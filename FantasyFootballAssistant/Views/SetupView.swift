import SwiftUI
import UniformTypeIdentifiers

private let statusLabels: [String: String] = [
    "pre_draft": "not started",
    "drafting": "LIVE",
    "paused": "paused",
    "complete": "complete",
]

struct SetupView: View {
    var onStart: (DraftSession) -> Void

    // rankings
    @State private var players: [RankedPlayer]?
    @State private var fileName = ""
    @State private var fileError: String?
    @State private var showFileImporter = false

    // projections (optional, one or more FantasyPros per-position exports)
    @State private var projections: ProjectionTable?
    @State private var projectionsSummary: String?
    @State private var projectionsError: String?
    @State private var showProjectionsImporter = false

    // sleeper player db (background load, used for rankings ↔ sleeper matching)
    @State private var playersDb: [String: SleeperDbPlayer]?

    // sleeper connection
    @State private var username = ""
    @State private var season = SleeperAPI.currentSeason
    @State private var user: SleeperUser?
    @State private var drafts: [SleeperDraft]?
    @State private var findLoading = false
    @State private var draftInput = ""
    @State private var selectedDraft: SleeperDraft?
    @State private var draftLoading = false
    @State private var sleeperError: String?
    @State private var manualSlot = 1

    // AI advisor (on-demand, optional)
    @AppStorage("openRouterApiKey") private var openRouterApiKey = ""
    @AppStorage("openRouterModel") private var openRouterModel = AIAdvisor.defaultModel
    @State private var keyValidation: KeyValidationState = .idle
    @State private var keyValidationTask: Task<Void, Never>?
    @State private var showModelPicker = false
    @State private var modelSearch = ""

    private enum KeyValidationState {
        case idle, validating
        case valid(label: String?)
        case invalid(String)
    }

    @State private var savedSession: SavedSession?
    @State private var resuming = false
    @State private var resumeError: String?
    @State private var starting = false
    @State private var startError: String?

    private var matchedPlayers: [RankedPlayer]? {
        guard let players else { return nil }
        guard let playersDb else { return players }
        return NameMatching.match(players, to: playersDb)
    }

    private var unmatched: [RankedPlayer] {
        guard playersDb != nil, let matchedPlayers else { return [] }
        return matchedPlayers.filter { $0.sleeperId == nil }
    }

    private var draftOrderSlot: Int? {
        guard let selectedDraft, let user else { return nil }
        return selectedDraft.draftOrder?[user.userId]
    }

    private var unsupportedType: Bool { selectedDraft?.type == "auction" }

    private var canStart: Bool {
        players != nil && selectedDraft != nil && user != nil && !unsupportedType && !starting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("🏈 Fantasy Football Assistant").font(.title).bold()
                    Text("Draft assistant · live-synced with your Sleeper draft")
                        .foregroundStyle(.secondary)
                }

                if let saved = savedSession { resumeBanner(saved) }

                rankingsSection
                projectionsSection
                sleeperSection
                advisorSection

                if let startError {
                    Text(startError).foregroundStyle(.red)
                }

