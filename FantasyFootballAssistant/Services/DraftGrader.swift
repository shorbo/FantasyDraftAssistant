import Foundation

// One pick's value: where the player was actually taken vs. their consensus
// rank. delta > 0 = a steal (drafted later than ranked); < 0 = a reach.
struct PickValue: Identifiable, Sendable {
    let pick: ResolvedPick
    let effectiveRank: Int
    var delta: Int { pick.pickNumber - effectiveRank }
    var id: Int { pick.pickNumber }
}

struct TeamGrade: Identifiable, Sendable {
    let slot: Int
    let teamName: String
    let isMine: Bool
    let picks: [PickValue]
    let totalValue: Int // steals − reaches vs. consensus rank
    let valueGrade: String
    let projectedPoints: Double // best starting lineup, modeled projections
    let pointsGrade: String
    let bestPicks: [PickValue] // steals, best delta first
    let worstPicks: [PickValue] // reaches, worst delta first
    var id: Int { slot }
    var avgValue: Double { picks.isEmpty ? 0 : Double(totalValue) / Double(picks.count) }
}

// How to rank/grade the leaderboard.
enum LeaderboardMetric: String, CaseIterable, Identifiable {
    case value = "Draft value"
    case points = "Projected points"
    var id: String { rawValue }
}

// Scores a completed draft two ways — value over consensus rank (draft-day
// efficiency) and best-lineup projected points (roster strength) — grading
// each team on a curve relative to the field so "average draft = C".
enum DraftGrader {
    static func grade(
        picks: [ResolvedPick],
        teamNames: [String],
        unrankedRank: Int,
        config: DraftConfig,
        projections: ProjectionTable?
    ) -> [TeamGrade] {
        guard config.teams > 0 else { return [] }

        var bySlot: [Int: [PickValue]] = [:]
        for p in picks {
            let rank = p.player.rank ?? unrankedRank
            bySlot[p.slot, default: []].append(PickValue(pick: p, effectiveRank: rank))
        }

        let slots = (1...config.teams).filter { !(bySlot[$0]?.isEmpty ?? true) }
        let values = slots.map { slot in bySlot[slot]!.reduce(0) { $0 + $1.delta } }
        let points = slots.map { slot in
            Projection.startingLineupPoints(
                players: bySlot[slot]!.map(\.pick.player), slots: config.slots, using: projections
            )
        }

        let valueCurve = Curve(values.map(Double.init))
        let pointsCurve = Curve(points)

        func teamName(_ slot: Int) -> String {
            (slot >= 1 && slot <= teamNames.count) ? teamNames[slot - 1] : "Team \(slot)"
        }

        let grades = slots.enumerated().map { i, slot -> TeamGrade in
            let pv = bySlot[slot]!
            let byValue = pv.sorted { $0.delta > $1.delta }
            return TeamGrade(
                slot: slot,
                teamName: teamName(slot),
                isMine: slot == config.userSlot,
                picks: pv,
                totalValue: values[i],
                valueGrade: valueCurve.letter(for: Double(values[i])),
                projectedPoints: points[i],
                pointsGrade: pointsCurve.letter(for: points[i]),
                bestPicks: byValue,
                worstPicks: byValue.reversed()
            )
        }

        return grades
    }

    // Field mean/spread → letter grade, so grading is relative to the league.
    private struct Curve {
        let mean: Double
        let std: Double

        init(_ xs: [Double]) {
            mean = xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
            let m = mean
            let variance = xs.isEmpty ? 0 : xs.reduce(0.0) { $0 + pow($1 - m, 2) } / Double(xs.count)
            std = variance.squareRoot()
        }

        func letter(for x: Double) -> String {
            let z = std > 0 ? (x - mean) / std : 0
            switch z {
            case 1.5...: return "A+"
            case 0.75...: return "A"
            case 0.25...: return "B"
            case (-0.25)...: return "C"
            case (-1.0)...: return "D"
            default: return "F"
            }
        }
    }
}
