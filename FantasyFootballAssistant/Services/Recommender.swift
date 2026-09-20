import Foundation

// Deterministic recommendations: consensus ranking is the value anchor, with
// phase strategy, roster needs, tiers, and lineup capacity breaking close calls.
enum Recommender {
    enum Phase: String {
        case anchors = "Rounds 1–3: Anchor RBs & Alpha WRs"
        case differenceMaker = "Rounds 4–7: WR depth + elite QB/TE target"
        case rushingUpside = "Rounds 8–11: High-upside RB backfield shifts"
        case pureUpside = "Rounds 12+: Pure upside, handcuffs & late stashes"

        static func forRound(_ round: Int) -> Phase {
            switch round {
            case ...3: return .anchors
            case 4...7: return .differenceMaker
            case 8...11: return .rushingUpside
            default: return .pureUpside
            }
        }
    }

    struct DraftPlan {
        let selectionPick: Int?
        let followingPick: Int?
        let remainingPicks: Int
        let emptySlots: [LineupSlot]
        let candidates: [RankedPlayer]

        var mustFillStarter: Bool { remainingPicks <= emptySlots.count && !emptySlots.isEmpty }
        var opponentPicksBetween: Int? {
            guard let selectionPick, let followingPick else { return nil }
            return followingPick - selectionPick - 1
        }
    }

    // Keep the actual upcoming selection separate from the pick AFTER it.
    // No probability model: rankings supply value, the roster supplies constraints.
    static func draftPlan(
        available: [RankedPlayer], myPlayers: [RankedPlayer], picks: [ResolvedPick],
        config: DraftConfig, currentPick: Int
    ) -> DraftPlan {
        let selection = DraftMath.nextUserPick(from: currentPick, config: config)
        let following = selection.flatMap { DraftMath.nextUserPick(from: $0 + 1, config: config) }
        let remaining = (selection.map { first in
            (first...config.totalPicks).filter { DraftMath.slot(forPick: $0, config: config) == config.userSlot }.count
        }) ?? 0
        let empty = DraftMath.assignRoster(myPlayers, slots: config.slots).starters
            .filter { $0.player == nil }.map(\.slot)
        let mustFill = remaining <= empty.count
        let rostered = Set(config.slots.flatMap(\.positions))
        let needed = Set(empty.flatMap(\.positions))
        let drafted = Set(picks.map(\.player.id) + myPlayers.map(\.id))
        let round = DraftMath.round(forPick: selection ?? currentPick, teams: config.teams)
        let eligible = available.filter { player in
            guard selection != nil, !drafted.contains(player.id), rostered.contains(player.pos) else { return false }
            if mustFill && !needed.contains(player.pos) { return false }
            // K/DST are starting-slot picks, with room to fill unusual multi-K/DST formats.
            if player.pos == .k || player.pos == .dst {
                let specialSlots = empty.filter { $0.positions == [.k] || $0.positions == [.dst] }.count
                return needed.contains(player.pos) && (mustFill || round > config.rounds - max(2, specialSlots))
            }
            return true
        }.sorted {
            if $0.rank != $1.rank { return ($0.rank ?? .max) < ($1.rank ?? .max) }
            return $0.id < $1.id
        }
        var board = Array(eligible.prefix(12))
        for pos in Position.allCases where rostered.contains(pos) {
            for player in eligible.filter({ $0.pos == pos }).prefix(3)
                where !board.contains(where: { $0.id == player.id }) {
                board.append(player)
            }
        }
        board.sort { ($0.rank ?? .max, $0.id) < ($1.rank ?? .max, $1.id) }
        return DraftPlan(selectionPick: selection, followingPick: following, remainingPicks: remaining,
                         emptySlots: empty, candidates: board)
    }

    struct PositionGroup: Identifiable {
        let pos: Position
        let players: [RankedPlayer]
        var id: String { pos.rawValue }
    }

