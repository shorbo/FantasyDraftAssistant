import SwiftUI

struct DraftView: View {
    let session: DraftSession
    var onLeave: () -> Void

    @State private var showLeaderboard = true // defaults to the leaderboard once complete

    var body: some View {
        VStack(spacing: 0) {
            headerView
            if session.source == .yahoo { yahooReceiverView }
            Divider()
            if session.complete && showLeaderboard {
                LeaderboardView(session: session)
            } else {
                HSplitView {
                    PlayersListView(session: session)
                        .frame(minWidth: 380)
                    VSplitView {
                        RosterView(session: session)
                            .frame(minHeight: 200)
                        AdvisorView(session: session)
                            .frame(minHeight: 220)
                            .padding(.top, 6)
                    }
                    .frame(minWidth: 300, idealWidth: 340)
                    RecommendationsView(session: session)
                        .frame(minWidth: 320, idealWidth: 380)
                }
            }
        }
    }

    private var yahooReceiverView: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.orange)
            Text("Yahoo extension receiver:").font(.caption).bold()
            Text("http://127.0.0.1:8765/api/draft/pick")
                .font(.caption.monospaced()).textSelection(.enabled)
            if let error = session.syncError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else {
                Text("Extension sends picks automatically").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.10))
    }

    private var headerView: some View {
        HStack(spacing: 16) {
            if session.complete {
                Text("🏁 Draft complete").font(.headline)
            } else if session.status == "pre_draft" {
                Text("⏳ Waiting for the draft to start…").font(.headline)
            } else {
                let round = DraftMath.round(forPick: session.clampedPick, teams: session.config.teams)
                let pickInRound = (session.clampedPick - 1) % session.config.teams + 1
                Text("\(session.status == "paused" ? "⏸ " : "")Round \(round) · Pick \(pickInRound) (overall #\(session.currentPick))")
                    .font(.headline)
                if session.onClockSlot == session.config.userSlot {
                    Text("🟢 You're on the clock!").bold().foregroundStyle(.green)
                } else if let slot = session.onClockSlot {
                    let suffix = session.nextUserPickNumber.map { " — you pick in \($0 - session.currentPick)" }
                        ?? " — no picks left for you"
                    Text("\(session.teamName(forSlot: slot)) on the clock\(suffix)")
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if session.complete {
                Picker("", selection: $showLeaderboard) {
                    Text("Leaderboard").tag(true)
                    Text("Draft board").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }

            // The authoritative sync control lives on the Drafted panel, right
            // next to the picks it affects — see SyncControl.
            Button("✕ Leave") { onLeave() }
                .help("Back to setup — you can rejoin anytime")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Shared bits

extension Position {
    var color: Color {
        switch self {
        case .qb: return Color(red: 0.82, green: 0.42, blue: 0.65)
        case .rb: return Color(red: 0.24, green: 0.81, blue: 0.56)
        case .wr: return Color(red: 0.35, green: 0.65, blue: 0.97)
        case .te: return Color(red: 0.96, green: 0.71, blue: 0.32)
        case .k: return Color(red: 0.69, green: 0.55, blue: 0.95)
        case .dst, .unknown: return Color(red: 0.54, green: 0.58, blue: 0.66)
        }
    }
}

struct PositionBadge: View {
    let player: RankedPlayer

    var body: some View {
        Text("\(player.pos.rawValue)\(player.posRank.map(String.init) ?? "")")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(player.pos.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .frame(minWidth: 36)
            .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

// Wraps a panel section in a tinted, bordered card so each part of the draft
// screen reads as a clearly distinct block rather than blending together.
struct SectionCard<Content: View>: View {
    let tint: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(Color.gray.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1.5)
            )
    }
}

// Colored title bar for the top of a SectionCard. `trailing` renders on the
// right (e.g. a refresh control) — omit it for a plain title bar.
func sectionHeader(
    _ title: String, count: Int? = nil, tint: Color,
    @ViewBuilder trailing: () -> some View = { EmptyView() }
) -> some View {
    HStack(spacing: 6) {
        Circle().fill(tint).frame(width: 6, height: 6)
        Text(count.map { "\(title) (\($0))" } ?? title)
            .font(.system(size: 12, weight: .bold))
            .kerning(0.6)
            .foregroundStyle(tint)
        Spacer()
        trailing()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(tint.opacity(0.14))
    .overlay(Rectangle().fill(tint.opacity(0.4)).frame(height: 1.5), alignment: .bottom)
}

// Live-updating "synced Ns ago" text + a manual refresh button, so the user
// can visually confirm the app has caught up with Sleeper's own site.
struct SyncControl: View {
    let session: DraftSession

    var body: some View {
        HStack(spacing: 6) {
            if let error = session.syncError {
                Text("⚠ sync error").font(.caption).foregroundStyle(.orange).help(error)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let age = session.lastSync.map { Int(context.date.timeIntervalSince($0)) }
                    let ageText = age.map { $0 < 2 ? "just now" : "\($0)s ago" } ?? "connecting…"
                    Text(session.complete ? "synced" : ageText)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Button {
                session.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Sync with Sleeper now — compare the top pick here to sleeper.com")
            .disabled(session.complete)
        }
    }
}

// MARK: - Players panel

struct PlayersListView: View {
    let session: DraftSession

    @State private var query = ""
    @State private var tab: Position?

    private func matchesFilters(_ p: RankedPlayer) -> Bool {
        if let tab, p.pos != tab { return false }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty, !p.name.lowercased().contains(q) { return false }
        return true
    }

    // Most recent pick first, so the top of the list tracks the draft.
    private var visibleDrafted: [ResolvedPick] {
        session.picks.filter { matchesFilters($0.player) }.reversed()
    }

    private var visibleAvailable: [RankedPlayer] {
        session.available.filter(matchesFilters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 8) {
                TextField("Search players…", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $tab) {
                    Text("All").tag(Position?.none)
                    ForEach([Position.qb, .rb, .wr, .te, .k, .dst], id: \.self) {
                        Text($0.rawValue).tag(Position?.some($0))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // Drafted on top (tracks the draft), Available below; drag to trade space.
            VSplitView {
                SectionCard(tint: .green) {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("DRAFTED", count: session.picks.count, tint: .green) {
                            SyncControl(session: session)
                        }
                        ScrollViewReader { proxy in
                            List(visibleDrafted) { pick in
                                draftedRow(pick)
                                    .id(pick.pickNumber)
                            }
                            .listStyle(.plain)
                            // Newest pick is at the top; jump there whenever a pick lands.
                            .onChange(of: session.picks.count) {
                                guard let top = visibleDrafted.first else { return }
                                withAnimation { proxy.scrollTo(top.pickNumber, anchor: .top) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 150)
                .padding(.bottom, 6)

                SectionCard(tint: .blue) {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader("AVAILABLE", count: session.available.count, tint: .blue)
                        List(visibleAvailable) { p in
                            availableRow(p)
                        }
                        .listStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 150)
                .padding(.top, 6)
            }
        }
    }

    private func availableRow(_ p: RankedPlayer) -> some View {
        HStack(spacing: 10) {
            Text("\(p.rank ?? 0)")
                .frame(width: 34, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            PositionBadge(player: p)
            Text(p.name).bold().lineLimit(1)
            Spacer()
            Text("\(p.team) · bye \(p.bye.map(String.init) ?? "—")")
                .font(.callout).foregroundStyle(.secondary)
            Text("T\(p.tier.map(String.init) ?? "—")")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private func draftedRow(_ pick: ResolvedPick) -> some View {
        let round = DraftMath.round(forPick: pick.pickNumber, teams: session.config.teams)
        let pickInRound = (pick.pickNumber - 1) % session.config.teams + 1
        return HStack(spacing: 10) {
            Text("#\(pick.pickNumber)")
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("\(round).\(pickInRound)")
                .font(.caption)
                .frame(width: 34, alignment: .leading)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            PositionBadge(player: pick.player)
            Text(pick.player.name).bold().lineLimit(1)
            if pick.isMine {
                Text("YOU").font(.caption).bold().foregroundStyle(.green)
            }
            Spacer()
            Text(session.teamName(forSlot: pick.slot))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 1)
        .listRowBackground(pick.isMine ? Color.green.opacity(0.08) : nil)
    }
}

// MARK: - Roster panel

struct RosterView: View {
    let session: DraftSession

    private static let tint = Color.purple

    var body: some View {
        let roster = session.roster
        let filled = roster.starters.filter { $0.player != nil }.count

        SectionCard(tint: Self.tint) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("MY ROSTER", count: filled, tint: Self.tint)

                let warnings = session.rosterGaps.map { ("⚠️", $0) } + session.byeWarnings.map { ("📅", $0) }
                if !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(warnings, id: \.1) { icon, text in
                            Text("\(icon) \(text)")
                                .font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(roster.starters.enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: 10) {
                                Text(entry.slot.key)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(entry.player == nil ? Color.secondary : Self.tint)
                                    .frame(width: 44, alignment: .leading)
                                if let p = entry.player {
                                    PositionBadge(player: p)
                                    Text(p.name).bold().lineLimit(1)
                                    Spacer()
                                    Text("\(p.team) · bye \(p.bye.map(String.init) ?? "—")")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("empty").italic().foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        Text("BENCH (\(roster.bench.count)/\(session.config.benchSize))")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)

                        ForEach(roster.bench) { p in
                            HStack(spacing: 10) {
                                Text("BN")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Self.tint)
                                    .frame(width: 44, alignment: .leading)
                                PositionBadge(player: p)
                                Text(p.name).bold().lineLimit(1)
                                Spacer()
                                Text("\(p.team) · bye \(p.bye.map(String.init) ?? "—")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
    }
}

// MARK: - AI Advisor panel

struct AdvisorView: View {
    let session: DraftSession

    private static let tint = Color.orange
    @AppStorage("openRouterModel") private var model = AIAdvisor.defaultModel
    @AppStorage("openRouterReasoningEffort") private var reasoningEffort = ""
    @State private var showModelPicker = false
    @State private var modelSearch = ""

    private var isLoading: Bool {
        switch session.adviceState {
        case .syncing, .loading: return true
        default: return false
        }
    }

    private var catalog: [OpenRouterAPI.ModelInfo] { OpenRouterModelCache.shared.models }
    private var currentModelInfo: OpenRouterAPI.ModelInfo? { OpenRouterModelCache.shared.info(for: model) }

    var body: some View {
        SectionCard(tint: Self.tint) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("AI ADVISOR", tint: Self.tint)
                modelRow
                Divider()
                // Advice on top, chat always visible below — drag to trade space.
                VSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            content
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 110)

                    ChatPanel(session: session)
                        .frame(minHeight: 160)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .task {
            await OpenRouterModelCache.shared.ensureLoaded()
        }
        .sheet(isPresented: $showModelPicker) {
            modelPickerSheet
        }
    }

    private var modelRow: some View {
        HStack(spacing: 8) {
            Button {
                modelSearch = ""
                showModelPicker = true
            } label: {
                Text(model.isEmpty ? AIAdvisor.defaultModel : model)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Change the OpenRouter model")

            if let contextLabel = currentModelInfo?.contextLengthLabel {
                Text(contextLabel)
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }

            Spacer()

            if currentModelInfo?.supportsReasoning == true {
                Picker("", selection: $reasoningEffort) {
                    Text("No reasoning").tag("")
                    Text("Low reasoning").tag("low")
                    Text("Medium reasoning").tag("medium")
                    Text("High reasoning").tag("high")
                }
                .pickerStyle(.menu)
                .font(.caption)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var modelPickerSheet: some View {
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
            List(filtered) { info in
                Button {
                    model = info.id
                    showModelPicker = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.id).bold()
                            if let name = info.name {
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            if let ctx = info.contextLengthLabel {
                                Text(ctx).font(.caption2).foregroundStyle(.secondary)
                            }
                            if info.supportsReasoning {
                                Text("reasoning").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 520, height: 420)
    }

    @ViewBuilder
    private var content: some View {
        switch session.adviceState {
        case .idle:
            Text("On-demand AI advice. Code precomputes VORP, ADP value, survival odds, tier cliffs, and dropoffs; the model applies a strict decision procedure and cites the rule that decided the pick.")
                .font(.callout).foregroundStyle(.secondary)
            askButton("Ask AI")

        case .syncing:
            loadingRow("Syncing latest picks from Sleeper…")

        case .loading:
            // Raw JSON deltas aren't shown directly (would look like broken
            // text mid-stream) — a growing byte count instead proves tokens
            // are actually arriving, not that the request has stalled.
            loadingRow(session.adviceStreamedChars > 0
                ? "Thinking through the board… (\(session.adviceStreamedChars) chars received)"
                : "Thinking through the board…")

        case .error(let message):
            Text(message).font(.callout).foregroundStyle(.red)
            askButton("Try again")

        case .ready(let forPick, let advice):
            if forPick != session.currentPick, !session.complete {
                Text("⚠ From pick #\(forPick) — the board has moved since.")
                    .font(.caption).bold().foregroundStyle(.orange)
            }
            adviceCard(advice)
            askButton("Ask again")
        }
    }

    @ViewBuilder
    private func adviceCard(_ advice: AIAdvice) -> some View {
        // PICK
        pickRow(advice)
        // WHY
        Text(advice.why).font(.callout).fixedSize(horizontal: false, vertical: true)
        // ALTERNATES
        if !advice.alternates.isEmpty {
            Text("ALTERNATES").font(.caption2).bold().kerning(0.5).foregroundStyle(.secondary)
            ForEach(advice.alternates, id: \.id) { candidateRow($0) }
        }
        // IF SNIPED
        if let ifSniped = advice.ifSniped, !ifSniped.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("IF SNIPED").font(.caption2).bold().kerning(0.5).foregroundStyle(.secondary)
                Text(ifSniped).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pickRow(_ advice: AIAdvice) -> some View {
        let player = session.players.first { $0.id == advice.pickId }
        let drafted = player.map { session.draftedIds.contains($0.id) } ?? false
        return HStack(spacing: 8) {
            if let player {
                PositionBadge(player: player)
                Text(player.name).bold().strikethrough(drafted)
                if drafted { Text("TAKEN").font(.caption2).bold().foregroundStyle(.red) }
            } else {
                Text("Player \(advice.pickId)").bold()
            }
            Spacer()
            if let rule = advice.rule {
                Text("Rule \(rule)")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Self.tint.opacity(0.2), in: Capsule())
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Self.tint.opacity(0.5)))
    }

    private func loadingRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.callout).foregroundStyle(.secondary)
            if let started = session.adviceStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(Int(context.date.timeIntervalSince(started)))s")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            Button("Stop") { session.cancelAdvisor() }
        }
    }

    private func askButton(_ title: String) -> some View {
        Button(title) { session.askAdvisor() }
            .disabled(isLoading || session.complete || !session.hasAdvisorKey)
            .help(session.hasAdvisorKey
                ? "Get fresh advice for the current pick"
                : "Add your OpenRouter API key on the setup screen to enable the advisor")
    }

    private func candidateRow(_ candidate: AICandidate) -> some View {
        let player = session.players.first { $0.id == candidate.id }
        let drafted = player.map { session.draftedIds.contains($0.id) } ?? false
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if let player {
                    PositionBadge(player: player)
                    Text(player.name).bold().strikethrough(drafted)
                    if drafted {
                        Text("TAKEN").font(.caption2).bold().foregroundStyle(.red)
                    }
                    Spacer()
                    Text("#\(player.rank ?? 0)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Player \(candidate.id)").bold()
                }
            }
            Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Recommendations panel

struct RecommendationsView: View {
    let session: DraftSession

    private static let tint = Color.teal

    var body: some View {
        SectionCard(tint: Self.tint) {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("BEST AVAILABLE", tint: Self.tint)
                Text("Top 3 by consensus rank at each position")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        let groups = session.recommendations
                        if groups.isEmpty {
                            Text("No available players left.").foregroundStyle(.secondary).padding(12)
                        }
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(group.pos.rawValue)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(group.pos.color)
                                ForEach(group.players) { player in
                                    recRow(player)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
    }

    private func recRow(_ player: RankedPlayer) -> some View {
        HStack(spacing: 8) {
            PositionBadge(player: player)
            Text(player.name).bold().lineLimit(1)
            if session.tierCliffIds.contains(player.id) {
                Text("TIER CLIFF").font(.caption2).bold().foregroundStyle(.orange)
            }
            Spacer()
            Text("\(player.team) · bye \(player.bye.map(String.init) ?? "—")")
                .font(.caption).foregroundStyle(.secondary)
            Text("#\(player.rank ?? 0) · T\(player.tier.map(String.init) ?? "—")")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
