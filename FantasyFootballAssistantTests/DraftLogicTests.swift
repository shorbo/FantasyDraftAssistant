import XCTest
@testable import FantasyFootballAssistant

final class DraftMathTests: XCTestCase {
    private func snakeConfig(reversalRound: Int = 0) -> DraftConfig {
        DraftConfig(
            draftId: "x", leagueId: nil, name: "Test", season: "2026", type: "snake",
            reversalRound: reversalRound, teams: 10, rounds: 15,
            slots: [], benchSize: 6, scoring: "ppr", userSlot: 3
        )
    }

    func testSnakeOrder() {
        let config = snakeConfig()
        XCTAssertEqual((1...10).map { DraftMath.slot(forPick: $0, config: config) }, Array(1...10))
        XCTAssertEqual((11...20).map { DraftMath.slot(forPick: $0, config: config) }, Array((1...10).reversed()))
        XCTAssertEqual(DraftMath.slot(forPick: 21, config: config), 1)
    }

    func testThirdRoundReversal() {
        let config = snakeConfig(reversalRound: 3)
        // r1 forward, r2 reverse, r3 reverse again, then alternating
        XCTAssertEqual(DraftMath.slot(forPick: 1, config: config), 1)
        XCTAssertEqual(DraftMath.slot(forPick: 11, config: config), 10)
        XCTAssertEqual(DraftMath.slot(forPick: 21, config: config), 10)
        XCTAssertEqual(DraftMath.slot(forPick: 31, config: config), 1)
    }

    func testNextUserPick() {
        let config = snakeConfig()
        XCTAssertEqual(DraftMath.nextUserPick(from: 1, config: config), 3)
        XCTAssertEqual(DraftMath.nextUserPick(from: 4, config: config), 18)
        XCTAssertNil(DraftMath.nextUserPick(from: 149, config: config)) // slot 3's last pick is 143
    }

    func testBuildConfigSlots() {
        let draft = SleeperDraft(
            draftId: "d1", leagueId: nil, season: "2026", type: "snake", status: "pre_draft",
            startTime: nil, created: nil,
            settings: SleeperDraftSettings(
                teams: 10, rounds: 15, reversalRound: 0, pickTimer: 60,
                slotsQB: 1, slotsRB: 2, slotsWR: 2, slotsTE: 1, slotsFlex: 1,
                slotsWRRBFlex: nil, slotsRecFlex: nil, slotsSuperFlex: nil,
                slotsK: 1, slotsDef: 1, slotsBench: 6
            ),
            metadata: SleeperDraftMetadata(name: "Mock", scoringType: "ppr"),
            draftOrder: ["u1": 4]
        )
        let config = DraftMath.buildConfig(draft: draft, userId: "u1")
        XCTAssertEqual(config.slots.map(\.key), ["QB", "RB1", "RB2", "WR1", "WR2", "TE", "FLEX", "K", "DST"])
        XCTAssertEqual(config.benchSize, 6)
        XCTAssertEqual(config.userSlot, 4)
        XCTAssertEqual(config.totalPicks, 150)
    }

    func testAssignRosterFillsDedicatedThenFlexThenBench() {
        let slots = [
            LineupSlot(key: "RB1", label: "RB", positions: [.rb]),
            LineupSlot(key: "RB2", label: "RB", positions: [.rb]),
            LineupSlot(key: "FLEX", label: "FLEX", positions: [.rb, .wr, .te]),
        ]
        let rbs = (1...4).map { i in
            RankedPlayer(id: i, rank: i, tier: 1, name: "RB \(i)", team: "T", pos: .rb, posRank: i, bye: nil)
        }
        let (starters, bench) = DraftMath.assignRoster(rbs, slots: slots)
        XCTAssertEqual(starters[0].player?.id, 1)
        XCTAssertEqual(starters[1].player?.id, 2)
        XCTAssertEqual(starters[2].player?.id, 3) // flex
        XCTAssertEqual(bench.map(\.id), [4])
    }
}

