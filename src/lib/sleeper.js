const BASE = 'https://api.sleeper.app/v1';

async function get(path) {
  const res = await fetch(`${BASE}${path}`);
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Sleeper API error ${res.status} for ${path}`);
  return res.json();
}

export function getUser(usernameOrId) {
  return get(`/user/${encodeURIComponent(String(usernameOrId).trim())}`);
}

export function getUserDrafts(userId, season) {
  return get(`/user/${userId}/drafts/nfl/${season}`);
}

export function getDraft(draftId) {
  return get(`/draft/${draftId}`);
}

export function getDraftPicks(draftId) {
  return get(`/draft/${draftId}/picks`);
}

export function getLeagueUsers(leagueId) {
  return get(`/league/${leagueId}/users`);
}

export function currentSeason() {
  return String(new Date().getFullYear());
}

// Accepts a raw draft id or any sleeper.com draft URL
// (e.g. https://sleeper.com/draft/nfl/123456789012345678).
export function parseDraftInput(input) {
  const s = String(input || '').trim();
  const m = s.match(/draft\/(?:nfl\/)?(\d{10,})/) || s.match(/^(\d{10,})$/);
  return m ? m[1] : null;
}

/* ---------- Player database (trimmed + cached) ---------- */

const PLAYERS_CACHE_KEY = 'sleeper-players-nfl-v2';
const PLAYERS_TTL_MS = 24 * 60 * 60 * 1000; // Sleeper asks for at most one fetch/day
// FB included because rankings sites list fullbacks as RB.
const FANTASY_POSITIONS = new Set(['QB', 'RB', 'FB', 'WR', 'TE', 'K', 'DEF']);

function normPos(position) {
  if (position === 'DEF') return 'DST';
  if (position === 'FB') return 'RB';
  return position;
}

// The full dump is ~5MB; we keep only fantasy-relevant positions and the
// fields needed for name matching, which fits comfortably in localStorage.
export async function loadPlayersDb() {
  try {
    const cached = JSON.parse(localStorage.getItem(PLAYERS_CACHE_KEY));
    if (cached && Date.now() - cached.fetchedAt < PLAYERS_TTL_MS) return cached.players;
  } catch {
    // fall through to a fresh fetch
  }

  const raw = await get('/players/nfl');
  const players = {};
  for (const [id, p] of Object.entries(raw || {})) {
    if (!FANTASY_POSITIONS.has(p.position)) continue;
    players[id] = {
      name: p.full_name || `${p.first_name || ''} ${p.last_name || ''}`.trim(),
      pos: normPos(p.position),
      team: p.team || null,
      active: p.active === true,
    };
  }

  try {
    localStorage.setItem(PLAYERS_CACHE_KEY, JSON.stringify({ fetchedAt: Date.now(), players }));
  } catch {
    // cache miss next session is fine
  }
  return players;
}

/* ---------- Name matching (FantasyPros rankings ↔ Sleeper ids) ---------- */

// Both sides use slightly different team codes for a few franchises.
const TEAM_ALIASES = {
  JAC: 'JAX',
  WSH: 'WAS',
  ARZ: 'ARI',
  BLT: 'BAL',
  CLV: 'CLE',
  HST: 'HOU',
  LA: 'LAR',
  SD: 'LAC',
  STL: 'LAR',
  OAK: 'LV',
};

function normTeam(team) {
  const t = String(team || '').toUpperCase();
  return TEAM_ALIASES[t] || t;
}

const NAME_SUFFIXES = new Set(['jr', 'sr', 'ii', 'iii', 'iv', 'v']);

// Ranking sites sometimes use nicknames where Sleeper has the legal name.
const NAME_ALIASES = {
  'hollywood brown': 'marquise brown',
  'bam knight': 'zonovan knight',
  'gabe davis': 'gabriel davis',
  'josh palmer': 'joshua palmer',
  'mitch trubisky': 'mitchell trubisky',
  'chig okonkwo': 'chigoziem okonkwo',
};

export function normalizeName(name) {
  const tokens = String(name || '')
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, '')
    .split(/\s+/)
    .filter(Boolean);
  while (tokens.length > 2 && NAME_SUFFIXES.has(tokens[tokens.length - 1])) tokens.pop();
  const joined = tokens.join(' ');
  return NAME_ALIASES[joined] || joined;
}

function nameKey(pos, name) {
  return `${pos}:${normalizeName(name)}`;
}

// Annotates each rankings player with its Sleeper player id (sleeperId: null
// when no confident match). Sleeper DEF ids are team codes ("PHI"), so DSTs
// match on team rather than name.
export function matchPlayersToSleeper(players, db) {
  const byName = new Map();
  const dstByTeam = new Map();
  for (const [id, p] of Object.entries(db || {})) {
    if (p.pos === 'DST') {
      dstByTeam.set(normTeam(id), id);
      continue;
    }
    const key = nameKey(p.pos, p.name);
    if (!byName.has(key)) byName.set(key, []);
    byName.get(key).push(id);
  }

  return players.map((p) => {
    let sleeperId = null;
    if (p.pos === 'DST') {
      sleeperId = dstByTeam.get(normTeam(p.team)) || null;
    } else {
      const candidates = byName.get(nameKey(p.pos, p.name)) || [];
      if (candidates.length === 1) {
        sleeperId = candidates[0];
      } else if (candidates.length > 1) {
        // Same name + position (e.g. a retired namesake): prefer team, then active.
        sleeperId =
          candidates.find((id) => normTeam(db[id].team) === normTeam(p.team)) ||
          candidates.find((id) => db[id].active) ||
          candidates[0];
      }
    }
    return { ...p, sleeperId };
  });
}

// Maps a Sleeper pick to a rankings player: by sleeperId first, then by
// name+position from the pick's metadata, else a stub so rosters still track
// players outside the rankings file.
export function buildPickResolver(players) {
  const bySleeperId = new Map();
  const byName = new Map();
  for (const p of players) {
    if (p.sleeperId && !bySleeperId.has(p.sleeperId)) bySleeperId.set(p.sleeperId, p);
    const key = nameKey(p.pos, p.name);
    if (!byName.has(key)) byName.set(key, p);
  }
  const stubs = new Map();

  return function resolvePick(pick) {
    const direct = bySleeperId.get(pick.player_id);
    if (direct) return direct;

    const md = pick.metadata || {};
    const pos = md.position === 'DEF' ? 'DST' : md.position;
    const name = `${md.first_name || ''} ${md.last_name || ''}`.trim();
    const byNameMatch = byName.get(nameKey(pos, name));
    if (byNameMatch) return byNameMatch;

    if (!stubs.has(pick.player_id)) {
      stubs.set(pick.player_id, {
        id: `sleeper-${pick.player_id}`,
        sleeperId: pick.player_id,
        rank: null,
        posRank: null,
        tier: null,
        bye: null,
        name: name || `Player ${pick.player_id}`,
        pos: pos || '?',
        team: md.team || '',
        unranked: true,
      });
    }
    return stubs.get(pick.player_id);
  };
}
