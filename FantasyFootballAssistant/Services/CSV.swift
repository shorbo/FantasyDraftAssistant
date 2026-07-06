import Foundation

enum CSV {
    // Minimal RFC-4180 row parser: quoted fields, escaped quotes, CRLF.
    // Drops fully-empty lines. Used by the rankings and projections parsers.
    static func parseRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex

        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c.isNewline {
                // Swift treats CRLF as a single Character, so isNewline covers
                // \n, \r, and \r\n uniformly.
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i = text.index(after: i)
        }
        row.append(field)
        if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        return rows
    }

    // Parses a number that may carry quotes, thousands separators, or blanks.
    static func number(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
        return cleaned.isEmpty ? nil : Double(cleaned)
    }
}
