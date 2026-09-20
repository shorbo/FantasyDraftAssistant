import Foundation

enum RankingsCSVError: LocalizedError {
    case notCSV
    case missingColumns([String])
    case tooFewPlayers(Int)

    var errorDescription: String? {
        switch self {
        case .notCSV:
            return "Could not read that file as CSV."
        case .missingColumns(let cols):
            return "This doesn't look like a FantasyPros rankings export — missing column(s): \(cols.joined(separator: ", "))."
        case .tooFewPlayers(let n):
            return "Only \(n) valid player rows found — expected a full rankings export. Check the file."
        }
    }
}

// Parses a FantasyPros rankings export. Headers may have trailing spaces,
// and POS embeds positional rank (e.g. "WR12"). Malformed rows are skipped
// rather than failing the whole file.
enum RankingsCSV {
    // Logical column → accepted header spellings (case-insensitive). FantasyPros
    // has changed header text between export versions (e.g. "BYE" → "BYE Week");
    // any alias satisfies the requirement.
    private static let columnOrder = ["RK", "TIERS", "PLAYER NAME", "TEAM", "POS", "BYE"]
    private static let columnAliases: [String: [String]] = [
        "RK": ["RK"],
        "TIERS": ["TIERS"],
        "PLAYER NAME": ["PLAYER NAME"],
        "TEAM": ["TEAM"],
        "POS": ["POS"],
        "BYE": ["BYE", "BYE WEEK"],
    ]
    // Optional: the delta between expert consensus rank and ADP. Used to
    // derive ADP (rank + delta).
    private static let ecrVsAdpAliases = ["ECR VS. ADP", "ECR VS ADP"]
    private static let upsideAliases = ["UPSIDE", "UPSIDE RATING"]

    static func parse(_ url: URL) throws -> [RankedPlayer] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw RankingsCSVError.notCSV
        }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> [RankedPlayer] {
        let rows = CSV.parseRows(text)
        guard let headerRow = rows.first else { throw RankingsCSVError.notCSV }
        let headerIndex = Dictionary(
            headerRow.enumerated().map { ($0.element.trimmingCharacters(in: .whitespaces).uppercased(), $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        var index: [String: Int] = [:]
        for column in columnOrder {
            if let i = (columnAliases[column] ?? []).lazy.compactMap({ headerIndex[$0] }).first {
                index[column] = i
            }
        }
        let missing = columnOrder.filter { index[$0] == nil }
        guard missing.isEmpty else { throw RankingsCSVError.missingColumns(missing) }

        let ecrVsAdpIndex = ecrVsAdpAliases.lazy.compactMap { headerIndex[$0] }.first
        let upsideIndex = upsideAliases.lazy.compactMap { headerIndex[$0] }.first

        func cell(_ row: [String], _ column: String) -> String {
            guard let i = index[column], i < row.count else { return "" }
            return row[i].trimmingCharacters(in: .whitespaces)
        }

        // "+2", "0", "-3" → 2, 0, -3; blank/"-" → nil.
        func ecrVsAdp(_ row: [String]) -> Double? {
            guard let i = ecrVsAdpIndex, i < row.count else { return nil }
            let raw = row[i]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "+", with: "")
            return Double(raw)
        }

        func upside(_ row: [String]) -> Int? {
            guard let i = upsideIndex, i < row.count else { return nil }
            let raw = row[i].trimmingCharacters(in: .whitespaces)
            let digits = raw.prefix(while: { $0.isNumber })
            return digits.isEmpty ? nil : Int(digits)
        }

        var players: [RankedPlayer] = []
        for row in rows.dropFirst() {
            guard let rank = Int(cell(row, "RK")) else { continue }
            let name = cell(row, "PLAYER NAME")
            let posField = cell(row, "POS")
            guard !name.isEmpty,
                  let match = posField.wholeMatch(of: /([A-Z]+?)(\d+)/),
                  let pos = Position(rawValue: String(match.1)), pos != .unknown,
                  let posRank = Int(match.2)
            else { continue }

            players.append(RankedPlayer(
                id: rank,
                rank: rank,
                tier: Int(cell(row, "TIERS")),
                name: name,
                team: cell(row, "TEAM"),
                pos: pos,
                posRank: posRank,
                bye: Int(cell(row, "BYE")),
                adp: ecrVsAdp(row).map { Double(rank) + $0 },
                upsideRating: upside(row)
            ))
        }

        guard players.count >= 100 else { throw RankingsCSVError.tooFewPlayers(players.count) }
        return players.sorted { $0.id < $1.id }
    }
}
