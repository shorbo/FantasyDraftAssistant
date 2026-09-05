# Fantasy Football Assistant — Draft Assistant Requirements

## Overview

A **native macOS app (SwiftUI, Swift 6)** that assists during a fantasy football draft. It **live-syncs with a Sleeper draft** (mock or real) — Sleeper is the source of truth for picks, and the app watches, tracks your roster, and recommends who to take next. Two recommendation layers: an instant, deterministic **Best Available** panel from FantasyPros consensus rankings, and an on-demand **AI Advisor** that runs a code-computed analytics engine (VORP, ADP value, survival odds, tier cliffs, dropoffs) through an LLM applying a strict decision procedure. It never makes picks for you; you pick in Sleeper and the app advises. When the draft ends it scores every team and shows a **leaderboard** so you can learn from your steals and reaches.

The draft assistant is the first tool in a planned **Fantasy Football Assistant** suite; in-season tools (waivers, start/sit, trades) are planned for later.

> The app is Swift-only; build with Xcode / `xcodebuild`.

---

## League & Draft Settings

All league and draft settings are **read from Sleeper** at connect time — nothing is hardcoded or manually configured:

- Teams, rounds, and total picks
- Draft type: **snake**, **linear**, or **snake with Nth-round reversal** (auction is detected and rejected as unsupported)
- Starting lineup slots, including flex variants (`FLEX` RB/WR/TE, `W/R`, `W/T`, superflex) and bench size
- Scoring format (PPR / half / standard / 2-QB / dynasty variants)
- Which draft slot is the user's (from the draft order; if the user isn't in the order — e.g. watching someone else's board — they pick their slot manually)

---

## Setup Screen

1. **Rankings CSV** — user selects a FantasyPros consensus export ("Draft ALL Rankings"). Parsed and matched against the Sleeper player database (see below).
2. **Projections (optional)** — one or more FantasyPros per-position projection CSVs (QB/RB/WR/TE/K/DST). Used for VORP and the projected-points leaderboard; positions not loaded fall back to modeled projections.
3. **Connect to Sleeper** — user enters their Sleeper **username** and season; the app lists their drafts for that season (mock drafts included), most recent first. Alternatively, paste a **draft URL or id** directly.
4. **Pick a draft** — selecting one shows a summary (teams, type, rounds, status) and confirms which slot is the user's.
5. **AI Advisor (optional)** — an **OpenRouter API key** (validated live against `/key`), plus a **model** chosen from the OpenRouter catalog (searchable picker showing context-window size and reasoning support). Key + model persist in `UserDefaults`.
6. **Connect** — enters the live draft screen and begins syncing.

A **resume banner** appears if a prior session exists — one click reconnects to that draft (picks are always re-fetched fresh from Sleeper, never restored from local state).

---

## Sleeper Integration

- **Public read-only Sleeper API** (`https://api.sleeper.app/v1`) — no auth, no API key, no OAuth.
- Endpoints used: user by username, user's drafts for a season, draft by id, draft picks, league users (for team names), and the `players/nfl` dump.
- **Player database**: the `players/nfl` dump (~5MB) is fetched at most once per day and cached to Application Support, trimmed to fantasy-relevant positions and only the fields matching needs.
- **No caching on live calls**: draft/pick requests use an ephemeral `URLSession` with caching disabled and `Cache-Control: no-cache`, because both `URLSession`'s cache and Sleeper's CDN will otherwise serve stale picks during a live draft.
- **Rate limits**: stay well under Sleeper's ~1000 calls/min guideline (polling every 3s ≈ 20 calls/min).

### Rankings ↔ Sleeper Matching

The FantasyPros rankings and Sleeper use different player identifiers, so a matching layer connects them:

- Match on **normalized name + position** (lowercased, punctuation stripped, name suffixes like "Jr."/"III" dropped)
- **Team-code aliases** reconcile differing abbreviations (JAC↔JAX, WSH↔WAS, LA↔LAR, etc.)
- **Nickname aliases** handle ranking-site nicknames vs. Sleeper legal names (e.g. "Hollywood Brown" → "Marquise Brown")
- **Defenses (DST)** match on team code, since Sleeper defense ids are team codes
- **Fullbacks (FB)** are treated as RB
- Duplicate name+position resolves by team, then active status
- Achieves ~494/496 match rate on the current FantasyPros export; the setup screen reports the match count and lists any unmatched players

---

## Core Features

### 1. Player Lists (Available + Drafted)

- Player data from the **FantasyPros CSV**; each player shows name, team, position + positional rank, overall rank, tier, and bye week.
- The left column stacks two lists in a vertical split (drag the divider): **Drafted** on top and **Available** (undrafted, by overall rank) below, each with a live count header.
- Drafted rows show overall pick number, round.pick, drafting team, and a **YOU** tag on the user's own picks. Most recent pick first, and the list **auto-scrolls to the top whenever a pick lands** so the newest is always visible.
- A shared **search box** and **position filter** (All | QB | RB | WR | TE | K | DST) filter both lists.
- Lists are **read-only** — picks sync in from Sleeper, so there is no click-to-draft, manual attribution, or undo.

