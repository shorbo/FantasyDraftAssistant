import Foundation

enum SleeperAPIError: LocalizedError {
    case badStatus(Int, String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let path): return "Sleeper API error \(code) for \(path)"
        case .notFound(let what): return what
        }
    }
}

enum SleeperAPI {
    private static let base = "https://api.sleeper.app/v1"

    // No caching anywhere: draft picks must always be fresh, and both
    // URLSession's local cache and Sleeper's CDN will happily serve stale
    // responses to a plain GET during a live draft.
    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T? {
        var request = URLRequest(url: URL(string: base + path)!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw SleeperAPIError.badStatus(status, path) }
        // Sleeper returns literal null for some missing resources.
        if data.count <= 4, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return nil
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func user(_ usernameOrId: String) async throws -> SleeperUser? {
        let name = usernameOrId.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return try await get("/user/\(encoded)", as: SleeperUser.self)
    }

    static func userDrafts(userId: String, season: String) async throws -> [SleeperDraft] {
        try await get("/user/\(userId)/drafts/nfl/\(season)", as: [SleeperDraft].self) ?? []
    }

    static func draft(_ draftId: String) async throws -> SleeperDraft? {
        try await get("/draft/\(draftId)", as: SleeperDraft.self)
    }

    static func draftPicks(_ draftId: String) async throws -> [SleeperPick] {
        try await get("/draft/\(draftId)/picks", as: [SleeperPick].self) ?? []
    }

    static func leagueUsers(_ leagueId: String) async throws -> [SleeperLeagueUser] {
        try await get("/league/\(leagueId)/users", as: [SleeperLeagueUser].self) ?? []
    }

    static var currentSeason: String {
        String(Calendar.current.component(.year, from: Date()))
    }

    // Accepts a raw draft id or any sleeper.com draft URL
    // (e.g. https://sleeper.com/draft/nfl/123456789012345678).
    static func parseDraftInput(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: #"draft/(?:nfl/)?(\d{10,})"#, options: .regularExpression) {
            return String(s[range]).components(separatedBy: "/").last
        }
        if s.range(of: #"^\d{10,}$"#, options: .regularExpression) != nil { return s }
        return nil
    }

    // MARK: - Player database (trimmed + cached)

    private struct PlayersCache: Codable {
        var fetchedAt: Date
        var players: [String: SleeperDbPlayer]
    }

    private struct RawDbPlayer: Codable {
        var firstName: String?
        var lastName: String?
        var fullName: String?
        var position: String?
        var team: String?
        var active: Bool?

        enum CodingKeys: String, CodingKey {
            case firstName = "first_name"
            case lastName = "last_name"
            case fullName = "full_name"
            case position, team, active
        }
    }

    private static let playersTTL: TimeInterval = 24 * 60 * 60 // Sleeper asks for one fetch/day max
    // FB included because rankings sites list fullbacks as RB.
    private static let fantasyPositions: Set<String> = ["QB", "RB", "FB", "WR", "TE", "K", "DEF"]

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FantasyFootballAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sleeper-players-nfl.json")
    }

    // The full dump is ~5MB; we keep only fantasy-relevant positions and the
    // fields needed for name matching.
    static func loadPlayersDb() async throws -> [String: SleeperDbPlayer] {
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(PlayersCache.self, from: data),
           Date().timeIntervalSince(cache.fetchedAt) < playersTTL {
            return cache.players
        }

        let raw = try await get("/players/nfl", as: [String: RawDbPlayer].self) ?? [:]
        var players: [String: SleeperDbPlayer] = [:]
        for (id, p) in raw {
            guard let position = p.position, fantasyPositions.contains(position) else { continue }
            let name = p.fullName ?? [p.firstName, p.lastName].compactMap { $0 }.joined(separator: " ")
            players[id] = SleeperDbPlayer(
                name: name,
                pos: Position(sleeper: position),
                team: p.team,
                active: p.active == true
            )
        }

        if let data = try? JSONEncoder().encode(PlayersCache(fetchedAt: Date(), players: players)) {
            try? data.write(to: cacheURL)
        }
        return players
    }
}
