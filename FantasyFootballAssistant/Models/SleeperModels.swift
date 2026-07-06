import Foundation

struct SleeperUser: Codable, Sendable {
    var userId: String
    var username: String?
    var displayName: String?

    var nameForDisplay: String { displayName ?? username ?? userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case displayName = "display_name"
    }
}

struct SleeperDraftSettings: Codable, Sendable {
    var teams: Int?
    var rounds: Int?
    var reversalRound: Int?
    var pickTimer: Int?
    var slotsQB: Int?
    var slotsRB: Int?
    var slotsWR: Int?
    var slotsTE: Int?
    var slotsFlex: Int?
    var slotsWRRBFlex: Int?
    var slotsRecFlex: Int?
    var slotsSuperFlex: Int?
    var slotsK: Int?
    var slotsDef: Int?
    var slotsBench: Int?

    enum CodingKeys: String, CodingKey {
        case teams, rounds
        case reversalRound = "reversal_round"
        case pickTimer = "pick_timer"
        case slotsQB = "slots_qb"
        case slotsRB = "slots_rb"
        case slotsWR = "slots_wr"
        case slotsTE = "slots_te"
        case slotsFlex = "slots_flex"
        case slotsWRRBFlex = "slots_wrrb_flex"
        case slotsRecFlex = "slots_rec_flex"
        case slotsSuperFlex = "slots_super_flex"
        case slotsK = "slots_k"
        case slotsDef = "slots_def"
        case slotsBench = "slots_bn"
    }
}

struct SleeperDraftMetadata: Codable, Sendable {
    var name: String?
    var scoringType: String?

    enum CodingKeys: String, CodingKey {
        case name
        case scoringType = "scoring_type"
    }
}

struct SleeperDraft: Codable, Sendable {
    var draftId: String
    var leagueId: String?
    var season: String?
    var type: String?
    var status: String? // pre_draft | drafting | paused | complete
    var startTime: Int?
    var created: Int?
    var settings: SleeperDraftSettings?
    var metadata: SleeperDraftMetadata?
    var draftOrder: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case draftId = "draft_id"
        case leagueId = "league_id"
        case season, type, status, settings, metadata
        case startTime = "start_time"
        case created
        case draftOrder = "draft_order"
    }
}

struct SleeperPickMetadata: Codable, Sendable {
    var firstName: String?
    var lastName: String?
    var position: String?
    var team: String?

    enum CodingKeys: String, CodingKey {
        case firstName = "first_name"
        case lastName = "last_name"
        case position, team
    }
}

struct SleeperPick: Codable, Sendable {
    var pickNo: Int
    var round: Int?
    var draftSlot: Int
    var playerId: String
    var pickedBy: String?
    var metadata: SleeperPickMetadata?

    enum CodingKeys: String, CodingKey {
        case pickNo = "pick_no"
        case round
        case draftSlot = "draft_slot"
        case playerId = "player_id"
        case pickedBy = "picked_by"
        case metadata
    }
}

struct SleeperLeagueUser: Codable, Sendable {
    var userId: String
    var displayName: String?
    var username: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case username
    }
}

// Trimmed entry from the ~5MB players/nfl dump; only what matching needs.
struct SleeperDbPlayer: Codable, Sendable {
    var name: String
    var pos: Position
    var team: String?
    var active: Bool
}
