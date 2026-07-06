import Foundation

struct AICandidate: Decodable, Sendable {
    let id: Int
    let reason: String
}

// Structured recommendation matching the spec's PICK / WHY / ALTERNATES /
// IF SNIPED output, returned as JSON so player-id linking stays intact.
struct AIAdvice: Decodable, Sendable {
    let pickId: Int
    let rule: Int?
    let why: String
    let alternates: [AICandidate]
    let ifSniped: String?

    enum CodingKeys: String, CodingKey {
        case pickId, rule, why, alternates, ifSniped
    }
}

// A turn in the follow-up chat with the advisor.
struct ChatMessage: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant, error }
    let id = UUID()
    let role: Role
    let text: String
}

enum AIAdvisorError: LocalizedError {
    case api(String)
    case unparseable

    var errorDescription: String? {
        switch self {
        case .api(let message): return message
        case .unparseable: return "The model returned no parseable advice."
        }
    }
}

// On-demand draft advice via OpenRouter (chat completions).
enum AIAdvisor {
    static let defaultModel = "anthropic/claude-sonnet-4.5"
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    // Structured one-shot advice: rich draft context in, a short narrative +
    // 2–3 candidate picks out (strict JSON). onDelta fires with each raw
    // streamed fragment (JSON, not display text — callers typically just
    // count characters rather than render it).
    static func advise(
        apiKey: String, model: String, reasoningEffort: String?, prompt: String,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> AIAdvice {
        let text = try await callCompletion(
            kind: "advise", apiKey: apiKey, model: model,
            reasoningEffort: reasoningEffort, prompt: prompt, maxTokens: 4000, onDelta: onDelta
        )
        guard let advice = parse(text) else { throw AIAdvisorError.unparseable }
        return advice
    }

    // Free-form follow-up question, given the same draft context plus the
    // conversation so far. Returns plain text. onDelta fires with each
    // streamed fragment — safe to render directly since this response is
    // plain conversational text, not JSON.
    static func chat(
        apiKey: String, model: String, reasoningEffort: String?, prompt: String,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let text = try await callCompletion(
            kind: "chat", apiKey: apiKey, model: model,
            reasoningEffort: reasoningEffort, prompt: prompt, maxTokens: 2000, onDelta: onDelta
        )
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIAdvisorError.unparseable
        }
        return text
    }

    // Shared OpenRouter call: times the request, logs prompt/response/error
    // to AILogger regardless of outcome, and returns the raw completion text.
    private static func callCompletion(
        kind: String, apiKey: String, model: String, reasoningEffort: String?,
        prompt: String, maxTokens: Int, onDelta: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let usedModel = model.isEmpty ? defaultModel : model
        let start = Date()

        func logAndReturn(_ text: String) -> String {
            AILogger.log(
                kind: kind, model: usedModel, prompt: prompt, response: text, error: nil,
                durationSeconds: Date().timeIntervalSince(start)
            )
            return text
        }
        func logAndThrow(_ error: Error) -> Error {
            AILogger.log(
                kind: kind, model: usedModel, prompt: prompt, response: nil,
                error: String(describing: error), durationSeconds: Date().timeIntervalSince(start)
            )
            return error
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // This is an IDLE timeout (no bytes received), not a total-duration cap.
        // Streaming (below) means it resets on every token, so 120s is ample
        // even when the full generation runs far longer.
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.setValue("Fantasy Football Assistant", forHTTPHeaderField: "x-title")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")

        var body: [String: Any] = [
            "model": usedModel,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
            // Non-streaming responses withhold every byte until the model is
            // completely done generating — on a slow or reasoning-heavy model
            // that alone can exceed any request timeout even though the model
            // is working fine. Streaming trickles tokens in continuously,
            // which resets the idle timeout above on every chunk.
            "stream": true,
        ]
        // Only sent when the caller confirmed (via the model catalog) that
        // this model supports OpenRouter's unified reasoning parameter.
        if let reasoningEffort, !reasoningEffort.isEmpty {
            body["reasoning"] = ["effort": reasoningEffort]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                var errText = ""
                for try await line in bytes.lines {
                    errText += line
                    if errText.count > 500 { break }
                }
                throw AIAdvisorError.api("OpenRouter error \(status): \(errText.prefix(300))")
            }

            var full = ""
            for try await line in bytes.lines {
                if let delta = try parseSSELine(line) {
                    full += delta
                    onDelta?(delta)
                }
            }
            return logAndReturn(full)
        } catch {
            throw logAndThrow(error)
        }
    }