final class NameMatchingTests: XCTestCase {
    func testNormalization() {
        XCTAssertEqual(NameMatching.normalizeName("Marvin Harrison Jr."), "marvin harrison")
        XCTAssertEqual(NameMatching.normalizeName("D.J. Moore"), "dj moore")
        XCTAssertEqual(NameMatching.normalizeName("Amon-Ra St. Brown"), "amonra st brown")
        XCTAssertEqual(NameMatching.normalizeName("Ja'Marr Chase"), "jamarr chase")
        XCTAssertEqual(NameMatching.normalizeName("Hollywood Brown"), "marquise brown")
    }

    func testMatchByNameAndDstByTeam() {
        let db: [String: SleeperDbPlayer] = [
            "7564": SleeperDbPlayer(name: "Ja'Marr Chase", pos: .wr, team: "CIN", active: true),
            "PHI": SleeperDbPlayer(name: "Philadelphia Eagles", pos: .dst, team: "PHI", active: true),
        ]
        let players = [
            RankedPlayer(id: 1, rank: 1, tier: 1, name: "Ja'Marr Chase", team: "CIN", pos: .wr, posRank: 1, bye: 10),
            RankedPlayer(id: 2, rank: 2, tier: 1, name: "Philadelphia Eagles", team: "PHI", pos: .dst, posRank: 1, bye: 9),
            RankedPlayer(id: 3, rank: 3, tier: 1, name: "Nobody Real", team: "XX", pos: .qb, posRank: 1, bye: nil),
        ]
        let matched = NameMatching.match(players, to: db)
        XCTAssertEqual(matched[0].sleeperId, "7564")
        XCTAssertEqual(matched[1].sleeperId, "PHI")
        XCTAssertNil(matched[2].sleeperId)
    }

    func testDuplicateNamePrefersTeamThenActive() {
        let db: [String: SleeperDbPlayer] = [
            "1": SleeperDbPlayer(name: "Mike Williams", pos: .wr, team: "LAC", active: false),
            "2": SleeperDbPlayer(name: "Mike Williams", pos: .wr, team: "NYJ", active: true),
        ]
        let player = RankedPlayer(id: 1, rank: 50, tier: 5, name: "Mike Williams", team: "NYJ", pos: .wr, posRank: 20, bye: nil)
        XCTAssertEqual(NameMatching.match([player], to: db)[0].sleeperId, "2")
    }

    func testPickResolverFallsBackToNameThenStub() {
        let players = [
            RankedPlayer(id: 1, rank: 1, tier: 1, name: "Bijan Robinson", team: "ATL", pos: .rb, posRank: 1, bye: 5, sleeperId: "9509"),
            RankedPlayer(id: 2, rank: 2, tier: 1, name: "Justin Jefferson", team: "MIN", pos: .wr, posRank: 1, bye: 6, sleeperId: nil),
        ]
        let resolver = PickResolver(players: players)

        let byId = SleeperPick(pickNo: 1, round: 1, draftSlot: 1, playerId: "9509", pickedBy: nil, metadata: nil)
        XCTAssertEqual(resolver.resolve(byId).id, 1)

        let byName = SleeperPick(
            pickNo: 2, round: 1, draftSlot: 2, playerId: "111", pickedBy: nil,
            metadata: SleeperPickMetadata(firstName: "Justin", lastName: "Jefferson", position: "WR", team: "MIN")
        )
        XCTAssertEqual(resolver.resolve(byName).id, 2)

        let stub = SleeperPick(
            pickNo: 3, round: 1, draftSlot: 3, playerId: "999", pickedBy: nil,
            metadata: SleeperPickMetadata(firstName: "Deep", lastName: "Bench", position: "TE", team: "FA")
        )
        let resolved = resolver.resolve(stub)
        XCTAssertTrue(resolved.unranked)
        XCTAssertLessThan(resolved.id, 0)
        XCTAssertEqual(resolved.pos, .te)
    }

    func testPickResolverMatchesYahooInitialAndTeam() {
        let player = RankedPlayer(
            id: 1, rank: 1, tier: 1, name: "Omarion Hampton", team: "LAC", pos: .rb,
            posRank: 1, bye: 7
        )
        let resolver = PickResolver(players: [player])
        let pick = SleeperPick(
            pickNo: 16, round: 2, draftSlot: 4, playerId: "yahoo:16", pickedBy: nil,
            metadata: SleeperPickMetadata(firstName: "O.", lastName: "Hampton", position: "RB", team: "LAC")
        )
        XCTAssertEqual(resolver.resolve(pick).id, 1)
    }

