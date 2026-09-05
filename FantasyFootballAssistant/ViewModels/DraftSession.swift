import Foundation
import Observation

enum AdviceState {
    case idle
    case syncing
    case loading(forPick: Int)
    case ready(forPick: Int, advice: AIAdvice)
    case error(String)
}

enum ChatState {
    case idle
    case syncing
    case loading
    case error(String)
}

// Live-syncs a draft and derives everything the draft screen shows. Sleeper
// polls its public API; Yahoo receives local browser-extension events.
@MainActor
@Observable
final class DraftSession {
    let players: [RankedPlayer]
    let config: DraftConfig
    let userId: String
    private(set) var teamNames: [String]
    let projections: ProjectionTable?
    let source: DraftSource

    private(set) var draft: SleeperDraft
    private(set) var rawPicks: [SleeperPick] = []
    private(set) var syncError: String?
    private(set) var lastSync: Date?
    private(set) var adviceState: AdviceState = .idle
    private(set) var adviceStartedAt: Date?
    private(set) var adviceStreamedChars: Int = 0 // raw JSON isn't shown, just a "receiving" signal
    private(set) var chatMessages: [ChatMessage] = []
    private(set) var chatState: ChatState = .idle
    private(set) var chatStartedAt: Date?
    private(set) var chatStreamText: String = "" // live partial answer, rendered as it streams in

    private let resolver: PickResolver
    private var pollTask: Task<Void, Never>?
    private var adviceTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var yahooReceiver: YahooPickReceiver?

    private static let pollSeconds: Double = 3
    private static let draftRefreshTicks = 5

    init(
        players: [RankedPlayer],
        draft: SleeperDraft,
        config: DraftConfig,
        userId: String,
        teamNames: [String],
        projections: ProjectionTable?,
        source: DraftSource = .sleeper
    ) {
        self.players = players
        self.draft = draft
        self.config = config
        self.userId = userId
        self.teamNames = teamNames
        self.projections = projections
        self.source = source
        self.resolver = PickResolver(players: players)

        if source == .sleeper {
            SessionStore.save(SavedSession(
                draftId: config.draftId,
                draftName: config.name,
                userId: userId,
                players: players,
                teamNames: teamNames,
                projections: projections,
                savedAt: Date()
            ))
        }
    }

    // MARK: - Derived state

    var status: String {
        guard source == .yahoo else { return draft.status ?? "pre_draft" }
        if config.totalPicks > 0 && rawPicks.count >= config.totalPicks { return "complete" }
        return rawPicks.isEmpty ? "pre_draft" : "drafting"
    }

    // draft_slot (not picked_by) decides ownership so autopicked players
    // still land on the right roster.
    var picks: [ResolvedPick] {
        rawPicks.map {
            ResolvedPick(
                pickNumber: $0.pickNo,
                slot: $0.draftSlot,
                player: resolver.resolve($0),
                isMine: $0.draftSlot == config.userSlot
            )
        }
    }

    var currentPick: Int { rawPicks.count + 1 }
    var clampedPick: Int { min(currentPick, max(config.totalPicks, 1)) }
    var complete: Bool { status == "complete" || rawPicks.count >= config.totalPicks }
    var onClockSlot: Int? { complete ? nil : DraftMath.slot(forPick: clampedPick, config: config) }
    var nextUserPickNumber: Int? { DraftMath.nextUserPick(from: currentPick, config: config) }

    var draftedIds: Set<Int> { Set(picks.map(\.player.id)) }
    var myPlayers: [RankedPlayer] { picks.filter(\.isMine).map(\.player) }
    var available: [RankedPlayer] {
        let drafted = draftedIds
        return players.filter { !drafted.contains($0.id) }
    }

    var roster: (starters: [(slot: LineupSlot, player: RankedPlayer?)], bench: [RankedPlayer]) {
        DraftMath.assignRoster(myPlayers, slots: config.slots)
    }

    var rosterGaps: [String] {
        DraftMath.rosterGaps(
            starters: roster.starters,
            round: DraftMath.round(forPick: clampedPick, teams: config.teams),
            rounds: config.rounds
        )
    }

    var byeWarnings: [String] { DraftMath.byeWarnings(starters: roster.starters) }

    // Top available by consensus rank at each position the league starts.
    var recommendations: [Recommender.PositionGroup] {
        Recommender.topByPosition(available: available, config: config, limit: 3)
    }

    // Ids of players who are the last available in their positional tier —
    // flagged as a tier cliff in the recommendations.
    var tierCliffIds: Set<Int> { Recommender.tierCliffIds(available) }

