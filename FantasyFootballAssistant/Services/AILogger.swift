import Foundation

// Appends every LLM request/response to a plain-text log for troubleshooting
// (e.g. "why did the advisor say that" or "why is this slow").
enum AILogger {
    static let logFileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FantasyFootballAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai-requests.log")
    }()

    private static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func log(
        kind: String,
        model: String,
        prompt: String,
        response: String?,
        error: String?,
        durationSeconds: Double
    ) {
        var entry = "===== \(timestamp(Date())) [\(kind)] model=\(model) duration=\(String(format: "%.1f", durationSeconds))s =====\n"
        entry += "--- PROMPT ---\n\(prompt)\n"
        if let response { entry += "--- RESPONSE ---\n\(response)\n" }
        if let error { entry += "--- ERROR ---\n\(error)\n" }
        entry += "\n"

        guard let data = entry.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            }
        } else {
            try? data.write(to: logFileURL)
        }
    }
}