    func testPickResolverDistinguishesYahooSuffixFromPlainInitial() {
        let bijan = RankedPlayer(
            id: 1, rank: 1, tier: 1, name: "Bijan Robinson", team: "ATL", pos: .rb,
            posRank: 1, bye: 5
        )
        let brian = RankedPlayer(
            id: 2, rank: 2, tier: 1, name: "Brian Robinson Jr.", team: "ATL", pos: .rb,
            posRank: 2, bye: 5
        )
        let resolver = PickResolver(players: [bijan, brian])
        let bijanPick = SleeperPick(
            pickNo: 1, round: 1, draftSlot: 1, playerId: "yahoo:1", pickedBy: nil,
            metadata: SleeperPickMetadata(firstName: "B.", lastName: "Robinson", position: "RB", team: "ATL")
        )
        let brianPick = SleeperPick(
            pickNo: 2, round: 1, draftSlot: 2, playerId: "yahoo:2", pickedBy: nil,
            metadata: SleeperPickMetadata(firstName: "B.", lastName: "Robinson Jr.", position: "RB", team: "ATL")
        )
        XCTAssertEqual(resolver.resolve(bijanPick).id, bijan.id)
        XCTAssertEqual(resolver.resolve(brianPick).id, brian.id)
    }
}

final class RankingsCSVTests: XCTestCase {
    func testParsesFantasyProsFormat() throws {
        let header = "\"RK\",\"TIERS\",\"PLAYER NAME\",\"TEAM\",\"POS\",\"BYE\",\"SOS SEASON\",\"ECR VS. ADP\""
        let rows = (1...120).map { i in
            "\"\(i)\",\"\(1 + i / 10)\",\"Player \(i)\",\"DAL\",\"WR\(i)\",\"7\",\"3 out of 5\",\"+2\""
        }
        let players = try RankingsCSV.parse(([header] + rows).joined(separator: "\n"))
        XCTAssertEqual(players.count, 120)
        XCTAssertEqual(players[0].name, "Player 1")
        XCTAssertEqual(players[0].pos, .wr)
        XCTAssertEqual(players[0].posRank, 1)
        XCTAssertEqual(players[0].bye, 7)
    }

    func testRejectsWrongColumns() {
        XCTAssertThrowsError(try RankingsCSV.parse("A,B,C\n1,2,3"))
    }

    // FantasyPros renamed "BYE" to "BYE Week" in some exports — either header
    // spelling (and casing) must parse identically.
    func testAcceptsByeWeekHeaderAlias() throws {
        let header = "\"RK\",\"TIERS\",\"PLAYER NAME\",\"TEAM\",\"POS\",\"BYE Week\""
        let rows = (1...120).map { i in
            "\"\(i)\",\"\(1 + i / 10)\",\"Player \(i)\",\"DAL\",\"WR\(i)\",\"9\""
        }
        let players = try RankingsCSV.parse(([header] + rows).joined(separator: "\n"))
        XCTAssertEqual(players.count, 120)
        XCTAssertEqual(players[0].bye, 9)
    }

    func testSkipsMalformedRowsAndDstParses() throws {
        let header = "RK,TIERS,PLAYER NAME,TEAM,POS,BYE"
        var rows = (1...110).map { "\($0),1,Player \($0),DAL,RB\($0),7" }
        rows.append("111,9,Denver Broncos,DEN,DST1,9")
        rows.append("not-a-rank,,,,,") // skipped
        let players = try RankingsCSV.parse(([header] + rows).joined(separator: "\n"))
        XCTAssertEqual(players.count, 111)
        XCTAssertEqual(players.last?.pos, .dst)
    }
}

final class RecommenderTests: XCTestCase {
    private var config: DraftConfig {
        DraftConfig(
            draftId: "x", leagueId: nil, name: "Test", season: "2026", type: "snake",
            reversalRound: 0, teams: 10, rounds: 15,
            slots: [
                LineupSlot(key: "QB", label: "QB", positions: [.qb]),
                LineupSlot(key: "RB", label: "RB", positions: [.rb]),
                LineupSlot(key: "K", label: "K", positions: [.k]),
            ],
            benchSize: 6, scoring: "ppr", userSlot: 1
        )
    }