    // Parses one line of an OpenRouter SSE stream. Returns the incremental
    // text for a content chunk, or nil for lines to ignore (blank, comments,
    // "[DONE]", chunks with no content delta). Throws if the chunk carries an
    // error payload.
    static func parseSSELine(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }

        struct StreamChunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta
            }
            struct APIError: Decodable { let message: String? }
            let choices: [Choice]?
            let error: APIError?
        }
        guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else { return nil }
        if let error = chunk.error {
            throw AIAdvisorError.api("OpenRouter error: \(error.message ?? "unknown")")
        }
        return chunk.choices?.first?.delta.content
    }

    // Extracts the JSON payload from the response text (the model may wrap it
    // in prose or a code fence despite instructions).
    static func parse(_ text: String) -> AIAdvice? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end
        else { return nil }
        let json = String(text[start...end])
        guard let advice = try? JSONDecoder().decode(AIAdvice.self, from: Data(json.utf8)),
              !advice.why.isEmpty
        else { return nil }
        return advice
    }

    // MARK: - Prompt

    private static let scoringLabels: [String: String] = [
        "ppr": "full-PPR", "half_ppr": "half-PPR", "std": "standard scoring",
        "2qb": "2-QB", "dynasty": "dynasty", "dynasty_ppr": "dynasty full-PPR",
        "dynasty_half_ppr": "dynasty half-PPR", "dynasty_std": "dynasty standard scoring",
    ]

    static func buildPrompt(
        config: DraftConfig,
        currentPick: Int,
        nextUserPick: Int?,
        myPlayers: [RankedPlayer],
        available: [RankedPlayer],
        picks: [ResolvedPick],
        teamNames: [String],
        allPlayers: [RankedPlayer],
        projections: ProjectionTable?,
        projectionsAreReal: Bool
    ) -> String {
        let analysis = DraftAnalytics.compute(
            config: config, currentPick: currentPick, nextUserPick: nextUserPick,
            myPlayers: myPlayers, available: available, picks: picks,
            allPlayers: allPlayers, projections: projections
        )
        let context = buildContextBlock(
            config: config, currentPick: currentPick, nextUserPick: nextUserPick,
            myPlayers: myPlayers, available: available, picks: picks,
            teamNames: teamNames, projections: projections,
            projectionsAreReal: projectionsAreReal, analysis: analysis
        )

        let pairPlan = analysis.atTheTurn
            ? "\n\nYOU ARE AT THE TURN. Plan BOTH of your upcoming picks together as a pair — recommend the pick that maximizes combined VORP across the pair given survival, taking the scarcer player (lower survival, steeper dropoff) first. Use IF SNIPED to name the second-pick pivot."
            : ""

        return context + """


        \(decisionProcedure)

        \(roundPhaseStrategy)\(pairPlan)

        Respond with ONLY a JSON object, no prose, no code fences:
        {"pickId": <player id from the board>, "rule": <the rule number 1-4 that decided it>, "why": "<one sentence citing VORP, survival, and tier context>", "alternates": [{"id": <id>, "reason": "<one line>"}, {"id": <id>, "reason": "<one line>"}], "ifSniped": "<who to take if the pick is gone before your turn>"}
        Give exactly 2 alternates.
        """
    }

    private static let decisionProcedure = """
    DECISION PROCEDURE — evaluate in strict order, stop at the first rule that decides the pick, and report its number:
    1. CAPACITY HARD RULE: if my remaining picks ≤ my empty required starting slots, recommend filling a required slot NOW. Never advise waiting on a required slot I cannot guarantee filling later. Required slots are every starting-lineup slot (QB, both RB, both WR, TE, both FLEX, K, DST).
    2. TIER CLIFF AT A POSITION OF NEED: if a position where I have an open starting slot shows "any survive" below 40%, and the best available player in that tier has positive VORP, recommend him.
    3. BEST VORP UNLIKELY TO SURVIVE: among the top-5 VORP players available, prefer the one with the lowest survival %, unless another top-5 VORP player fills an open starting slot and has survival below 60% — then prefer that one.
    4. TIEBREAKERS (only when rules 2–3 leave options with VORP within ~5 pts): (a) fills an open starting slot; (b) higher upside per the round-phase strategy; (c) avoids a duplicate bye week with my starting QB or TE ONLY (ignore RB/WR/flex bye conflicts).
    """

    private static let roundPhaseStrategy = """
    ROUND-PHASE STRATEGY (2-FLEX PPR — I start 5–6 combined RB/WR each week, so RB/WR volume wins this format):
    - Rounds 1–6: draft RB/WR almost exclusively, by best tier + VORP. Only exceptions: an elite tier-1 TE at fair value, or a top-3 QB falling a full round past ADP. Otherwise do NOT draft QB or TE here.
    - Rounds 7–10: keep taking RB/WR to fill both FLEX spots with startable players; take TE here if still unrostered; QB no earlier than round 8 and by round 10.
    - Rounds 11–13: prioritize ceiling over floor — high-variance upside (rookies, ambiguous backfields, breakout WRs) over safe capped veterans. Projections compress toward the mean here; do not chase tiny projection edges. Keep skewing RB/WR for flex insurance.
    - K and DST: the final two rounds ONLY, unless the capacity hard rule forces it earlier.
    """

    // Same situational context as buildPrompt, but for a free-form follow-up
    // question with the running conversation attached instead of a forced
    // JSON candidate list.
    static func buildChatPrompt(
        config: DraftConfig,
        currentPick: Int,
        nextUserPick: Int?,
        myPlayers: [RankedPlayer],
        available: [RankedPlayer],
        picks: [ResolvedPick],
        teamNames: [String],
        allPlayers: [RankedPlayer],
        projections: ProjectionTable?,
        projectionsAreReal: Bool,
        history: [ChatMessage],
        question: String
    ) -> String {
        let analysis = DraftAnalytics.compute(
            config: config, currentPick: currentPick, nextUserPick: nextUserPick,
            myPlayers: myPlayers, available: available, picks: picks,
            allPlayers: allPlayers, projections: projections
        )
        let context = buildContextBlock(
            config: config, currentPick: currentPick, nextUserPick: nextUserPick,
            myPlayers: myPlayers, available: available, picks: picks,
            teamNames: teamNames, projections: projections,
            projectionsAreReal: projectionsAreReal, analysis: analysis
        )
        let historyText: String
        if history.isEmpty {
            historyText = ""
        } else {
            let lines = history.map { "\($0.role == .user ? "Me" : "You"): \($0.text)" }
            historyText = "\nCONVERSATION SO FAR:\n" + lines.joined(separator: "\n") + "\n"
        }
        return context + """

        \(historyText)
        MY QUESTION: \(question)

        Answer directly and conversationally in plain text — no JSON, no code fences. Keep it to a few sentences unless the question genuinely calls for more. Ground your answer in the roster, board, draft capacity, and opponent-needs context above; the situation above reflects the board right now, not when we started talking.
        """
    }

    // The shared situational context: league shape, roster, draft capacity,
    // opponent needs, and a fully precomputed board (VORP, ADP deltas,
    // survival %, tier survival, dropoffs). All math is done in code so the
    // LLM only exercises judgment over annotated numbers.
    private static func buildContextBlock(
        config: DraftConfig,
        currentPick: Int,
        nextUserPick: Int?,
        myPlayers: [RankedPlayer],
        available: [RankedPlayer],
        picks: [ResolvedPick],
        teamNames: [String],
        projections: ProjectionTable?,
        projectionsAreReal: Bool,
        analysis: DraftAnalysis
    ) -> String {
        let round = DraftMath.round(forPick: currentPick, teams: config.teams)
        let scoring = config.scoring.flatMap { scoringLabels[$0] ?? $0 } ?? "unknown scoring"
        let lineup = config.slots.map(\.key).joined(separator: ", ")

        func teamName(_ slot: Int) -> String {
            (slot >= 1 && slot <= teamNames.count) ? teamNames[slot - 1] : "Team \(slot)"
        }

        func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a" }
        func signed(_ v: Double) -> String { (v >= 0 ? "+" : "") + String(Int(v.rounded())) }
        func signedI(_ v: Int) -> String { (v >= 0 ? "+" : "") + String(v) }

        // A board row carries every precomputed number for one player.
        func playerLine(_ p: RankedPlayer) -> String {
            let a = analysis.annotation(for: p)
            var parts = [
                "\(p.name) (\(p.team), \(p.pos.rawValue)\(p.posRank.map(String.init) ?? ""))",
                "rank \(p.rank.map(String.init) ?? "?")",
                "tier \(p.tier.map(String.init) ?? "?")",
                "ADP \(p.adp.map { String(Int($0.rounded())) } ?? "?")",
                "bye \(p.bye.map(String.init) ?? "?")",
            ]
            if let a {
                parts.append("proj \(Int(a.projPts.rounded()))")
                parts.append("VORP \(signed(a.vorp))")
                if let rd = a.rankDelta { parts.append("rankΔ \(signedI(rd))") }
                if let ad = a.adpDelta { parts.append("adpΔ \(signed(ad))") }
                if a.survivalPct != nil { parts.append("survives \(pct(a.survivalPct))") }
            }
            var line = parts.joined(separator: ", ")
            if a?.isTierCliff == true { line += " [LAST IN TIER]" }
            return line
        }

        // My roster by slot.
        let (starters, bench) = DraftMath.assignRoster(myPlayers, slots: config.slots)
        let rosterLines = (
            starters.map { entry in
                let value = entry.player.map { playerLine($0) } ?? "EMPTY"
                return "\(entry.slot.key): \(value)"
            } + bench.map { "BENCH: \(playerLine($0))" }
        ).joined(separator: "\n")

        // Draft capacity: all empty starting slots count as required.
        let emptyText = analysis.emptyRequiredByLabel.isEmpty
            ? "none"
            : analysis.emptyRequiredByLabel.map { "\($0.count) \($0.label)" }.joined(separator: ", ")
        let capacityWarning = analysis.remainingPicks <= analysis.emptyStartingSlots && analysis.emptyStartingSlots > 0
            ? " You have only \(analysis.remainingPicks) pick(s) left and \(analysis.emptyStartingSlots) required starting slot(s) still empty — you cannot punt any; a slot still empty at draft's end stays empty (Rule 1 territory)."
            : ""

        // Opponents picking before my next turn and their open needs.
        var opponentLines: [String] = []
        if let nextUp = nextUserPick, nextUp > currentPick {
            for p in currentPick..<nextUp {
                let slot = DraftMath.slot(forPick: p, config: config)
                guard slot != config.userSlot else { continue }
                let theirPlayers = picks.filter { $0.slot == slot }.map(\.player)
                let (theirStarters, _) = DraftMath.assignRoster(theirPlayers, slots: config.slots)
                let needs = theirStarters.filter { $0.player == nil }.map(\.slot.label)
                let needText = needs.isEmpty ? "starters full" : "needs \(needs.joined(separator: ", "))"
                opponentLines.append("Pick #\(p) — \(teamName(slot)): \(needText)")
            }
        }
        let opponentSection = opponentLines.isEmpty
            ? "(you are on the clock now or have no later pick)"
            : opponentLines.joined(separator: "\n")

        // Per-position summaries: replacement baseline, top-tier survival, dropoff.
        var positionLines: [String] = []
        for pos in [Position.qb, .rb, .wr, .te, .k, .dst] {
            guard let s = analysis.positionSummaries[pos] else { continue }
            var line = "\(pos.rawValue): replacement \(Int(s.replacementPts.rounded())) pts"
            if let t = s.topTier { line += "; top tier \(t)" }
            if s.tierSurvivalPct != nil { line += "; any survive to next pick \(pct(s.tierSurvivalPct))" }
            line += "; VORP dropoff if you wait \(signed(-s.dropoffNextRound)) pts"
            if s.hasOpenStartingSlot { line += "; YOU HAVE AN OPEN SLOT HERE" }
            positionLines.append(line)
        }

        // Board: top overall + best few per position, all annotated.
        var board = Array(available.prefix(30))
        for pos in [Position.qb, .rb, .wr, .te, .k, .dst] {
            let top = available.filter { $0.pos == pos }.prefix(3)
            for p in top where !board.contains(where: { $0.id == p.id }) { board.append(p) }
        }
        let boardLines = board.map { "id=\($0.id) \(playerLine($0))" }.joined(separator: "\n")

        let g = analysis.picksUntilNextTurn
        let situation = g.map {
            $0 == 0
                ? "I am ON THE CLOCK at pick #\(currentPick)."
                : "It is pick #\(currentPick); I pick next at #\(nextUserPick!) (\($0) picks away)."
        } ?? "It is pick #\(currentPick); this is my LAST pick — no picks remain after it."

        let provenance = projectionsAreReal
            ? "Projections are user-loaded FantasyPros data; VORP and dropoff numbers are reliable."
            : "Projections are SYNTHETIC estimates, not loaded data. Treat VORP and dropoff as approximate — lean more on tiers, ADP, and consensus rank, and hedge any point-based claims."

        return """
        You are an expert fantasy football draft advisor for a \(config.teams)-team \(scoring) \(config.type) draft (\(config.rounds) rounds). Starting lineup: \(lineup), \(config.benchSize) bench. I draft from slot \(config.userSlot ?? 0). It is round \(round). \(situation)

        This is the \(config.season) NFL season. Your training data may be stale on which team a player is currently on (trades, free agency, and depth-chart moves happen every offseason) — the `team` shown for each player below is pulled fresh from this season's data and is authoritative. Whenever a decision depends on team context — handcuffs, QB/pass-catcher stacks, bye-week conflicts, depth-chart role — verify it against the team listed below rather than what you recall; do not assume a player is still on the team you last knew them on.

        All math below is precomputed for you. VORP = projected points above the positional replacement level (this 2-FLEX format pushes RB/WR replacement deeper, so their VORP runs high — that is correct). ADP is the market draft slot; adpΔ = pick − ADP (positive = falling past market). survives = chance the player is still available at my next pick. Do NOT recompute these; apply judgment to them. \(provenance)

        MY ROSTER SO FAR:
        \(rosterLines)

        DRAFT CAPACITY: \(analysis.remainingPicks) pick(s) left (incl. this one if on the clock). Empty required starting slots: \(emptyText).\(capacityWarning)

        TEAMS PICKING BEFORE MY NEXT TURN (their open starting slots — already folded into the survives % via positional runs):
        \(opponentSection)

        POSITION SUMMARY (replacement baseline, top-tier survival, VORP lost by waiting a round):
        \(positionLines.joined(separator: "\n"))

        BOARD — top available, fully annotated:
        \(boardLines)
        """
    }
}