#### CSV Parsing Requirements

The FantasyPros export has quirks the parser must handle:

- Fields are quoted and names contain apostrophes (`"Ja'Marr Chase"`) — a proper RFC-4180 parser is used, not `split(",")`; CRLF line endings are handled (Swift treats `\r\n` as one Character)
- Headers may have trailing spaces / varied casing — normalized on read; **column aliases** absorb FantasyPros renames (e.g. `BYE` or `BYE WEEK`)
- `POS` embeds positional rank (`WR1`, `RB12`, `DST5`) — split into position + posRank
- Columns used: `RK`, `TIERS`, `PLAYER NAME`, `TEAM`, `POS`, `BYE`; the optional `ECR VS. ADP` delta is read to derive **ADP = rank + delta** (FantasyPros' overall rank is its ECR)
- Malformed rows are skipped; the file is validated (required columns present, ≥100 valid rows) with a clear error on failure

### 2. Live Draft Sync & Header

- **Polls the Sleeper draft every 3 seconds**, plus periodic draft-object refreshes to track status (`pre_draft` → `drafting` → `paused` → `complete`); polling stops when complete. Concurrent syncs (poll + manual) coalesce onto a single in-flight fetch, so an awaited sync always reflects a real completed fetch.
- The **DRAFTED panel header** carries a live "synced Ns ago" age and a **manual refresh button**, placed next to the picks it affects so the user can compare the top pick to sleeper.com and force an immediate sync. Sync errors surface (retrying) without breaking the draft.
- Header shows current round/pick/overall, who is on the clock, and **how many picks until the user's next turn** (derived from the draft type's pick-order math).
- **Draft-complete state** switches the header to a completion indicator.
- Pick ownership is decided by **draft slot** (not `picked_by`), so autopicked players still land on the correct roster.

### 3. My Roster Panel

- Shows the user's drafted players grouped by starting slot, with filled vs. empty slots and the bench.
- **Slot fill order**: dedicated single-position slots first, then flex slots, then bench (supports all Sleeper flex types).
- Highlights **roster gaps** (e.g. "No TE drafted yet"), suppressing K/DST warnings until the final few rounds.
- **Bye-week warnings** when 3+ starters share a bye.

### 4. Recommendations Panel ("Best Available")

- **Consensus rankings** — shows the **top 3 available players at each position** the league starts (QB/RB/WR/TE, plus K/DST when rostered), ordered by FantasyPros overall rank, grouped under position headers.
- Each row shows name, team, bye, overall rank, tier, and a **TIER CLIFF** flag when the player is the last available in their positional tier.
- Recompute instantly on every sync as players come off the board.

### 4b. AI Advisor (on demand)

The advisor's guiding principle: **code computes all the math; the LLM only exercises judgment over precomputed, annotated data.** This avoids asking the model to derive dropoffs/survivability from raw lists, which it does unreliably.

**Analytics engine** ([`DraftAnalytics.swift`](FantasyFootballAssistant/Services/DraftAnalytics.swift)) — computed fresh each request, entirely in code:

- **VORP (Value Over Replacement Player)** — the headline value metric: `player_projected_points − replacement_level_at_position`. Replacement levels are computed from the league shape: dedicated starters (`teams × slots`) plus a share of the flex pool (default flex allocation 40% RB / 55% WR / 5% TE), which pushes RB/WR replacement deeper in a 2-FLEX format (correctly making QB a stronger wait). For a 10-team/2-FLEX league this yields QB #12, RB #28, WR #31, TE #11, K/DST #11 — matching the spec.
- **ADP value** — `adpΔ = current_pick − ADP` (positive = falling past market), shown alongside `rankΔ` vs. consensus rank.
- **Survival probability** — for each board player, chance they last to the user's next pick, from a piecewise-linear curve on `(ADP − pick) − picks_until_next_turn`, minus a positional-run penalty (default 7% per open slot among intervening opponents; an open FLEX counts 0.5 for RB/WR/TE).
- **Tier survival** — per position, `1 − Π(1 − survival_i)` over the top available tier ("any survive to next pick N%").
- **Dropoff** — per position, best VORP now minus the survival-weighted expected best VORP at the next pick.
- **Capacity math** — remaining picks vs. empty starting slots (all 10 count as required, including both FLEX).

**LLM layer** — a separate **"Ask AI"** panel, strictly on-demand (a button, never auto-triggered), that forces a fresh Sleeper sync, then sends the fully-annotated board to **OpenRouter** (user-selected model; reasoning effort forwarded only for models that support it). The system instruction is a **strict ordered decision procedure** (evaluate in order, stop at the first rule that decides, cite the rule number):

1. **Capacity hard rule** — if remaining picks ≤ empty required slots, fill a required slot now.
2. **Tier cliff at a position of need** — open slot + top-tier "any survive" < 40% + positive VORP.
3. **Best VORP unlikely to survive** — among top-5 VORP, prefer the lowest survival (with an open-slot override under 60%).
4. **Tiebreakers** (VORP within ~5 pts) — fills a slot / round-phase upside / duplicate bye at QB or TE only.