    private func player(_ id: Int, rank: Int, pos: Position, tier: Int? = nil, team: String = "DAL") -> RankedPlayer {
        RankedPlayer(id: id, rank: rank, tier: tier, name: "P\(id)", team: team, pos: pos, posRank: nil, bye: nil)
    }

    func testTopByPositionReturnsTop3PerRosteredPositionByRank() {
        let available = [
            player(1, rank: 5, pos: .rb), player(2, rank: 1, pos: .rb),
            player(3, rank: 9, pos: .rb), player(4, rank: 12, pos: .rb),
            player(5, rank: 3, pos: .qb), player(6, rank: 20, pos: .qb),
            player(7, rank: 8, pos: .k),
            player(8, rank: 2, pos: .wr), // WR not rostered in this config
        ]
        let groups = Recommender.topByPosition(available: available, config: config, limit: 3)
        // config starts QB, RB, K — in that order, WR excluded.
        XCTAssertEqual(groups.map(\.pos), [.qb, .rb, .k])
        // RB sorted by rank, capped at 3 (drops the rank-12 RB).
        let rb = groups.first { $0.pos == .rb }!
        XCTAssertEqual(rb.players.map(\.id), [2, 1, 3])
        XCTAssertFalse(groups.contains { $0.pos == .wr })
    }

    func testTierCliffIdsFlagsLastInTier() {
        let available = [
            player(1, rank: 1, pos: .rb, tier: 1),
            player(2, rank: 2, pos: .rb, tier: 1),
            player(3, rank: 3, pos: .wr, tier: 1), // alone in WR tier 1 → cliff
            player(4, rank: 4, pos: .rb, tier: 2), // alone in RB tier 2 → cliff
        ]
        let cliffs = Recommender.tierCliffIds(available)
        XCTAssertEqual(cliffs, [3, 4])
    }
}

final class DraftGraderTests: XCTestCase {
    private func config(teams: Int, userSlot: Int) -> DraftConfig {
        DraftConfig(
            draftId: "x", leagueId: nil, name: "Test", season: "2026", type: "snake",
            reversalRound: 0, teams: teams, rounds: 2, slots: [], benchSize: 0,
            scoring: "ppr", userSlot: userSlot
        )
    }

    private func pick(_ no: Int, slot: Int, rank: Int?, mine: Bool) -> ResolvedPick {
        let p = RankedPlayer(id: no, rank: rank, tier: nil, name: "P\(no)", team: "DAL",
                             pos: .rb, posRank: nil, bye: nil)
        return ResolvedPick(pickNumber: no, slot: slot, player: p, isMine: mine)
    }

    func testValueDeltasAndLeader() {
        // 2-team, 2-round snake: slots pick 1,2,2,1.
        // Team 1 reaches; Team 2 gets value.
        let picks = [
            pick(1, slot: 1, rank: 3, mine: true),  // delta 1 - 3 = -2
            pick(2, slot: 2, rank: 1, mine: false), // delta 2 - 1 = +1
            pick(3, slot: 2, rank: 2, mine: false), // delta 3 - 2 = +1
            pick(4, slot: 1, rank: 10, mine: true), // delta 4 - 10 = -6
        ]
        let board = DraftGrader.grade(
            picks: picks, teamNames: ["Me", "Them"], unrankedRank: 500,
            config: config(teams: 2, userSlot: 1), projections: nil
        )
        XCTAssertEqual(board.count, 2)
        // Leader by value is Team 2 (+2) over Team 1 (−8).
        let leader = board.max { $0.totalValue < $1.totalValue }
        XCTAssertEqual(leader?.teamName, "Them")
        XCTAssertEqual(leader?.totalValue, 2)
        let me = board.first { $0.isMine }
        XCTAssertEqual(me?.totalValue, -8)
        // Biggest reach for my team is the rank-10 pick at #4 (delta -6).
        XCTAssertEqual(me?.worstPicks.first?.delta, -6)
    }

