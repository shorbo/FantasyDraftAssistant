import Foundation

enum DraftSource: String, Codable, CaseIterable, Sendable {
    case sleeper
    case yahoo

    var displayName: String {
        switch self {
        case .sleeper: "Sleeper"
        case .yahoo: "Yahoo Fantasy"
        }
    }
}

enum Position: String, Codable, CaseIterable, Sendable {
    case qb = "QB"
    case rb = "RB"
    case wr = "WR"
    case te = "TE"
    case k = "K"
    case dst = "DST"
    case unknown = "?"

    // Sleeper uses DEF for defenses and FB for fullbacks (which rankings
    // sites list as RB).
    init(sleeper raw: String?) {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "DEF", "DST", "D/ST", "DEFENSE": self = .dst
        case "FB": self = .rb
        default: self = Position(rawValue: raw ?? "") ?? .unknown
        }
    }
}

// A player row from the rankings CSV, annotated with its Sleeper id after
// matching. Also used for "stub" players drafted outside the rankings.
struct RankedPlayer: Codable, Identifiable, Hashable, Sendable {
    var id: Int // rank for ranked players, negative synthetic ids for stubs
    var rank: Int?
    var tier: Int?
    var name: String
    var team: String
    var pos: Position
    var posRank: Int?
    var bye: Int?
    var sleeperId: String?
    var unranked: Bool = false
    // Overall average draft position (a rank-like 1..N slot). Derived from the
    // rankings CSV as rank + (ECR-vs-ADP delta), since FantasyPros' overall
    // rank is its ECR. nil when the CSV has no ADP delta for this player.
    var adp: Double?
    // Optional analyst signal parsed from FantasyPros' UPSIDE column (1–5).
    // It is used only as a late-round tiebreaker; missing values are normal.
    var upsideRating: Int? = nil
}

struct LineupSlot: Hashable, Sendable {
    var key: String // "RB1", "FLEX"…
    var label: String // "RB", "FLEX"
    var positions: [Position]
    var isFlex: Bool { positions.count > 1 }
}

// Everything the app needs to know about a draft, derived from Sleeper's
// draft object once at connect time.
struct DraftConfig: Sendable {
    var draftId: String
    var leagueId: String?
    var name: String
    var season: String
    var type: String // "snake" | "linear" | "auction"
    var reversalRound: Int
    var teams: Int
    var rounds: Int
    var slots: [LineupSlot]
    var benchSize: Int
    var scoring: String?
    var userSlot: Int?
    // User-declared format of the CSV; the export itself has no scoring metadata.
    var rankingsScoring: String? = nil

    var totalPicks: Int { teams * rounds }
}

// A Sleeper pick resolved against the rankings.
struct ResolvedPick: Identifiable, Sendable {
    var pickNumber: Int
    var slot: Int
    var player: RankedPlayer
    var isMine: Bool
    var id: Int { pickNumber }
}

struct Recommendation: Identifiable, Sendable {
    var player: RankedPlayer
    var reason: String
    var tierBreak: Bool
    var id: Int { player.id }
}