Plus a **round-phase strategy** (RB/WR hammer rounds 1–6, fill flex + TE/QB windows 7–10, ceiling over floor 11–13, K/DST last two rounds) and **snake-turn pair planning** when the user is at the turn (≤2 opponent picks between their two picks).

- **Output** is rendered as **PICK / WHY / ALTERNATES / IF SNIPED** with a "Rule N" badge (driven by structured JSON so player-id linking, TAKEN detection, and position badges keep working). Stale advice is flagged when the pick has moved on since it was generated.
- **Projection provenance** — the prompt states whether projections are user-loaded or modeled, and instructs the model to hedge point-based claims when modeled.
- **Bye stacking is demoted** — no longer a primary factor; only tiebreaker (c), and only for duplicate byes at QB or TE.
- Requires an OpenRouter API key entered at setup; without it the panel is disabled and consensus recommendations are unaffected.

### 4c. AI Chat (on demand)

- A **chat panel** occupying the lower half of the Advisor panel (always visible), for free-form follow-up questions.
- Each message forces a fresh Sleeper sync and sends the **same fully-annotated context** as the advisor plus the running conversation, so answers stay grounded as the board moves.
- Model picker (with context-window and reasoning badges), reasoning-effort menu, a **Stop** button with elapsed timer on both advisor and chat requests.

### 4d. Request logging

- Every advisor and chat request/response (with the full prompt, model, duration, and any error) is appended to `ai-requests.log` in Application Support for troubleshooting; a **Log** button in the chat header reveals it in Finder.

### 5. Draft Leaderboard (end of draft)

- When the draft completes, the draft screen switches to a **leaderboard** (with a header toggle to flip back to the draft board).
- Two scoring metrics, chosen with a toggle; each ranks and grades the field independently:
  - **Draft value** — each pick's value = its overall pick number minus the player's consensus rank. Positive = a **steal** (drafted later than ranked), negative = a **reach**. A team's score is the sum across its picks; unranked players use a replacement rank so reaching for them counts against you. Measures draft-day efficiency.
  - **Projected points** — the projected points of each team's best legal starting lineup (dedicated slots filled first, then flex, by projection). Measures roster strength. Projections come from user-loaded FantasyPros projection CSVs when provided; any position not loaded falls back to a per-position curve **modeled from consensus positional rank** (`Projection.swift`).
- Teams are ranked by the selected metric (medals for the top 3, the user's team highlighted), each with a **letter grade on a curve** relative to the field (so an average draft is a C and systematic effects like everyone taking a late K/DST cancel out). Both scores are shown per team.
- A **"Your draft"** breakdown lists the user's best-value picks and biggest reaches — the core learning tool.

---

## UX Requirements

- **Single window**, three-panel layout during the draft: **Drafted + Available | My Roster | AI Advisor + Chat / Best Available**, in a resizable `HSplitView`; the first and third columns are themselves vertical splits (Drafted-over-Available; Advisor-over-Chat, with Best Available beneath). Replaced by the full-width **leaderboard** once the draft completes.
- Native macOS look and feel; primary use is at a desktop/laptop during a live draft.
- Fast and responsive — sync and recommendations must never block the UI.

---

## Technical Constraints

- **Native SwiftUI macOS app**, Swift 6, `@Observable` state. Project generated via **xcodegen** (`project.yml` → `FantasyFootballAssistant.xcodeproj`); build/test with `xcodebuild`.
- **Data sources**: FantasyPros CSVs (rankings + optional projections) + Sleeper public API (drafts, picks, players) + OpenRouter (optional AI advisor/chat, incl. its public model catalog for the picker). No backend, no database, no authentication.
- **Persistence** (Application Support): the trimmed Sleeper player DB (daily cache) and the last session (matched rankings, draft id, user id, team names, projections). **Picks are never persisted** — Sleeper is the source of truth and picks are always re-fetched on resume. OpenRouter key/model/reasoning-effort persist in `UserDefaults`. AI requests log to `ai-requests.log`.
- **Analytics config** — replacement-level ranks, flex allocation, flex-demand weight, survival breakpoints, run penalty, tier-cliff threshold, and VORP tiebreak band are tunable constants (`AnalyticsConfig`) with spec defaults.
- Unit tests cover pick-order math (snake / linear / 3rd-round reversal), roster assignment, name matching & pick resolution, CSV parsing (incl. ADP derivation & header aliases), the recommender, the draft grader, the analytics engine (replacement ranks, VORP, survival curve, capacity), and advisor prompt/output shapes.

---

## Out of Scope (for now)

- ESPN or Yahoo league APIs (Sleeper only)
- Auction drafts (detected and rejected; snake/linear only)
- In-season tools — waivers, start/sit, trades (planned as future suite tools)
- Making picks on the user's behalf (the app advises; the user drafts in Sleeper)
- Auto-triggered AI recommendations (the AI Advisor is strictly on-demand)
- iOS / iPadOS builds
