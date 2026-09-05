import Foundation

// Wire format emitted by the browser extension. The only identifier trusted
// for de-duplication is the overall pick number; Yahoo player identifiers are
// intentionally not required for the DOM-based POC.
struct YahooDraftPickEvent: Codable, Sendable {
    let source: String
    let pick: Int
    let round: Int?
    let draftSlot: Int?
    let fantasyTeam: String?
    let playerName: String
    let position: String?
    let nflTeam: String?

    enum CodingKeys: String, CodingKey {
        case source, pick, round
        case draftSlot = "draft_slot"
        case fantasyTeam = "fantasy_team"
        case playerName = "player_name"
        case position
        case nflTeam = "nfl_team"
    }

    func validate() throws {
        guard source.lowercased() == "yahoo" else { throw YahooReceiverError.invalidEvent("source must be yahoo") }
        guard pick > 0 else { throw YahooReceiverError.invalidEvent("pick must be positive") }
        guard !playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw YahooReceiverError.invalidEvent("player_name is required")
        }
        if let round, round < 1 { throw YahooReceiverError.invalidEvent("round must be positive") }
        if let draftSlot, draftSlot < 1 { throw YahooReceiverError.invalidEvent("draft_slot must be positive") }
    }
}

enum YahooReceiverError: LocalizedError {
    case invalidEvent(String)

    var errorDescription: String? {
        switch self {
        case .invalidEvent(let reason): "Invalid Yahoo draft event: \(reason)."
        }
    }
}