    func testUnrankedPlayerCountsAsReach() {
        let picks = [
            pick(1, slot: 1, rank: nil, mine: true), // unranked → effectiveRank 500, delta 1-500
            pick(2, slot: 2, rank: 2, mine: false),
        ]
        let board = DraftGrader.grade(
            picks: picks, teamNames: ["Me", "Them"], unrankedRank: 500,
            config: config(teams: 2, userSlot: 1), projections: nil
        )
        let me = board.first { $0.isMine }
        XCTAssertEqual(me?.picks.first?.effectiveRank, 500)
        XCTAssertEqual(me?.totalValue, 1 - 500)
    }

    func testProjectedPointsUsesBestStartingLineup() {
        // One QB slot + one FLEX (RB/WR/TE). A team with an elite QB and RB
        // should out-project a team of mediocre players.
        func rp(_ id: Int, pos: Position, posRank: Int) -> RankedPlayer {
            RankedPlayer(id: id, rank: id, tier: nil, name: "P\(id)", team: "DAL",
                         pos: pos, posRank: posRank, bye: nil)
        }
        func pk(_ no: Int, slot: Int, _ player: RankedPlayer) -> ResolvedPick {
            ResolvedPick(pickNumber: no, slot: slot, player: player, isMine: slot == 1)
        }
        let slots = [
            LineupSlot(key: "QB", label: "QB", positions: [.qb]),
            LineupSlot(key: "FLEX", label: "FLEX", positions: [.rb, .wr, .te]),
        ]
        var cfg = config(teams: 2, userSlot: 1)
        cfg = DraftConfig(
            draftId: cfg.draftId, leagueId: nil, name: cfg.name, season: cfg.season,
            type: cfg.type, reversalRound: 0, teams: 2, rounds: 2, slots: slots,
            benchSize: 0, scoring: "ppr", userSlot: 1
        )
        let picks = [
            pk(1, slot: 1, rp(1, pos: .qb, posRank: 1)),  // elite QB
            pk(2, slot: 2, rp(2, pos: .qb, posRank: 20)), // weak QB
            pk(3, slot: 2, rp(3, pos: .rb, posRank: 40)), // weak RB
            pk(4, slot: 1, rp(4, pos: .rb, posRank: 2)),  // strong RB
        ]
        let board = DraftGrader.grade(
            picks: picks, teamNames: ["Me", "Them"], unrankedRank: 500, config: cfg, projections: nil
        )
        let me = board.first { $0.isMine }!
        let them = board.first { !$0.isMine }!
        XCTAssertGreaterThan(me.projectedPoints, them.projectedPoints)
        // My lineup = QB1 + RB2 modeled projections (no table loaded).
        let expected = Projection.points(for: rp(1, pos: .qb, posRank: 1), using: nil)
            + Projection.points(for: rp(4, pos: .rb, posRank: 2), using: nil)
        XCTAssertEqual(me.projectedPoints, expected, accuracy: 0.001)
    }

    func testProjectionDecreasesWithPositionalRank() {
        let wr1 = RankedPlayer(id: 1, rank: 1, tier: nil, name: "A", team: "X", pos: .wr, posRank: 1, bye: nil)
        let wr30 = RankedPlayer(id: 2, rank: 60, tier: nil, name: "B", team: "Y", pos: .wr, posRank: 30, bye: nil)
        XCTAssertGreaterThan(Projection.modeled(for: wr1), Projection.modeled(for: wr30))
    }

    func testRealProjectionOverridesModeled() {
        var table = ProjectionTable()
        table.add(name: "Josh Allen", team: "BUF", fpts: 372.1)
        let allen = RankedPlayer(id: 1, rank: 15, tier: 2, name: "Josh Allen", team: "BUF",
                                 pos: .qb, posRank: 1, bye: 7)
        XCTAssertEqual(Projection.points(for: allen, using: table), 372.1, accuracy: 0.001)
        // A player absent from the table falls back to the modeled curve.
        let other = RankedPlayer(id: 2, rank: 40, tier: 4, name: "Some Back", team: "DAL",
                                 pos: .rb, posRank: 10, bye: 9)
        XCTAssertEqual(Projection.points(for: other, using: table), Projection.modeled(for: other), accuracy: 0.001)
    }
}

