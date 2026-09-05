import XCTest
@testable import FantasyFootballAssistant

final class YahooIntegrationTests: XCTestCase {
    func testEventDecodesAndValidates() throws {
        let json = #"""
        {
          "source": "yahoo", "pick": 17, "round": 2, "draft_slot": 4,
          "fantasy_team": "Team Foo", "player_name": "Amon-Ra St. Brown",
          "position": "WR", "nfl_team": "DET"
        }
        """#
        let event = try JSONDecoder().decode(YahooDraftPickEvent.self, from: Data(json.utf8))
        XCTAssertNoThrow(try event.validate())
        XCTAssertEqual(event.pick, 17)
        XCTAssertEqual(event.playerName, "Amon-Ra St. Brown")
    }

    func testEventRejectsWrongSourceAndMissingPlayer() throws {
        let wrongSource = YahooDraftPickEvent(
            source: "sleeper", pick: 1, round: nil, draftSlot: nil, fantasyTeam: nil,
            playerName: "Player", position: nil, nflTeam: nil
        )
        XCTAssertThrowsError(try wrongSource.validate())
        let missingPlayer = YahooDraftPickEvent(
            source: "yahoo", pick: 1, round: nil, draftSlot: nil, fantasyTeam: nil,
            playerName: "  ", position: nil, nflTeam: nil
        )
        XCTAssertThrowsError(try missingPlayer.validate())
    }
}
