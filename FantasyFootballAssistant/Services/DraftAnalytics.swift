import Foundation

// Tunable constants for the analytics engine. Defaults target a 10-team PPR
// league with a 2-FLEX lineup (the shape the upgrade spec was written for).
struct AnalyticsConfig: Sendable {
    // Share of the league-wide flex slots assumed to be spent on each
    // position, as a fraction of total flex slots (must roughly sum to 1).
    var flexAllocation: [Position: Double] = [.rb: 0.40, .wr: 0.55, .te: 0.05]
    // Replacement-rank buffers past the dedicated starters for non-flex spots.
    var qbReplacementBuffer = 2
    var kReplacementBuffer = 1
    var dstReplacementBuffer = 1
    // An open FLEX slot counts as this fraction of a dedicated slot when
    // measuring positional-run demand (flex demand is split across RB/WR/TE).
    var flexDemandWeight = 0.5
    // Survival hit per full slot-equivalent of open demand ahead of my pick.
    var runPenaltyPerSlot = 0.07
    // A tier is a "cliff" when its chance of any member surviving falls below this.
    var tierCliffThreshold = 0.40
    // Two options are "near-equal" for tiebreaking when VORP is within this.
    var vorpTiebreakBand = 5.0

    // Survival curve breakpoints, on z = (ADP − pick) − picks_until_next_turn.
    var survivalUpperGap = 8.0
    var survivalUpperProb = 0.95
    var survivalMidProb = 0.50
    var survivalLowerGap = 8.0
    var survivalLowerProb = 0.10
    var survivalClampLow = 0.02
    var survivalClampHigh = 0.98

    static let `default` = AnalyticsConfig()
}

// Per-player precomputed annotations handed to the LLM.
struct PlayerAnnotation: Sendable {
    let player: RankedPlayer
    let projPts: Double
    let vorp: Double
    let adp: Double?
    let adpDelta: Double? // current pick − ADP (positive = falling past market)
    let rankDelta: Int? // current pick − overall rank
    let survivalPct: Double? // 0…1, nil when there is no next pick
    let isTierCliff: Bool
    let fillsOpenSlot: Bool
}

// Per-position summary: replacement baseline, the cliff at the top tier, and
// how much VORP you expect to lose by waiting a round.
struct PositionSummary: Sendable {
    let pos: Position
    let replacementPts: Double
    let topTier: Int?
    let tierSurvivalPct: Double? // P(any top-tier member survives to next pick)
    let dropoffNextRound: Double // bestVORP now − expected best VORP next pick
    let hasOpenStartingSlot: Bool
}

struct DraftAnalysis: Sendable {
    let replacementPts: [Position: Double]
    let annotationsById: [Int: PlayerAnnotation]
    let positionSummaries: [Position: PositionSummary]
    let picksUntilNextTurn: Int? // g
    let atTheTurn: Bool
    let remainingPicks: Int
    let emptyStartingSlots: Int // all starting slots incl. flex
    let emptyRequiredByLabel: [(label: String, count: Int)]

    func annotation(for player: RankedPlayer) -> PlayerAnnotation? { annotationsById[player.id] }
}

enum DraftAnalytics {
    // Replacement level per position, computed once from the full player
    // universe by projection. Flex-eligible positions get a share of the
    // league flex slots on top of their dedicated starters.
    static func replacementRanks(config: DraftConfig, cfg: AnalyticsConfig) -> [Position: Int] {
        var dedicated: [Position: Int] = [:]
        var flexSlotCount = 0
        for slot in config.slots {
            if slot.positions.count == 1 {
                dedicated[slot.positions[0], default: 0] += 1
            } else if slot.isFlex, !Set(slot.positions).isDisjoint(with: [.rb, .wr, .te]) {
                flexSlotCount += 1
            }
        }
        let totalFlex = flexSlotCount * config.teams

        var ranks: [Position: Int] = [:]
        for pos in [Position.qb, .rb, .wr, .te, .k, .dst] {
            let starters = (dedicated[pos] ?? 0) * config.teams
            switch pos {
            case .rb, .wr, .te:
                let share = Int((cfg.flexAllocation[pos] ?? 0) * Double(totalFlex))
                ranks[pos] = starters + share
            case .qb:
                ranks[pos] = starters + cfg.qbReplacementBuffer
            case .k:
                ranks[pos] = starters + cfg.kReplacementBuffer
            case .dst:
                ranks[pos] = starters + cfg.dstReplacementBuffer
            default:
                ranks[pos] = max(starters, 1)
            }
        }
        return ranks
    }

