import Foundation

// Picks are NOT stored — Sleeper is the source of truth, so resuming a
// session just reconnects to the draft and re-fetches them. We persist the
// matched rankings so a relaunch mid-draft doesn't need the CSV again.
struct SavedSession: Codable, Sendable {
    var draftId: String
    var draftName: String
    var userId: String
    var players: [RankedPlayer]
    var teamNames: [String]
    var projections: ProjectionTable? // optional → old saved sessions still decode
    var savedAt: Date
    var rankingsScoring: String? = nil
}

enum SessionStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FantasyFootballAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }

    static func save(_ session: SavedSession) {
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: fileURL)
        }
    }

    static func load() -> SavedSession? {
        guard let data = try? Data(contentsOf: fileURL),
              let session = try? JSONDecoder().decode(SavedSession.self, from: data),
              !session.draftId.isEmpty, !session.userId.isEmpty, !session.players.isEmpty
        else { return nil }
        return session
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
