import Foundation

// Matches FantasyPros rankings to Sleeper player ids, and resolves live
// Sleeper picks back to rankings rows.
enum NameMatching {
    // Both sides use slightly different team codes for a few franchises.
    private static let teamAliases: [String: String] = [
        "JAC": "JAX", "WSH": "WAS", "ARZ": "ARI", "BLT": "BAL", "CLV": "CLE",
        "HST": "HOU", "LA": "LAR", "SD": "LAC", "STL": "LAR", "OAK": "LV",
    ]

    // Ranking sites sometimes use nicknames where Sleeper has the legal name.
    private static let nameAliases: [String: String] = [
        "hollywood brown": "marquise brown",
        "bam knight": "zonovan knight",
        "gabe davis": "gabriel davis",
        "josh palmer": "joshua palmer",
        "mitch trubisky": "mitchell trubisky",
        "chig okonkwo": "chigoziem okonkwo",
    ]

    private static let nameSuffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "v"]

    static func normTeam(_ team: String?) -> String {
        let t = (team ?? "").uppercased()
        return teamAliases[t] ?? t
    }

    static func normalizeName(_ name: String) -> String {
        var tokens = name.lowercased()
            .components(separatedBy: CharacterSet.lowercaseLetters.union(.decimalDigits).union(.whitespaces).inverted)
            .joined()
            .split(separator: " ")
            .map(String.init)
        while tokens.count > 2, let last = tokens.last, nameSuffixes.contains(last) {
            tokens.removeLast()
        }
        let joined = tokens.joined(separator: " ")
        return nameAliases[joined] ?? joined
    }

    private static func nameKey(_ pos: Position, _ name: String) -> String {
        "\(pos.rawValue):\(normalizeName(name))"
    }

    // Annotates each rankings player with its Sleeper id (nil when no
    // confident match). Sleeper DEF ids are team codes ("PHI"), so DSTs match
    // on team rather than name.
    static func match(_ players: [RankedPlayer], to db: [String: SleeperDbPlayer]) -> [RankedPlayer] {
        var byName: [String: [String]] = [:]
        var dstByTeam: [String: String] = [:]
        for (id, p) in db {
            if p.pos == .dst {
                dstByTeam[normTeam(id)] = id
            } else {
                byName[nameKey(p.pos, p.name), default: []].append(id)
            }
        }

        return players.map { player in
            var p = player
            if p.pos == .dst {
                p.sleeperId = dstByTeam[normTeam(p.team)]
            } else {
                let candidates = byName[nameKey(p.pos, p.name)] ?? []
                if candidates.count == 1 {
                    p.sleeperId = candidates[0]
                } else if candidates.count > 1 {
                    // Same name + position (e.g. a retired namesake): prefer team, then active.
                    p.sleeperId = candidates.first { normTeam(db[$0]?.team) == normTeam(p.team) }
                        ?? candidates.first { db[$0]?.active == true }
                        ?? candidates.first
                }
            }
            return p
        }
    }
}

// Maps a Sleeper pick to a rankings player: by sleeperId first, then by
// name+position from the pick's metadata, else a stub so rosters still track
// players outside the rankings file.
struct PickResolver {
    private let bySleeperId: [String: RankedPlayer]
    private let byNameKey: [String: RankedPlayer]

    init(players: [RankedPlayer]) {
        var byId: [String: RankedPlayer] = [:]
        var byName: [String: RankedPlayer] = [:]
        for p in players {
            if let sid = p.sleeperId, byId[sid] == nil { byId[sid] = p }
            let key = "\(p.pos.rawValue):\(NameMatching.normalizeName(p.name))"
            if byName[key] == nil { byName[key] = p }
        }
        bySleeperId = byId
        byNameKey = byName
    }

    func resolve(_ pick: SleeperPick) -> RankedPlayer {
        if let p = bySleeperId[pick.playerId] { return p }

        let md = pick.metadata
        let pos = Position(sleeper: md?.position)
        let name = [md?.firstName, md?.lastName].compactMap { $0 }.joined(separator: " ")
        if let p = byNameKey["\(pos.rawValue):\(NameMatching.normalizeName(name))"] { return p }

        return RankedPlayer(
            id: -(abs(pick.playerId.hashValue % 1_000_000) + 1),
            rank: nil,
            tier: nil,
            name: name.isEmpty ? "Player \(pick.playerId)" : name,
            team: md?.team ?? "",
            pos: pos,
            posRank: nil,
            bye: nil,
            sleeperId: pick.playerId,
            unranked: true
        )
    }
}