    static func replacementPoints(
        config: DraftConfig, allPlayers: [RankedPlayer],
        projections: ProjectionTable?, cfg: AnalyticsConfig
    ) -> [Position: Double] {
        let ranks = replacementRanks(config: config, cfg: cfg)
        var pts: [Position: Double] = [:]
        for (pos, rank) in ranks {
            let sorted = allPlayers
                .filter { $0.pos == pos }
                .map { Projection.points(for: $0, using: projections) }
                .sorted(by: >)
            guard !sorted.isEmpty else { pts[pos] = 0; continue }
            let idx = min(max(rank - 1, 0), sorted.count - 1)
            pts[pos] = sorted[idx]
        }
        return pts
    }

    // Piecewise-linear survival curve (before the positional-run penalty).
    static func baseSurvival(adp: Double, currentPick: Int, g: Int, cfg: AnalyticsConfig) -> Double {
        let d = adp - Double(currentPick)
        let z = d - Double(g)
        if z >= cfg.survivalUpperGap { return cfg.survivalUpperProb }
        if z >= 0 {
            return cfg.survivalMidProb + (z / cfg.survivalUpperGap) * (cfg.survivalUpperProb - cfg.survivalMidProb)
        }
        if z > -cfg.survivalLowerGap {
            return cfg.survivalMidProb - (-z / cfg.survivalLowerGap) * (cfg.survivalMidProb - cfg.survivalLowerProb)
        }
        return cfg.survivalLowerProb
    }

