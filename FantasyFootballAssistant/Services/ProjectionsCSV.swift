import Foundation

// Real projected fantasy points loaded from FantasyPros projection exports,
// keyed by normalized player name (with a name+team key for disambiguation).
struct ProjectionTable: Codable, Sendable, Equatable {
    var byName: [String: Double] = [:]
    var byNameTeam: [String: Double] = [:]

    var count: Int { byName.count }
    var isEmpty: Bool { byName.isEmpty }

    func points(for player: RankedPlayer) -> Double? {
        let name = NameMatching.normalizeName(player.name)
        if let v = byNameTeam["\(name)|\(NameMatching.normTeam(player.team))"] { return v }
        return byName[name]
    }

    mutating func add(name: String, team: String, fpts: Double) {
        let n = NameMatching.normalizeName(name)
        byName[n] = fpts
        byNameTeam["\(n)|\(NameMatching.normTeam(team))"] = fpts
    }
}

enum ProjectionsCSVError: LocalizedError {
    case notCSV
    case missingColumns

    var errorDescription: String? {
        switch self {
        case .notCSV: return "Could not read that file as CSV."
        case .missingColumns:
            return "This doesn't look like a FantasyPros projections export — expected Player and FPTS columns."
        }
    }
}

// Parses FantasyPros per-position projection exports. Every position has a
// different stat layout, but all share `Player`, `Team`, and a trailing
// `FPTS` column. "low"/"high" variance rows have a blank Player and are
// skipped.
enum ProjectionsCSV {
    struct Row { let name: String; let team: String; let fpts: Double }

    static func parse(_ url: URL) throws -> [Row] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ProjectionsCSVError.notCSV
        }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> [Row] {
        let rows = CSV.parseRows(text)
        guard let header = rows.first else { throw ProjectionsCSVError.notCSV }
        let cols = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let nameIdx = cols.firstIndex(of: "player"),
              let fptsIdx = cols.lastIndex(of: "fpts")
        else { throw ProjectionsCSVError.missingColumns }
        let teamIdx = cols.firstIndex(of: "team")

        var result: [Row] = []
        for row in rows.dropFirst() {
            guard nameIdx < row.count, fptsIdx < row.count else { continue }
            let name = row[nameIdx].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let fpts = CSV.number(row[fptsIdx]) else { continue }
            let team = (teamIdx.flatMap { $0 < row.count ? row[$0] : nil } ?? "")
                .trimmingCharacters(in: .whitespaces)
            result.append(Row(name: name, team: team, fpts: fpts))
        }
        return result
    }

    // Merges one or more projection files into a single table. Returns which
    // files parsed and which failed, for reporting at setup.
    static func buildTable(from urls: [URL]) -> (table: ProjectionTable, loaded: Int, failed: [String]) {
        var table = ProjectionTable()
        var loaded = 0
        var failed: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let rows = try parse(url)
                guard !rows.isEmpty else { failed.append(url.lastPathComponent); continue }
                for r in rows { table.add(name: r.name, team: r.team, fpts: r.fpts) }
                loaded += 1
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        return (table, loaded, failed)
    }
}