    // End-of-draft leaderboard: each team scored by value over consensus rank
    // and by projected starting-lineup points.
    var leaderboard: [TeamGrade] {
        let unrankedRank = (players.compactMap(\.rank).max() ?? players.count) + 1
        return DraftGrader.grade(
            picks: picks, teamNames: teamNames, unrankedRank: unrankedRank,
            config: config, projections: projections
        )
    }

    var hasRealProjections: Bool { !(projections?.isEmpty ?? true) }

    func teamName(forSlot slot: Int) -> String {
        if slot >= 1, slot <= teamNames.count { return teamNames[slot - 1] }
        return "Team \(slot)"
    }

    // MARK: - Polling

    func startPolling() {
        if source == .yahoo {
            startYahooReceiver()
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.syncNow()
                if self.status == "complete" { return }
                try? await Task.sleep(for: .seconds(Self.pollSeconds))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        adviceTask?.cancel()
        adviceTask = nil
        chatTask?.cancel()
        chatTask = nil
        yahooReceiver?.stop()
        yahooReceiver = nil
    }

    // MARK: - AI Advisor (on demand only — never auto-triggered)

    var hasAdvisorKey: Bool {
        !(UserDefaults.standard.string(forKey: "openRouterApiKey") ?? "")
            .trimmingCharacters(in: .whitespaces).isEmpty
    }

    // Only forwarded to OpenRouter when the currently selected model's
    // catalog entry actually advertises support for it.
    private func currentReasoningEffort(for model: String) -> String? {
        let effort = (UserDefaults.standard.string(forKey: "openRouterReasoningEffort") ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !effort.isEmpty else { return nil }
        let usedModel = model.isEmpty ? AIAdvisor.defaultModel : model
        guard OpenRouterModelCache.shared.info(for: usedModel)?.supportsReasoning == true else { return nil }
        return effort
    }

    // Forces a fresh sync before asking, so advice is never built from picks
    // that are a poll cycle stale — then builds the prompt from that
    // just-confirmed state.
    func askAdvisor() {
        switch adviceState {
        case .syncing, .loading: return
        default: break
        }
        let apiKey = (UserDefaults.standard.string(forKey: "openRouterApiKey") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let model = (UserDefaults.standard.string(forKey: "openRouterModel") ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !apiKey.isEmpty else {
            adviceState = .error("Add your OpenRouter API key on the setup screen first.")
            return
        }

        adviceTask?.cancel()
        adviceState = .syncing
        adviceStartedAt = Date()
        adviceStreamedChars = 0
        adviceTask = Task { [weak self] in
            guard let self else { return }
            await self.syncNow()
            guard !Task.isCancelled else { return }

            guard !self.available.isEmpty else {
                self.adviceState = .idle
                return
            }
            let forPick = self.currentPick
            let prompt = AIAdvisor.buildPrompt(
                config: self.config,
                currentPick: self.clampedPick,
                nextUserPick: self.nextUserPickNumber,
                myPlayers: self.myPlayers,
                available: self.available,
                picks: self.picks,
                teamNames: self.teamNames,
                allPlayers: self.players,
                projections: self.projections,
                projectionsAreReal: self.hasRealProjections
            )
            self.adviceState = .loading(forPick: forPick)
            let reasoningEffort = self.currentReasoningEffort(for: model)
            do {
                let advice = try await AIAdvisor.advise(
                    apiKey: apiKey, model: model, reasoningEffort: reasoningEffort, prompt: prompt,
                    onDelta: { [weak self] delta in
                        Task { @MainActor in self?.adviceStreamedChars += delta.count }
                    }
                )
                guard !Task.isCancelled else { return }
                self.adviceState = .ready(forPick: forPick, advice: advice)
            } catch {
                guard !Task.isCancelled else { return }
                self.adviceState = .error(error.localizedDescription)
            }
        }
    }

    // Stops an in-flight advisor request (sync or LLM call) and returns to idle.
    func cancelAdvisor() {
        adviceTask?.cancel()
        adviceTask = nil
        adviceStartedAt = nil
        adviceStreamedChars = 0
        adviceState = .idle
    }

    // MARK: - AI Chat (follow-up questions, same context as the advisor)

    func sendChatMessage(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        switch chatState {
        case .syncing, .loading: return
        default: break
        }
        let apiKey = (UserDefaults.standard.string(forKey: "openRouterApiKey") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let model = (UserDefaults.standard.string(forKey: "openRouterModel") ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !apiKey.isEmpty else {
            chatState = .error("Add your OpenRouter API key on the setup screen first.")
            return
        }

        chatMessages.append(ChatMessage(role: .user, text: question))
        let history = Array(chatMessages.dropLast())
        chatTask?.cancel()
        chatState = .syncing
        chatStartedAt = Date()
        chatStreamText = ""
        chatTask = Task { [weak self] in
            guard let self else { return }
            await self.syncNow()
            guard !Task.isCancelled else { return }

            let prompt = AIAdvisor.buildChatPrompt(
                config: self.config,
                currentPick: self.clampedPick,
                nextUserPick: self.nextUserPickNumber,
                myPlayers: self.myPlayers,
                available: self.available,
                picks: self.picks,
                teamNames: self.teamNames,
                allPlayers: self.players,
                projections: self.projections,
                projectionsAreReal: self.hasRealProjections,
                history: history,
                question: question
            )
            self.chatState = .loading
            let reasoningEffort = self.currentReasoningEffort(for: model)
            do {
                let answer = try await AIAdvisor.chat(
                    apiKey: apiKey, model: model, reasoningEffort: reasoningEffort, prompt: prompt,
                    onDelta: { [weak self] delta in
                        Task { @MainActor in self?.chatStreamText += delta }
                    }
                )
                guard !Task.isCancelled else { return }
                self.chatMessages.append(ChatMessage(role: .assistant, text: answer))
                self.chatState = .idle
                self.chatStreamText = ""
            } catch {
                guard !Task.isCancelled else { return }
                self.chatMessages.append(ChatMessage(role: .error, text: error.localizedDescription))
                self.chatState = .idle
                self.chatStreamText = ""
            }
        }
    }

    func cancelChat() {
        chatTask?.cancel()
        chatTask = nil
        chatStartedAt = nil
        chatStreamText = ""
        chatState = .idle
    }

    func clearChat() {
        cancelChat()
        chatMessages = []
    }

    // Immediate out-of-band sync (also refreshes draft status).
    func refreshNow() {
        if source == .sleeper { Task { await syncNow() } }
    }

    private func startYahooReceiver() {
        guard yahooReceiver == nil else { return }
        let receiver = YahooPickReceiver()
        receiver.onPick = { [weak self] event in
            Task { @MainActor in self?.receiveYahooPick(event) }
        }
        do {
            try receiver.start()
            yahooReceiver = receiver
            syncError = nil
            lastSync = Date()
        } catch {
            syncError = "Could not start Yahoo receiver on 127.0.0.1:\(YahooPickReceiver.port): \(error.localizedDescription)"
        }
    }

    private func receiveYahooPick(_ event: YahooDraftPickEvent) {
        guard source == .yahoo, event.pick <= config.totalPicks, !rawPicks.contains(where: { $0.pickNo == event.pick }) else { return }
        let slot = event.draftSlot ?? DraftMath.slot(forPick: event.pick, config: config)
        guard slot >= 1, slot <= config.teams else { return }
        if let name = event.fantasyTeam?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
           slot <= teamNames.count {
            teamNames[slot - 1] = name
        }
        let words = event.playerName.split(separator: " ", maxSplits: 1).map(String.init)
        let pick = SleeperPick(
            pickNo: event.pick,
            round: event.round ?? DraftMath.round(forPick: event.pick, teams: config.teams),
            draftSlot: slot,
            playerId: "yahoo:\(event.pick)",
            pickedBy: nil,
            metadata: SleeperPickMetadata(
                firstName: words.first,
                lastName: words.count > 1 ? words[1] : nil,
                position: event.position,
                team: event.nflTeam
            )
        )
        rawPicks.append(pick)
        rawPicks.sort { $0.pickNo < $1.pickNo }
        lastSync = Date()
        syncError = nil
    }

    // Coalesces concurrent sync requests (the background poll and an
    // on-demand refresh/advisor call) onto a single in-flight fetch, so a
    // caller that awaits this always sees the result of a real completed
    // sync rather than a no-op skipped because one was already running.
    private var inFlightSync: Task<Void, Never>?
    private var syncTicks = 0

    private func syncNow() async {
        if let inFlightSync {
            await inFlightSync.value
            return
        }
        let ticks = syncTicks
        syncTicks += 1
        let task = Task { await self.performSync(ticks) }
        inFlightSync = task
        await task.value
        inFlightSync = nil
    }

    private func performSync(_ n: Int) async {
        guard source == .sleeper else { return }
        do {
            let latest = try await SleeperAPI.draftPicks(config.draftId)
            rawPicks = latest.sorted { $0.pickNo < $1.pickNo }
            lastSync = Date()
            syncError = nil

            let looksDone = config.totalPicks > 0 && latest.count >= config.totalPicks
            if status != "complete", looksDone || n.isMultiple(of: Self.draftRefreshTicks) {
                if let fresh = try await SleeperAPI.draft(config.draftId) { draft = fresh }
            }
        } catch {
            syncError = error.localizedDescription
        }
    }
}
