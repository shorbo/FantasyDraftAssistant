# Fantasy Football Assistant

A native macOS app that tracks a [Sleeper](https://sleeper.com) or Yahoo fantasy football draft, tracks your roster in real time, and helps you decide who to take next — from an instant consensus-rankings panel to an AI advisor that compares consensus rankings with your roster, league scoring, and flexible draft strategy. When the draft ends, it grades every team on a leaderboard so you can see exactly where you found value and where you reached.

Your draft room is the source of truth — the app never drafts for you. Sleeper syncs through its API; Yahoo completed picks arrive through the local browser extension.

## Features

- **Yahoo support** — configure scoring and lineup in setup, then connect the [local browser extension](browser-extension/yahoo/README.md)
- **Live Sleeper sync** — polls your draft (mock or real) every few seconds; snake, linear, and 3rd-round-reversal draft types all supported
- **Drafted / Available lists** — always-visible, auto-scrolling, filterable by search and position
- **My Roster** — starters and bench filled in real draft order, with gap and bye-week warnings
  - **Best Available** — a strategy-aware default pick using the current phase, roster needs, tiers, and consensus rank, followed by the top 3 undrafted players at each starting position
- **AI Advisor** (optional, on-demand) — an OpenRouter-backed advisor that:
  - Uses a shortlist ordered by consensus rank, with leading options at each eligible position
  - Compares tiers, roster needs, and ADP without synthetic projections or survival percentages
  - Adapts to actual lineup and scoring; Yahoo setup defaults to half-PPR
  - Enforces required-slot capacity and validates returned player IDs against the shortlist
  - Distinguishes your upcoming pick from the following pick when planning close selections
  - **Fast picks** (default on): compact answers, fastest supported reasoning, latency-prioritized routing, and a 12-second total request limit; an instant, clearly labeled rankings fallback stays available while waiting or after errors
  - Streams its response live (no more silent timeouts on slow models)
  - Ships with a **Chat** panel for open-ended follow-up questions, using the same live context
- **Draft Leaderboard** — grades every team by draft value (steals vs. reaches) and by projected best-lineup points, with a breakdown of your best picks and biggest reaches
- **Request logging** — every AI request/response is logged locally for troubleshooting

See [requirements.md](requirements.md) for the full functional spec.

## Requirements

- macOS 14+
- Xcode 15+ / Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the `.xcodeproj` is generated, not checked in
- A FantasyPros rankings export (CSV) for the current season
- Optional: FantasyPros per-position projection exports (CSV), and an [OpenRouter](https://openrouter.ai) API key for the AI advisor

## Getting Started

```sh
xcodegen generate
open FantasyFootballAssistant.xcodeproj
```

Build and run the `FantasyFootballAssistant` scheme. On first launch:

1. Load your FantasyPros rankings CSV and declare its scoring format (half-PPR, full-PPR, or standard). Use an export matching your league; the app does not convert rankings. Optional projection CSVs are used for the leaderboard.
2. Select Yahoo and enter your actual league scoring, lineup, and draft slot, or enter your Sleeper username/draft URL
3. (Optional) add an OpenRouter API key and pick a model to enable the AI Advisor
4. Connect and draft

### Command line

```sh
xcodegen generate
xcodebuild -project FantasyFootballAssistant.xcodeproj -scheme FantasyFootballAssistant build
xcodebuild -project FantasyFootballAssistant.xcodeproj -scheme FantasyFootballAssistant test
```

## Project Structure

```
FantasyFootballAssistant/
  App/            App entry point
  Models/         Core data types + Sleeper API DTOs
  Services/       Sleeper/OpenRouter clients, CSV parsing, draft math,
                  rankings shortlist, AI prompt building,
                  the draft grader, and session persistence
  ViewModels/      DraftSession — live draft state (@Observable)
  Views/           SwiftUI views (draft board, roster, advisor, chat, leaderboard)
FantasyFootballAssistantTests/
                  Unit tests for draft math, CSV parsing, name matching,
                  the analytics engine, the grader, and the AI prompts
project.yml        XcodeGen project spec
requirements.md     Full functional requirements
```

## Data Sources

- **Sleeper API** — public, read-only, no auth required
- **FantasyPros CSV exports** — rankings (required) and per-position projections (optional), loaded locally; not fetched automatically
- **OpenRouter** — optional, only used if you supply an API key for the AI Advisor/Chat

No backend, no database, no account system — everything runs locally except the Sleeper and (optional) OpenRouter API calls.

## Status

Draft assistant is the first tool in a planned Fantasy Football Assistant suite. In-season tools (waivers, start/sit, trades) are not yet implemented.