final class ProjectionsCSVTests: XCTestCase {
    func testParsesFantasyProsQBFormatAndSkipsVarianceRows() throws {
        let text = """
        "Player","Team","ATT","CMP","YDS","TDS","INTS","ATT","YDS","TDS","FL","FPTS"
        " ","","",""
        "Josh Allen","BUF","491.7","333.1","3,812.5","27.4","11.2","118.1","585.5","11.8","4.1","372.1"
        "","low","479.0","326.0","3,705.0","26.0","13.0","113.0","567.0","11.0","4.2","369.2"
        "Drake Maye","NE","504.3","346.0","4,064.2","28.3","10.4","100.3","505.2","3.7","5.6","326.9"
        """
        let rows = try ProjectionsCSV.parse(text)
        XCTAssertEqual(rows.count, 2) // variance row skipped
        XCTAssertEqual(rows[0].name, "Josh Allen")
        XCTAssertEqual(rows[0].fpts, 372.1, accuracy: 0.001)
        XCTAssertEqual(rows[1].name, "Drake Maye")
    }

    func testTableLookupByNameAndTeam() {
        var table = ProjectionTable()
        table.add(name: "Josh Allen", team: "BUF", fpts: 372.1)
        let p = RankedPlayer(id: 1, rank: 1, tier: 1, name: "Josh Allen", team: "BUF",
                             pos: .qb, posRank: 1, bye: 7)
        XCTAssertEqual(table.points(for: p), 372.1)
    }

    func testRejectsFileWithoutFptsColumn() {
        XCTAssertThrowsError(try ProjectionsCSV.parse("Player,Team,YDS\nA,B,100"))
    }

    // FantasyPros exports use CRLF; Swift treats "\r\n" as one Character, so
    // the row parser must terminate on it (regression guard).
    func testHandlesCRLFLineEndings() throws {
        let text = "\"Player\",\"Team\",\"FPTS\"\r\n\"Josh Allen\",\"BUF\",\"372.1\"\r\n\"Drake Maye\",\"NE\",\"326.9\"\r\n"
        let rows = try ProjectionsCSV.parse(text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "Josh Allen")
        XCTAssertEqual(rows[0].fpts, 372.1, accuracy: 0.001)
    }
}