    // The default recommendation is deterministic: consensus rank is the
    // value anchor, while phase and roster fit decide close options.
    static func primaryRecommendation(
        available: [RankedPlayer], myPlayers: [RankedPlayer], picks: [ResolvedPick],
        config: DraftConfig, currentPick: Int
    ) -> Recommendation? {
        let plan = draftPlan(available: available, myPlayers: myPlayers, picks: picks,
                             config: config, currentPick: currentPick)
        guard let top = plan.candidates.first else { return nil }
        let round = DraftMath.round(forPick: plan.selectionPick ?? currentPick, teams: config.teams)
        let phase = Phase.forRound(round)
        let emptyPositions = Set(plan.emptySlots.flatMap(\.positions))
        let starterNeeds = Set(plan.emptySlots.filter { !$0.isFlex }.flatMap(\.positions))
        func phasePriority(_ player: RankedPlayer) -> Int {
            switch phase {
            case .anchors:
                return [.rb, .wr].contains(player.pos) ? 0 : 2
            case .differenceMaker:
                if player.pos == .wr { return 0 }
                if [.qb, .te].contains(player.pos) && (player.posRank ?? 99) <= 5 { return 1 }
                return 2
            case .rushingUpside:
                return player.pos == .rb ? 0 : 1
            case .pureUpside:
                if player.pos == .k || player.pos == .dst { return 0 }
                if [.rb, .wr].contains(player.pos) { return 1 }
                return 2
            }
        }

        let eligible = plan.candidates.filter { player in
            // Strategy can guide a close call, but never replaces a clearly
            // better tier: only consider preferred positions within one rank tier.
            // Middle rounds also admit an elite QB/TE target; phase priority
            // decides between it and a similarly valued WR option.
            guard phasePriority(player) <= 1 else { return false }
            return (player.tier ?? Int.max) <= (top.tier ?? Int.max) + 1
        }
        let pool = eligible.isEmpty ? plan.candidates : eligible
        let best = pool.sorted { lhs, rhs in
            let lNeed = starterNeeds.contains(lhs.pos) ? 0 : (emptyPositions.contains(lhs.pos) ? 1 : 2)
            let rNeed = starterNeeds.contains(rhs.pos) ? 0 : (emptyPositions.contains(rhs.pos) ? 1 : 2)
            if lNeed != rNeed { return lNeed < rNeed }
            if phasePriority(lhs) != phasePriority(rhs) { return phasePriority(lhs) < phasePriority(rhs) }
            if phase == .pureUpside && lhs.upsideRating != rhs.upsideRating {
                return (lhs.upsideRating ?? 0) > (rhs.upsideRating ?? 0)
            }
            if lhs.tier != rhs.tier { return (lhs.tier ?? Int.max) < (rhs.tier ?? Int.max) }
            if lhs.rank != rhs.rank { return (lhs.rank ?? Int.max) < (rhs.rank ?? Int.max) }
            return lhs.id < rhs.id
        }.first ?? top
        let needText = starterNeeds.contains(best.pos) ? "fills an open \(best.pos.rawValue) starter slot" :
            (emptyPositions.contains(best.pos) ? "supports an open \(best.pos.rawValue) lineup need" : "preserves roster flexibility")
        let phaseText: String
        switch phase {
        case .anchors: phaseText = "the opening anchor phase favors RB/WR"
        case .differenceMaker: phaseText = "the middle phase favors WR depth and elite QB/TE values"
        case .rushingUpside: phaseText = "the late-middle phase favors RB upside"
            case .pureUpside:
                phaseText = (best.pos == .k || best.pos == .dst)
                    ? "the final rounds reserve a required kicker/defense slot"
                    : (best.upsideRating != nil ? "the late phase favors the supplied upside signal" : "the late phase favors RB/WR stash upside")
        }
        let rankText = best.rank.map { "rank #\($0)" } ?? "the highest available consensus value"
        return Recommendation(player: best, reason: "\(rankText), \(needText); \(phaseText).", tierBreak: tierCliffIds(available).contains(best.id))
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