    static func compute(
        config: DraftConfig,
        currentPick: Int,
        nextUserPick: Int?,
        myPlayers: [RankedPlayer],
        available: [RankedPlayer],
        picks: [ResolvedPick],
        allPlayers: [RankedPlayer],
        projections: ProjectionTable?,
        cfg: AnalyticsConfig = .default
    ) -> DraftAnalysis {
        let replacement = replacementPoints(
            config: config, allPlayers: allPlayers, projections: projections, cfg: cfg
        )

        // Open starting slots on my roster (dedicated + flex).
        let (starters, _) = DraftMath.assignRoster(myPlayers, slots: config.slots)
        let openPositions = Set(
            starters.filter { $0.player == nil && !$0.slot.isFlex }.flatMap(\.slot.positions)
        )
        let openFlexPositions = Set(
            starters.filter { $0.player == nil && $0.slot.isFlex }.flatMap(\.slot.positions)
        )
        func fillsOpenSlot(_ pos: Position) -> Bool {
            openPositions.contains(pos) || openFlexPositions.contains(pos)
        }

        // Positional-run demand: open slots at each position among opponents
        // picking before my next turn (flex weighted).
        var runDemand: [Position: Double] = [:]
        if let nextUp = nextUserPick, nextUp > currentPick {
            for p in currentPick..<nextUp {
                let slot = DraftMath.slot(forPick: p, config: config)
                guard slot != config.userSlot else { continue }
                let theirPlayers = picks.filter { $0.slot == slot }.map(\.player)
                let (theirStarters, _) = DraftMath.assignRoster(theirPlayers, slots: config.slots)
                for entry in theirStarters where entry.player == nil {
                    if !entry.slot.isFlex {
                        runDemand[entry.slot.positions[0], default: 0] += 1
                    } else {
                        for pos in entry.slot.positions where [.rb, .wr, .te].contains(pos) {
                            runDemand[pos, default: 0] += cfg.flexDemandWeight
                        }
                    }
                }
            }
        }

        let g = nextUserPick.map { $0 - currentPick }
        let tierCliffIds = Recommender.tierCliffIds(available)

        // Per-player annotations.
        var annotations: [Int: PlayerAnnotation] = [:]
        for p in available {
            let proj = Projection.points(for: p, using: projections)
            let vorp = proj - (replacement[p.pos] ?? 0)
            let adpDelta = p.adp.map { Double(currentPick) - $0 }
            let rankDelta = p.rank.map { currentPick - $0 }

            var survival: Double?
            if let g, let adp = p.adp {
                let base = baseSurvival(adp: adp, currentPick: currentPick, g: g, cfg: cfg)
                let penalty = (runDemand[p.pos] ?? 0) * cfg.runPenaltyPerSlot
                survival = min(max(base - penalty, cfg.survivalClampLow), cfg.survivalClampHigh)
            }

            annotations[p.id] = PlayerAnnotation(
                player: p, projPts: proj, vorp: vorp, adp: p.adp,
                adpDelta: adpDelta, rankDelta: rankDelta, survivalPct: survival,
                isTierCliff: tierCliffIds.contains(p.id), fillsOpenSlot: fillsOpenSlot(p.pos)
            )
        }

        // Per-position summaries.
        var summaries: [Position: PositionSummary] = [:]
        for pos in [Position.qb, .rb, .wr, .te, .k, .dst] {
            let posAvail = available
                .filter { $0.pos == pos }
                .sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
            guard !posAvail.isEmpty else { continue }

            // Top-available tier and its survival (P(any member survives)).
            let topTier = posAvail.first?.tier
            var tierSurvival: Double?
            if let topTier {
                let members = posAvail.filter { $0.tier == topTier }
                    .compactMap { annotations[$0.id]?.survivalPct }
                if !members.isEmpty {
                    let allGone = members.reduce(1.0) { $0 * (1 - $1) }
                    tierSurvival = 1 - allGone
                }
            }

            // Dropoff = best VORP now − expected best VORP that survives to next pick.
            let byVorp = posAvail.compactMap { annotations[$0.id] }
                .sorted { $0.vorp > $1.vorp }
            let bestNow = byVorp.first?.vorp ?? 0
            var expectedNext = 0.0
            var allBetterGone = 1.0
            for a in byVorp {
                let s = a.survivalPct ?? 0
                expectedNext += a.vorp * s * allBetterGone
                allBetterGone *= (1 - s)
            }
            let dropoff = g == nil ? 0 : max(0, bestNow - expectedNext)

            summaries[pos] = PositionSummary(
                pos: pos, replacementPts: replacement[pos] ?? 0,
                topTier: topTier, tierSurvivalPct: tierSurvival,
                dropoffNextRound: dropoff, hasOpenStartingSlot: fillsOpenSlot(pos)
            )
        }

        // Capacity math: all starting slots count as required (incl. flex).
        var emptyByLabel: [String: Int] = [:]
        var labelOrder: [String] = []
        var emptyStartingSlots = 0
        for entry in starters where entry.player == nil {
            emptyStartingSlots += 1
            if emptyByLabel[entry.slot.label] == nil { labelOrder.append(entry.slot.label) }
            emptyByLabel[entry.slot.label, default: 0] += 1
        }
        let emptyRequired = labelOrder.map { (label: $0, count: emptyByLabel[$0]!) }

        var remainingPicks = 0
        if let userSlot = config.userSlot {
            for p in currentPick...max(currentPick, config.totalPicks) where p <= config.totalPicks {
                if DraftMath.slot(forPick: p, config: config) == userSlot { remainingPicks += 1 }
            }
        }

        let opponentPicksBetween = g.map { $0 - 1 } ?? Int.max
        return DraftAnalysis(
            replacementPts: replacement,
            annotationsById: annotations,
            positionSummaries: summaries,
            picksUntilNextTurn: g,
            atTheTurn: opponentPicksBetween <= 2,
            remainingPicks: remainingPicks,
            emptyStartingSlots: emptyStartingSlots,
            emptyRequiredByLabel: emptyRequired
        )
    }
}
