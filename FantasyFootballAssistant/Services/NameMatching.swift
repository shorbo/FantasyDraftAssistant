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

    // Keep suffix information separately for compact Yahoo names. The regular
    // normalizer intentionally removes it, but `B. Robinson` and
    // `B. Robinson Jr.` can be different players on the same NFL team.
    static func suffix(_ name: String) -> String? {
        let token = name.lowercased()
            .components(separatedBy: CharacterSet.lowercaseLetters.union(.decimalDigits).inverted)
            .last(where: { !$0.isEmpty })
        guard let token, nameSuffixes.contains(token) else { return nil }
        return token
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
    private let byYahooInitialKey: [String: RankedPlayer]
    private let byYahooInitialSuffixKey: [String: RankedPlayer]

    init(players: [RankedPlayer]) {
        var byId: [String: RankedPlayer] = [:]
        var byName: [String: RankedPlayer] = [:]
        var byYahooInitial: [String: [RankedPlayer]] = [:]
        var byYahooInitialSuffix: [String: [RankedPlayer]] = [:]
        for p in players {
            if let sid = p.sleeperId, byId[sid] == nil { byId[sid] = p }
            let key = "\(p.pos.rawValue):\(NameMatching.normalizeName(p.name))"
            if byName[key] == nil { byName[key] = p }
            let nameParts = NameMatching.normalizeName(p.name).split(separator: " ")
            if let first = nameParts.first, let last = nameParts.last, nameParts.count >= 2 {
                let initialKey = "\(p.pos.rawValue):\(NameMatching.normTeam(p.team)):\(first.prefix(1)):\(last)"
                if let suffix = NameMatching.suffix(p.name) {
                    byYahooInitialSuffix["\(initialKey):\(suffix)", default: []].append(p)
                } else {
                    byYahooInitial[initialKey, default: []].append(p)
                }
            }
        }
        bySleeperId = byId
        byNameKey = byName
        // Yahoo's compact pick cards use names such as "O. Hampton". Only
        // keep an initial+surname key when position and NFL team make it
        // unambiguous, otherwise fall through to an unranked stub.
        byYahooInitialKey = byYahooInitial.compactMapValues { $0.count == 1 ? $0[0] : nil }
        byYahooInitialSuffixKey = byYahooInitialSuffix.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    func resolve(_ pick: SleeperPick) -> RankedPlayer {
        if let p = bySleeperId[pick.playerId] { return p }

        let md = pick.metadata
        let pos = Position(sleeper: md?.position)
        let name = [md?.firstName, md?.lastName].compactMap { $0 }.joined(separator: " ")
        if let p = byNameKey["\(pos.rawValue):\(NameMatching.normalizeName(name))"] { return p }
        let parts = NameMatching.normalizeName(name).split(separator: " ")
        if let first = parts.first, let last = parts.last, parts.count >= 2 {
            let key = "\(pos.rawValue):\(NameMatching.normTeam(md?.team)):\(first.prefix(1)):\(last)"
            if let suffix = NameMatching.suffix(name), let p = byYahooInitialSuffixKey["\(key):\(suffix)"] {
                return p
            }
            if let p = byYahooInitialKey[key] { return p }
        }

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
