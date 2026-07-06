import Foundation

// Consensus-ranking recommendations: the best available players at each
// position the league starts, ordered by FantasyPros overall rank.
enum Recommender {
    struct PositionGroup: Identifiable {
        let pos: Position
        let players: [RankedPlayer]
        var id: String { pos.rawValue }
    }

    // Top `limit` available at each rostered position, in draft-relevance order.
    static func topByPosition(
        available: [RankedPlayer],
        config: DraftConfig,
        limit: Int = 3
    ) -> [PositionGroup] {
        let order: [Position] = [.qb, .rb, .wr, .te, .k, .dst]
        let rostered = Set(config.slots.flatMap { $0.positions })

        var groups: [PositionGroup] = []
        for pos in order where rostered.contains(pos) {
            let players = available
                .filter { $0.pos == pos }
                .sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
                .prefix(limit)
            if !players.isEmpty {
                groups.append(PositionGroup(pos: pos, players: Array(players)))
            }
        }
        return groups
    }

    // Player ids that are the last available in their tier at their position —
    // a cliff follows, so they carry extra urgency.
    static func tierCliffIds(_ available: [RankedPlayer]) -> Set<Int> {
        var counts: [String: Int] = [:]
        for p in available {
            guard let tier = p.tier else { continue }
            counts["\(p.pos.rawValue):\(tier)", default: 0] += 1
        }
        var set: Set<Int> = []
        for p in available {
            if let tier = p.tier, counts["\(p.pos.rawValue):\(tier)"] == 1 { set.insert(p.id) }
        }
        return set
    }
}