final class AIAdvisorTests: XCTestCase {
    // Streaming: OpenRouter withholds all bytes until generation finishes on
    // a non-streaming request, which can exceed any idle timeout on a slow
    // model even though it would have succeeded. SSE parsing is what avoids
    // that — verify it end-to-end on synthetic chunks.
    func testParsesSSEContentDeltas() throws {
        XCTAssertEqual(try AIAdvisor.parseSSELine(#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#), "Hel")
        XCTAssertEqual(try AIAdvisor.parseSSELine(#"data: {"choices":[{"delta":{"content":"lo"}}]}"#), "lo")
    }

    func testIgnoresBlankCommentAndDoneLines() throws {
        XCTAssertNil(try AIAdvisor.parseSSELine(""))
        XCTAssertNil(try AIAdvisor.parseSSELine(": keep-alive"))
        XCTAssertNil(try AIAdvisor.parseSSELine("data: [DONE]"))
        XCTAssertNil(try AIAdvisor.parseSSELine("data: {}")) // no delta content
    }

    func testThrowsOnSSEErrorChunk() {
        XCTAssertThrowsError(try AIAdvisor.parseSSELine(#"data: {"error":{"message":"rate limited"}}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("rate limited"))
        }
    }

    func testParsesStructuredJSON() {
        let text = #"{"pickId": 8, "rule": 2, "why": "Last elite TE with positive VORP.", "alternates": [{"id": 12, "reason": "Best value."}], "ifSniped": "Take player 15."}"#
        let advice = AIAdvisor.parse(text)
        XCTAssertEqual(advice?.pickId, 8)
        XCTAssertEqual(advice?.rule, 2)
        XCTAssertEqual(advice?.alternates.map(\.id), [12])
        XCTAssertEqual(advice?.ifSniped, "Take player 15.")
    }

    func testParsesJSONWrappedInProseOrFence() {
        let text = """
        Here's my pick:
        ```json
        {"pickId": 3, "rule": 3, "why": "Highest VORP unlikely to survive.", "alternates": []}
        ```
        """
        let advice = AIAdvisor.parse(text)
        XCTAssertEqual(advice?.pickId, 3)
        XCTAssertEqual(advice?.rule, 3)
        XCTAssertNil(advice?.ifSniped)
    }

    func testRejectsGarbage() {
        XCTAssertNil(AIAdvisor.parse("no json here"))
        XCTAssertNil(AIAdvisor.parse(#"{"pickId": 3, "alternates": []}"#)) // missing "why"
    }

    private func fourTeamConfig() -> DraftConfig {
        DraftConfig(
            draftId: "x", leagueId: nil, name: "Test", season: "2026", type: "snake",
            reversalRound: 0, teams: 4, rounds: 5,
            slots: [
                LineupSlot(key: "QB", label: "QB", positions: [.qb]),
                LineupSlot(key: "RB", label: "RB", positions: [.rb]),
            ],
            benchSize: 3, scoring: "ppr", userSlot: 2
        )
    }

    func testPromptIncludesAnnotatedBoardAndDecisionProcedure() {
        let config = fourTeamConfig()
        let qb = RankedPlayer(id: 1, rank: 1, tier: 1, name: "Josh Allen", team: "BUF", pos: .qb, posRank: 1, bye: 7, adp: 3)
        let rb = RankedPlayer(id: 2, rank: 2, tier: 1, name: "Bijan Robinson", team: "ATL", pos: .rb, posRank: 1, bye: 5, adp: 2)
        let picks = [ResolvedPick(pickNumber: 1, slot: 1, player: rb, isMine: false)]
        let prompt = AIAdvisor.buildPrompt(
            config: config, currentPick: 2, nextUserPick: 2, myPlayers: [],
            available: [qb], picks: picks, teamNames: ["A", "Me", "C", "D"],
            allPlayers: [qb, rb], projections: nil, projectionsAreReal: false
        )
        XCTAssertTrue(prompt.contains("ON THE CLOCK"))
        XCTAssertTrue(prompt.contains("id=1"))
        XCTAssertTrue(prompt.contains("VORP"))
        XCTAssertTrue(prompt.contains("DECISION PROCEDURE"))
        XCTAssertTrue(prompt.contains("ROUND-PHASE STRATEGY"))
        XCTAssertTrue(prompt.contains("SYNTHETIC")) // modeled-projection provenance flag
        XCTAssertTrue(prompt.contains("4-team full-PPR snake draft"))
        // Regression: the model's training data can be stale on which team a
        // player is currently on, which breaks team-dependent reasoning like
        // handcuffs — the prompt must anchor it to the season and the fresh
        // `team` field rather than recalled knowledge.
        XCTAssertTrue(prompt.contains("2026 NFL season"))
        XCTAssertTrue(prompt.contains("handcuffs"))
        XCTAssertTrue(prompt.contains("training data may be stale"))
    }

    func testChatPromptIncludesHistoryAndQuestionNotDecisionProcedure() {
        let config = fourTeamConfig()
        let qb = RankedPlayer(id: 1, rank: 1, tier: 1, name: "Josh Allen", team: "BUF", pos: .qb, posRank: 1, bye: 7, adp: 3)
        let history = [
            ChatMessage(role: .user, text: "Should I wait on QB?"),
            ChatMessage(role: .assistant, text: "You can wait one more round."),
        ]
        let prompt = AIAdvisor.buildChatPrompt(
            config: config, currentPick: 1, nextUserPick: 5, myPlayers: [], available: [qb],
            picks: [], teamNames: ["A", "Me", "C", "D"], allPlayers: [qb],
            projections: nil, projectionsAreReal: false, history: history, question: "What about now?"
        )
        XCTAssertTrue(prompt.contains("CONVERSATION SO FAR"))
        XCTAssertTrue(prompt.contains("Should I wait on QB?"))
        XCTAssertTrue(prompt.contains("MY QUESTION: What about now?"))
        XCTAssertFalse(prompt.contains("DECISION PROCEDURE"))
    }
}

final class DraftAnalyticsTests: XCTestCase {
    // 10-team, QB/2RB/2WR/TE/2FLEX/K/DST — the spec's target shape.
    private func standardConfig() -> DraftConfig {
        DraftConfig(
            draftId: "x", leagueId: nil, name: "T", season: "2026", type: "snake",
            reversalRound: 0, teams: 10, rounds: 15,
            slots: [
                LineupSlot(key: "QB", label: "QB", positions: [.qb]),
                LineupSlot(key: "RB1", label: "RB", positions: [.rb]),
                LineupSlot(key: "RB2", label: "RB", positions: [.rb]),
                LineupSlot(key: "WR1", label: "WR", positions: [.wr]),
                LineupSlot(key: "WR2", label: "WR", positions: [.wr]),
                LineupSlot(key: "TE", label: "TE", positions: [.te]),
                LineupSlot(key: "FLEX1", label: "FLEX", positions: [.rb, .wr, .te]),
                LineupSlot(key: "FLEX2", label: "FLEX", positions: [.rb, .wr, .te]),
                LineupSlot(key: "K", label: "K", positions: [.k]),
                LineupSlot(key: "DST", label: "DST", positions: [.dst]),
            ],
            benchSize: 5, scoring: "ppr", userSlot: 1
        )
    }

    func testReplacementRanksMatchSpec() {
        let ranks = DraftAnalytics.replacementRanks(config: standardConfig(), cfg: .default)
        XCTAssertEqual(ranks[.qb], 12) // 10 starters + 2 buffer
        XCTAssertEqual(ranks[.rb], 28) // 20 + 8 flex share (0.40*20)
        XCTAssertEqual(ranks[.wr], 31) // 20 + 11 flex share (0.55*20)
        XCTAssertEqual(ranks[.te], 11) // 10 + 1 flex share (0.05*20)
        XCTAssertEqual(ranks[.k], 11)
        XCTAssertEqual(ranks[.dst], 11)
    }

    func testSurvivalCurveBreakpoints() {
        let cfg = AnalyticsConfig.default
        // z = (adp − pick) − g. Pick 10, g 20 → my next pick at 30.
        // adp 46 → d=36, z=+16 (≥8) → ~95%.
        XCTAssertEqual(DraftAnalytics.baseSurvival(adp: 46, currentPick: 10, g: 20, cfg: cfg), 0.95, accuracy: 0.001)
        // adp 30 → d=20, z=0 → 50%.
        XCTAssertEqual(DraftAnalytics.baseSurvival(adp: 30, currentPick: 10, g: 20, cfg: cfg), 0.50, accuracy: 0.001)
        // adp 22 → d=12, z=−8 → 10%.
        XCTAssertEqual(DraftAnalytics.baseSurvival(adp: 22, currentPick: 10, g: 20, cfg: cfg), 0.10, accuracy: 0.001)
    }

    func testVORPIsProjectionMinusReplacement() throws {
        let config = standardConfig()
        // 40 QBs with descending projections 400,399,...; QB12 (index 11) = 389.
        let qbs = (0..<40).map {
            RankedPlayer(id: $0 + 1, rank: $0 + 1, tier: 1, name: "QB\($0)", team: "X",
                         pos: .qb, posRank: $0 + 1, bye: 7, adp: Double($0 + 1))
        }
        var table = ProjectionTable()
        for (i, p) in qbs.enumerated() { table.add(name: p.name, team: p.team, fpts: Double(400 - i)) }

        let analysis = DraftAnalytics.compute(
            config: config, currentPick: 1, nextUserPick: 3, myPlayers: [],
            available: qbs, picks: [], allPlayers: qbs, projections: table
        )
        XCTAssertEqual(try XCTUnwrap(analysis.replacementPts[.qb]), 389, accuracy: 0.001)
        // Top QB projects 400 → VORP 11 over replacement.
        XCTAssertEqual(try XCTUnwrap(analysis.annotation(for: qbs[0])?.vorp), 11, accuracy: 0.001)
    }

    func testCapacityCountsAllStartingSlotsIncludingFlex() {
        let config = standardConfig()
        // Empty roster: all 10 starting slots (incl. both flex) are empty.
        let analysis = DraftAnalytics.compute(
            config: config, currentPick: 1, nextUserPick: 2, myPlayers: [],
            available: [], picks: [], allPlayers: [], projections: nil
        )
        XCTAssertEqual(analysis.emptyStartingSlots, 10)
    }
}
