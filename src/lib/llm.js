import { roundForPick, assignRoster } from './draft.js';

const API_URL = 'https://openrouter.ai/api/v1/chat/completions';
const MODELS_URL = 'https://openrouter.ai/api/v1/models';

export const DEFAULT_MODEL = 'anthropic/claude-sonnet-4.5';

// OpenRouter's public model catalog — used to populate the setup screen's
// model picker. Failure is non-fatal; the picker falls back to free text.
export async function fetchModelList() {
  const res = await fetch(MODELS_URL);
  if (!res.ok) throw new Error(`Model list fetch failed: ${res.status}`);
  const data = await res.json();
  return (data.data || [])
    .map((m) => m.id)
    .filter(Boolean)
    .sort();
}

// Asks the selected model for 5 recommendations from the top 30 available
// players. Returns [{ id, reason }]; throws on network/API/parse failure —
// the caller keeps showing local fallback recommendations in that case.
export async function fetchAiRecommendations({
  apiKey,
  model,
  available,
  myPlayers,
  currentPick,
  userSlot,
  signal,
}) {
  const response = await fetch(API_URL, {
    method: 'POST',
    signal,
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${apiKey}`,
      'x-title': 'Fantasy Draft Assistant',
    },
    body: JSON.stringify({
      model: model || DEFAULT_MODEL,
      max_tokens: 1000,
      messages: [
        { role: 'user', content: buildPrompt({ available, myPlayers, currentPick, userSlot }) },
      ],
    }),
  });

  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(`OpenRouter error ${response.status}: ${body.slice(0, 200)}`);
  }

  const data = await response.json();
  if (data.error) {
    throw new Error(`OpenRouter error: ${data.error.message || JSON.stringify(data.error)}`);
  }
  const text = data.choices?.[0]?.message?.content || '';
  const recs = extractJson(text);
  if (!Array.isArray(recs) || recs.length === 0) {
    throw new Error('Model returned no parseable recommendations.');
  }
  return recs
    .filter((r) => Number.isFinite(r.id) && typeof r.reason === 'string')
    .slice(0, 5);
}

function buildPrompt({ available, myPlayers, currentPick, userSlot }) {
  const round = roundForPick(currentPick);
  const { starters, bench } = assignRoster(myPlayers);
  const rosterLines = starters
    .map((s) => `${s.key}: ${s.player ? playerLine(s.player) : 'EMPTY'}`)
    .concat(bench.map((p) => `BENCH: ${playerLine(p)}`))
    .join('\n');
  const availableLines = available
    .slice(0, 30)
    .map((p) => `id=${p.id} ${playerLine(p)}`)
    .join('\n');

  return `You are a fantasy football draft assistant for a 10-team full-PPR snake draft (15 rounds). Starting lineup: 1 QB, 2 RB, 2 WR, 1 TE, 1 FLEX (RB/WR/TE), 1 K, 1 DST, 6 bench.

I draft from slot ${userSlot}. It is currently round ${round}, overall pick ${currentPick}, and I'm on the clock or about to be.

MY ROSTER SO FAR:
${rosterLines}

TOP AVAILABLE PLAYERS (FantasyPros PPR consensus; lower rank and lower tier are better):
${availableLines}

Recommend the 5 best picks for me right now, considering best available value, my open starting slots, tier cliffs at each position, round context (don't reach for K/DST before the final rounds), and bye-week stacking on my current starters.

Respond with ONLY a JSON array, no other text:
[{"id": <player id>, "reason": "<one sentence>"}]
Order from best pick to fifth-best.`;
}

function playerLine(p) {
  return `${p.name} (${p.team}, ${p.pos}${p.posRank}, rank ${p.rank}, tier ${p.tier ?? '?'}, bye ${p.bye ?? '?'})`;
}

function extractJson(text) {
  const start = text.indexOf('[');
  const end = text.lastIndexOf(']');
  if (start === -1 || end === -1 || end < start) return null;
  try {
    return JSON.parse(text.slice(start, end + 1));
  } catch {
    return null;
  }
}
