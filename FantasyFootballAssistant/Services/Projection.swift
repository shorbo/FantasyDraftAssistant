import Foundation

// Projected fantasy points for a player. Uses real FantasyPros projections
// when a table is loaded; otherwise falls back to a positional value curve
// modeled from consensus positional rank, so positions the user hasn't
// loaded still get a sensible number.
enum Projection {
    static func points(for player: RankedPlayer, using table: ProjectionTable?) -> Double {
        if let real = table?.points(for: player) { return real }
        return modeled(for: player)
    }

    // (base = points for the position's #1, drop per positional rank, floor).
    private static func curve(for pos: Position) -> (base: Double, drop: Double, floor: Double) {
        switch pos {
        case .qb: return (385, 6.0, 200)
        case .rb: return (330, 6.0, 55)
        case .wr: return (315, 5.0, 55)
        case .te: return (245, 6.5, 55)
        case .k: return (160, 1.2, 105)
        case .dst: return (165, 2.2, 80)
        case .unknown: return (40, 0, 20)
        }
    }

    static func modeled(for player: RankedPlayer) -> Double {
        let c = curve(for: player.pos)
        // Unranked/stub players (no positional rank) get the positional floor.
        let posRank = player.posRank ?? 999
        return max(c.floor, c.base - c.drop * Double(posRank - 1))
    }

    // Projected points of the best legal starting lineup from a set of players:
    // greedily seat the highest projections into dedicated slots first, then
    // flex slots. Leftovers are bench and don't count toward the total.
    static func startingLineupPoints(
        players: [RankedPlayer], slots: [LineupSlot], using table: ProjectionTable?
    ) -> Double {
        var open = slots
        var total = 0.0
        for player in players.sorted(by: { points(for: $0, using: table) > points(for: $1, using: table) }) {
            if let i = open.firstIndex(where: { !$0.isFlex && $0.positions == [player.pos] }) {
                total += points(for: player, using: table)
                open.remove(at: i)
            } else if let i = open.firstIndex(where: { $0.isFlex && $0.positions.contains(player.pos) }) {
                total += points(for: player, using: table)
                open.remove(at: i)
            }
        }
        return total
    }
}
