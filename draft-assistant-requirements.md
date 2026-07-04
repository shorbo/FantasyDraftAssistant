# Fantasy Football Draft Assistant — Requirements

## Overview

A web-based draft day assistant built as a React app. Used in real time during a fantasy football draft to track picks, manage your roster, and receive AI-powered recommendations on who to select next.

---

## League Settings

| Setting | Value |
|---|---|
| Teams | 10 |
| Rounds | 15 |
| Scoring | PPR |
| Roster size | 15 players |

### Starting Lineup

| Slot | Position |
|---|---|
| QB | 1 |
| RB | 2 |
| WR | 2 |
| TE | 1 |
| FLEX (RB/WR/TE) | 1 |
| K | 1 |
| DST | 1 |
| Bench | 6 |

> Note: bench was originally listed as 7, but 9 starters + 7 bench = 16, which contradicts the 15-player roster and 15 rounds. Corrected to 6.

---

## Setup Screen

- User enters their **draft pick position** (1–10) before the draft begins
- App calculates which picks belong to the user across all 15 rounds using **snake draft format** (odd rounds draft 1→10, even rounds draft 10→1)
- User can confirm settings before entering draft mode

---

## Core Features

### 1. Player List (Available Players)

- Player data loaded via **CSV upload at app startup** (source: FantasyPros PPR consensus export)
- User uploads the CSV before the draft begins; app parses and loads the rankings
- Each player shows: name, team, position, overall rank, **tier**, and **bye week**
- Players are filtered by position using tab buttons: **All | QB | RB | WR | TE | K | DST**
- Search bar to find a player by name quickly
- Drafted players are visually struck through and grayed out (not removed, for reference)
- Optionally hide drafted players with a toggle

#### CSV Parsing Requirements

The FantasyPros export has quirks the parser must handle:

- **Use a real CSV parser** (e.g., PapaParse) — fields are quoted and player names contain apostrophes (`"Ja'Marr Chase"`), so a naive `split(',')` will break
- **Normalize headers** — some have trailing spaces (`"UPSIDE "`, `"BUST "`)
- **`POS` embeds positional rank** — values are `WR1`, `RB12`, `DST5`; strip trailing digits to get the position for filtering
- **Use these columns**: `RK` (overall rank), `TIERS`, `PLAYER NAME`, `TEAM`, `POS`, `BYE`
- **Ignore these columns**: `UPSIDE`, `BUST` (placeholder text in the export), `SOS`, `ECR VS ADP`
- **Validate on upload** — check that the expected columns are present; show a clear error message if the file is malformed or the wrong export

### 2. Draft Pick Tracker

- Displays the current round and pick number
- User clicks a player to mark them as drafted
- **Auto-attribution**: the app already knows whose turn it is from the snake-draft math — if the current pick is the user's, the player goes to **My Roster**; otherwise they're marked as taken by another team. No confirmation prompt per pick (150 picks — every extra click hurts)
- A small correction affordance (e.g., click a recent pick to reassign it) covers the rare case where attribution is wrong, such as out-of-order pick entry
- **Undo stack** — undo reverses pick actions one at a time, multiple levels deep (mis-clicks cluster under draft-clock pressure; single-level undo is not enough)
- **Draft-complete state**: after pick 150, show a final roster summary in place of the pick tracker

### 3. My Roster Panel

- Shows players the user has drafted, grouped by position slot
- Displays which starting slots are filled vs. empty
- **Slot fill order**: dedicated position slots first, then FLEX, then bench (e.g., a 3rd RB fills FLEX; a 4th goes to bench)
- Highlights roster gaps (e.g., "No TE drafted yet")
- **Bye week warnings** when multiple starters share a bye (e.g., "3 of your starters have a week 6 bye")

### 4. AI Recommendations Panel

- Powered by the **OpenRouter API** with a user-selectable model (default: `anthropic/claude-sonnet-4.5`); the setup screen offers a searchable picker populated from OpenRouter's public model catalog, with free-text entry as fallback
- **Trigger**: automatically when the user's pick is approaching (within ~2 picks), plus a manual "Refresh recommendations" button — **not** after every pick (~150 API calls per draft, most wasted since recommendations only matter near the user's turn)
- **Local fallback (required)**: a deterministic best-available-by-need list renders instantly from local data; the AI reasoning layers on top when the API responds. Live drafts have pick clocks — the panel must never be empty because the API is slow or errored
- Shows **top 5 recommended players** from the available pool
- Each recommendation includes:
  - Player name, team, position, rank, tier
  - Short reason for the recommendation (1 sentence)
- Recommendation logic considers:
  - Best available by overall PPR rank
  - **Tier breaks** (e.g., "last RB left in tier 3" is a strong reason to pick)
  - User's current roster composition and starting lineup needs
  - Round context (e.g., don't wait too long on QB/TE; K/DST in the final rounds)
- **Prompt payload**: send only the top ~30 available players (with tiers) and the user's roster — not all ~500 players — to keep latency and cost down
- Roster gap warnings displayed above recommendations (e.g., "⚠️ You have no TE — consider drafting one soon")

---

## UX Requirements

- **Single-page app** — no navigation, everything visible on one screen
- **Three-panel layout**: Available Players | My Roster | AI Recommendations
- Works on desktop/laptop screen (primary use case is sitting at a computer during a draft)
- Dark theme preferred — easier on the eyes during a live draft
- Fast and responsive — no lag when marking picks or generating recommendations

---

## Technical Constraints

- Built as a **local Vite + React app** (`npm run dev`, runs in the browser)
- Player data loaded via **CSV upload** at startup — no external sports API required
- AI recommendations use the **OpenRouter API** (`/api/v1/chat/completions`) via fetch with an `Authorization: Bearer` key — browser-CORS friendly, no proxy needed
  - The user supplies their OpenRouter key at setup (entered in the UI or pre-filled from `VITE_OPENROUTER_API_KEY` in `.env.local`; kept in memory — never hardcoded in the source)
  - Model is user-selectable at setup and persisted with the draft for resume
- No backend, no database, no authentication
- **Draft state persisted to `localStorage`** after every pick, with a "Resume draft?" prompt on reload — an accidental refresh mid-draft must not lose the board
- All other state managed in React

---

## Out of Scope (for now)

- Integration with Sleeper, ESPN, or Yahoo league APIs
- Live ADP or real-time ranking updates
- Multi-user or shared draft board
- Mobile optimization
- Saving/exporting draft results
