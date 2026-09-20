import Foundation

enum DraftMath {
    // Sleeper draft settings → lineup slot definitions, in display order.
    private static func slotDefs(_ s: SleeperDraftSettings) -> [(count: Int, label: String, positions: [Position])] {
        [
            (s.slotsQB ?? 0, "QB", [.qb]),
            (s.slotsRB ?? 0, "RB", [.rb]),
            (s.slotsWR ?? 0, "WR", [.wr]),
            (s.slotsTE ?? 0, "TE", [.te]),
            (s.slotsFlex ?? 0, "FLEX", [.rb, .wr, .te]),
            (s.slotsWRRBFlex ?? 0, "W/R", [.wr, .rb]),
            (s.slotsRecFlex ?? 0, "W/T", [.wr, .te]),
            (s.slotsSuperFlex ?? 0, "SFLX", [.qb, .rb, .wr, .te]),
            (s.slotsK ?? 0, "K", [.k]),
            (s.slotsDef ?? 0, "DST", [.dst]),
        ]
    }

    static func buildConfig(draft: SleeperDraft, userId: String?) -> DraftConfig {
        let s = draft.settings ?? SleeperDraftSettings()
        let teams = s.teams ?? 0
        let rounds = s.rounds ?? 0

        var slots: [LineupSlot] = []
        for def in slotDefs(s) where def.count > 0 {
            for i in 1...def.count {
                slots.append(LineupSlot(
                    key: def.count > 1 ? "\(def.label)\(i)" : def.label,
                    label: def.label,
                    positions: def.positions
                ))
            }
        }

        return DraftConfig(
            draftId: draft.draftId,
            leagueId: draft.leagueId,
            // Sleeper returns "" (not null) for unnamed mock drafts.
            name: draft.metadata?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Sleeper draft",
            season: draft.season ?? SleeperAPI.currentSeason,
            type: draft.type ?? "snake",
            reversalRound: s.reversalRound ?? 0,
            teams: teams,
            rounds: rounds,
            slots: slots,
            benchSize: s.slotsBench ?? max(0, rounds - slots.count),
            scoring: draft.metadata?.scoringType,
            userSlot: userId.flatMap { draft.draftOrder?[$0] }
        )
    }

    // Yahoo does not expose draft settings through the POC receiver, so its
    // setup flow supplies these values directly rather than guessing from a
    // pick event.
    static func buildManualConfig(
        name: String, teams: Int, rounds: Int, type: String, userSlot: Int,
        slots: [LineupSlot], benchSize: Int, scoring: String = "half_ppr"
    ) -> DraftConfig {
        DraftConfig(
            draftId: "yahoo-local", leagueId: nil,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Yahoo draft" : name,
            season: SleeperAPI.currentSeason, type: type, reversalRound: 0,
            teams: teams, rounds: rounds, slots: slots, benchSize: benchSize,
            scoring: scoring, userSlot: userSlot
        )
    }

    static func round(forPick pick: Int, teams: Int) -> Int {
        teams > 0 ? Int(ceil(Double(pick) / Double(teams))) : 1
    }

    // Which draft slot is on the clock for an overall pick number. Handles
    // snake, linear, and snake with third-round reversal.
    static func slot(forPick pick: Int, config: DraftConfig) -> Int {
        let r = round(forPick: pick, teams: config.teams)
        let i = (pick - 1) % config.teams
        if config.type == "linear" { return i + 1 }
        var forward = r % 2 == 1
        if config.reversalRound > 0 && r >= config.reversalRound { forward.toggle() }
        return forward ? i + 1 : config.teams - i
    }

    static func nextUserPick(from currentPick: Int, config: DraftConfig) -> Int? {
        guard let userSlot = config.userSlot, config.teams > 0 else { return nil }
        for p in currentPick...max(currentPick, config.totalPicks) where p <= config.totalPicks {
            if slot(forPick: p, config: config) == userSlot { return p }
        }
        return nil
    }

    // Assign drafted players to lineup slots in draft order: dedicated
    // single-position slots first, then flex slots, then bench.
    static func assignRoster(_ myPlayers: [RankedPlayer], slots: [LineupSlot])
        -> (starters: [(slot: LineupSlot, player: RankedPlayer?)], bench: [RankedPlayer])
    {
        var starters: [(slot: LineupSlot, player: RankedPlayer?)] = slots.map { ($0, nil) }
        var bench: [RankedPlayer] = []

        for player in myPlayers {
            if let i = starters.firstIndex(where: { $0.player == nil && !$0.slot.isFlex && $0.slot.positions == [player.pos] }) {
                starters[i].player = player
            } else if let i = starters.firstIndex(where: { $0.player == nil && $0.slot.isFlex && $0.slot.positions.contains(player.pos) }) {
                starters[i].player = player
            } else {
                bench.append(player)
            }
        }
        return (starters, bench)
    }

    static func rosterGaps(
        starters: [(slot: LineupSlot, player: RankedPlayer?)], round: Int, rounds: Int
    ) -> [String] {
        var emptyByLabel: [String: Int] = [:]
        var labelOrder: [String] = []
        for entry in starters where entry.player == nil && !entry.slot.isFlex {
            if emptyByLabel[entry.slot.label] == nil { labelOrder.append(entry.slot.label) }
            emptyByLabel[entry.slot.label, default: 0] += 1
        }
        var gaps: [String] = []
        for label in labelOrder {
            let count = emptyByLabel[label] ?? 0
            if (label == "K" || label == "DST") && round < rounds - 3 { continue } // expected to be open early
            gaps.append(count > 1 ? "\(count) \(label) slots open" : "No \(label) drafted yet")
        }
        return gaps
    }

    static func byeWarnings(starters: [(slot: LineupSlot, player: RankedPlayer?)]) -> [String] {
        var byes: [Int: Int] = [:]
        for entry in starters {
            if let bye = entry.player?.bye { byes[bye, default: 0] += 1 }
        }
        return byes.filter { $0.value >= 3 }
            .sorted { $0.key < $1.key }
            .map { "\($0.value) of your starters have a week \($0.key) bye" }
    }
}