                Button(starting ? "Connecting…" : "Connect to draft") { start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canStart)
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .task {
            savedSession = SessionStore.load()
            playersDb = try? await SleeperAPI.loadPlayersDb()
            await OpenRouterModelCache.shared.ensureLoaded()
            if !openRouterApiKey.isEmpty { scheduleKeyValidation() }
        }
    }

    // MARK: - Sections

    private func resumeBanner(_ saved: SavedSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You were connected to **\(saved.draftName)**. Rejoin it?")
            if let resumeError {
                Text(resumeError).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Button(resuming ? "Reconnecting…" : "Rejoin draft") { resume(saved) }
                    .buttonStyle(.borderedProminent)
                    .disabled(resuming)
                Button("Start fresh") {
                    SessionStore.clear()
                    savedSession = nil
                    resumeError = nil
                }
                .disabled(resuming)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rankingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rankings CSV").bold()
            HStack {
                Button("Choose file…") { showFileImporter = true }
                    .fileImporter(
                        isPresented: $showFileImporter,
                        allowedContentTypes: [.commaSeparatedText, .plainText]
                    ) { result in
                        handleFile(result)
                    }
                if players != nil {
                    Text("✓ Loaded \(players?.count ?? 0) players from \(fileName)")
                        .foregroundStyle(.green)
                }
            }
            Text("FantasyPros consensus export (\"Draft ALL Rankings\")")
                .font(.callout).foregroundStyle(.secondary)
            if players != nil, playersDb != nil {
                if unmatched.isEmpty {
                    Text("✓ All ranked players matched to Sleeper").foregroundStyle(.green).font(.callout)
                } else {
                    let names = unmatched.prefix(5).map(\.name).joined(separator: ", ")
                    Text("\((players?.count ?? 0) - unmatched.count)/\(players?.count ?? 0) matched to Sleeper — unmatched: \(names)\(unmatched.count > 5 ? "…" : "")")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let fileError {
                Text(fileError).foregroundStyle(.red).font(.callout)
            }
        }
    }

    private var advisorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI advisor (optional)").bold()
            SecureField("OpenRouter API key (sk-or-…)", text: $openRouterApiKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: openRouterApiKey) { scheduleKeyValidation() }
            keyValidationStatus
            HStack {
                TextField("Model", text: $openRouterModel, prompt: Text(AIAdvisor.defaultModel))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                Button("Browse…") {
                    modelSearch = ""
                    showModelPicker = true
                }
                .disabled(OpenRouterModelCache.shared.models.isEmpty)
            }
            Text("Enables the on-demand \"Ask AI\" advisor during the draft. Without a key, the consensus Best Available panel still works.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showModelPicker) {
            modelPickerSheet
        }
    }

    @ViewBuilder
    private var keyValidationStatus: some View {
        switch keyValidation {
        case .idle:
            EmptyView()
        case .validating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Validating key…").font(.callout).foregroundStyle(.secondary)
            }
        case .valid(let label):
            Text("✓ Key valid\(label.map { " (\($0))" } ?? "")").font(.callout).foregroundStyle(.green)
        case .invalid(let message):
            Text(message).font(.callout).foregroundStyle(.red)
        }
    }

    private var modelPickerSheet: some View {
        let catalog = OpenRouterModelCache.shared.models
        let filtered = modelSearch.isEmpty
            ? catalog
            : catalog.filter {
                $0.id.localizedCaseInsensitiveContains(modelSearch)
                    || ($0.name?.localizedCaseInsensitiveContains(modelSearch) ?? false)
            }
        return VStack(spacing: 0) {
            HStack {
                Text("Choose a model").font(.headline)
                Spacer()
                Button("Cancel") { showModelPicker = false }
            }
            .padding()
            TextField("Search \(catalog.count) models…", text: $modelSearch)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)
            List(filtered) { model in
                Button {
                    openRouterModel = model.id
                    showModelPicker = false
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.id).bold()
                        if let name = model.name {
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 480, height: 420)
    }

    private var projectionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Projections (optional)").bold()
            HStack {
                Button("Choose files…") { showProjectionsImporter = true }
                    .fileImporter(
                        isPresented: $showProjectionsImporter,
                        allowedContentTypes: [.commaSeparatedText, .plainText],
                        allowsMultipleSelection: true
                    ) { result in
                        handleProjections(result)
                    }
                if let projectionsSummary {
                    Text(projectionsSummary).foregroundStyle(.green)
                }
            }
            Text("FantasyPros projection exports, one per position (QB, RB, WR, TE, K, DST). Positions you skip use modeled projections.")
                .font(.callout).foregroundStyle(.secondary)
            if let projectionsError {
                Text(projectionsError).foregroundStyle(.red).font(.callout)
            }
        }
    }

    private var sleeperSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your Sleeper username").bold()
                HStack {
                    TextField("username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if !username.isEmpty { findDrafts() } }
                        .onChange(of: username) { user = nil }
                    Picker("", selection: $season) {
                        ForEach([SleeperAPI.currentSeason, String((Int(SleeperAPI.currentSeason) ?? 0) - 1)], id: \.self) {
                            Text($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    Button(findLoading ? "Searching…" : "Find drafts") { findDrafts() }
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || findLoading)
                }
                Text("Lists your Sleeper drafts (mocks included) for the season")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let drafts, !drafts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose a draft").bold()
                    ForEach(drafts, id: \.draftId) { d in
                        draftOption(d)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("…or paste a draft link").bold()
                HStack {
                    TextField("https://sleeper.com/draft/nfl/…", text: $draftInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if !draftInput.isEmpty { loadDraftInput() } }
                    Button(draftLoading ? "Loading…" : "Load") { loadDraftInput() }
                        .disabled(draftInput.trimmingCharacters(in: .whitespaces).isEmpty || draftLoading)
                }
            }

            if let sleeperError {
                Text(sleeperError).foregroundStyle(.red)
            }

            if let selectedDraft {
                draftSummary(selectedDraft)
            }
        }
    }

    private func draftOption(_ d: SleeperDraft) -> some View {
        Button {
            select(draftId: d.draftId)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.metadata?.name ?? "Sleeper draft").bold()
                Text("\(d.settings?.teams ?? 0)-team \(d.type ?? "?") · \(statusLabels[d.status ?? ""] ?? d.status ?? "?")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                selectedDraft?.draftId == d.draftId ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .disabled(draftLoading)
    }

    private func draftSummary(_ draft: SleeperDraft) -> some View {
        let config = DraftMath.buildConfig(draft: draft, userId: user?.userId)
        return VStack(alignment: .leading, spacing: 8) {
            Text("✓ \(config.name) — \(config.teams)-team \(config.type), \(config.rounds) rounds (\(statusLabels[draft.status ?? ""] ?? draft.status ?? "?"))")
                .bold().foregroundStyle(.green)
            if unsupportedType {
                Text("Auction drafts aren't supported yet — snake/linear only.").foregroundStyle(.red)
            } else if draftOrderSlot == nil {
                HStack {
                    Text("You're not in this draft's order — which slot is yours?")
                    Picker("", selection: $manualSlot) {
                        ForEach(1...max(config.teams, 1), id: \.self) { Text("Slot \($0)") }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("You're drafting from slot \(draftOrderSlot ?? 0) as \(user?.nameForDisplay ?? "?")")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    // Debounced so validation doesn't fire on every keystroke while pasting/typing.
    private func scheduleKeyValidation() {
        keyValidationTask?.cancel()
        let key = openRouterApiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            keyValidation = .idle
            return
        }
        keyValidation = .validating
        keyValidationTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            do {
                switch try await OpenRouterAPI.validateKey(key) {
                case .valid(let label): keyValidation = .valid(label: label)
                case .invalid(let message): keyValidation = .invalid(message)
                }
            } catch {
                guard !Task.isCancelled else { return }
                keyValidation = .invalid("Could not reach OpenRouter to validate the key.")
            }
        }
    }

    private func handleFile(_ result: Result<URL, Error>) {
        fileError = nil
        players = nil
        switch result {
        case .failure(let error):
            fileError = error.localizedDescription
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                players = try RankingsCSV.parse(url)
                fileName = url.lastPathComponent
            } catch {
                fileError = error.localizedDescription
            }
        }
    }

    private func handleProjections(_ result: Result<[URL], Error>) {
        projectionsError = nil
        switch result {
        case .failure(let error):
            projectionsError = error.localizedDescription
        case .success(let urls):
            let (table, loaded, failed) = ProjectionsCSV.buildTable(from: urls)
            if table.isEmpty {
                projections = nil
                projectionsSummary = nil
                projectionsError = "No projections could be read from the selected file(s)."
                return
            }
            projections = table
            var summary = "✓ \(table.count) player projections from \(loaded) file\(loaded == 1 ? "" : "s")"
            if !failed.isEmpty { summary += " (skipped: \(failed.joined(separator: ", ")))" }
            projectionsSummary = summary
        }
    }

    private func resolveUser() async throws -> SleeperUser {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        if let user, user.username?.lowercased() == trimmed.lowercased() { return user }
        guard let found = try await SleeperAPI.user(trimmed) else {
            throw SleeperAPIError.notFound("No Sleeper user named “\(trimmed)”.")
        }
        user = found
        return found
    }

    private func findDrafts() {
        findLoading = true
        sleeperError = nil
        drafts = nil
        Task {
            defer { findLoading = false }
            do {
                let u = try await resolveUser()
                var found = try await SleeperAPI.userDrafts(userId: u.userId, season: season)
                found.sort { ($0.startTime ?? $0.created ?? 0) > ($1.startTime ?? $1.created ?? 0) }
                drafts = found
                if found.isEmpty {
                    sleeperError = "No \(season) drafts found for \(u.nameForDisplay)."
                }
            } catch {
                sleeperError = error.localizedDescription
            }
        }
    }

    private func select(draftId: String) {
        draftLoading = true
        sleeperError = nil
        Task {
            defer { draftLoading = false }
            do {
                guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw SleeperAPIError.notFound("Enter your Sleeper username first so I know which team is yours.")
                }
                _ = try await resolveUser()
                guard let draft = try await SleeperAPI.draft(draftId) else {
                    throw SleeperAPIError.notFound("Could not find that draft on Sleeper.")
                }
                selectedDraft = draft
            } catch {
                sleeperError = error.localizedDescription
            }
        }
    }

    private func loadDraftInput() {
        guard let id = SleeperAPI.parseDraftInput(draftInput) else {
            sleeperError = "That doesn't look like a Sleeper draft URL or id."
            return
        }
        select(draftId: id)
    }

    private func buildTeamNames(draft: SleeperDraft, teams: Int, user: SleeperUser) async -> [String] {
        var names = (1...max(teams, 1)).map { "Team \($0)" }
        var namesById = [user.userId: user.nameForDisplay]
        if let leagueId = draft.leagueId {
            // League names are a nicety, not a requirement.
            for u in (try? await SleeperAPI.leagueUsers(leagueId)) ?? [] {
                namesById[u.userId] = u.displayName ?? u.username ?? u.userId
            }
        }
        for (uid, slot) in draft.draftOrder ?? [:] {
            if let name = namesById[uid], slot >= 1, slot <= teams { names[slot - 1] = name }
        }
        return names
    }

    private func start() {
        guard let matchedPlayers, let selectedDraft, let user else { return }
        starting = true
        startError = nil
        Task {
            defer { starting = false }
            var config = DraftMath.buildConfig(draft: selectedDraft, userId: user.userId)
            if config.userSlot == nil { config.userSlot = manualSlot }
            let teamNames = await buildTeamNames(draft: selectedDraft, teams: config.teams, user: user)
            onStart(DraftSession(
                players: matchedPlayers,
                draft: selectedDraft,
                config: config,
                userId: user.userId,
                teamNames: teamNames,
                projections: projections
            ))
        }
    }

    private func resume(_ saved: SavedSession) {
        resuming = true
        resumeError = nil
        Task {
            defer { resuming = false }
            do {
                guard let draft = try await SleeperAPI.draft(saved.draftId) else {
                    throw SleeperAPIError.notFound("That draft no longer exists on Sleeper.")
                }
                let config = DraftMath.buildConfig(draft: draft, userId: saved.userId)
                onStart(DraftSession(
                    players: saved.players,
                    draft: draft,
                    config: config,
                    userId: saved.userId,
                    teamNames: saved.teamNames,
                    projections: saved.projections
                ))
            } catch {
                resumeError = error.localizedDescription
            }
        }
    }
}
