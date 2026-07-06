export const FLEX_POSITIONS = ['RB', 'WR', 'TE'];

// Sleeper draft settings key → lineup slot definition, in display order.
const SLOT_DEFS = [
  ['slots_qb', 'QB', ['QB']],
  ['slots_rb', 'RB', ['RB']],
  ['slots_wr', 'WR', ['WR']],
  ['slots_te', 'TE', ['TE']],
  ['slots_flex', 'FLEX', FLEX_POSITIONS],
  ['slots_wrrb_flex', 'W/R', ['WR', 'RB']],
  ['slots_rec_flex', 'W/T', ['WR', 'TE']],
  ['slots_super_flex', 'SFLX', ['QB', 'RB', 'WR', 'TE']],
  ['slots_k', 'K', ['K']],
  ['slots_def', 'DST', ['DST']],
];

// Everything the app needs to know about a draft, derived from Sleeper's
// draft object once at connect time.
export function buildDraftConfig(draft, userId) {
  const s = draft.settings || {};
  const teams = s.teams || 0;
  const rounds = s.rounds || 0;

  const slots = [];
  for (const [key, label, positions] of SLOT_DEFS) {
    const n = s[key] || 0;
    for (let i = 1; i <= n; i++) {
      slots.push({ key: n > 1 ? `${label}${i}` : label, label, positions });
    }
  }

  return {
    draftId: draft.draft_id,
    leagueId: draft.league_id || null,
    name: draft.metadata?.name || 'Sleeper draft',
    season: draft.season,
    type: draft.type, // 'snake' | 'linear' | 'auction'
    reversalRound: s.reversal_round || 0,
    teams,
    rounds,
    totalPicks: teams * rounds,
    slots,
    benchSize: s.slots_bn ?? Math.max(0, rounds - slots.length),
    scoring: draft.metadata?.scoring_type || null,
    userSlot: draft.draft_order?.[userId] ?? null,
  };
}

export function roundForPick(pick, teams) {
  return Math.ceil(pick / teams);
}

// Which draft slot is on the clock for an overall pick number. Handles
// snake, linear, and snake with third-round reversal.
export function slotForPick(pick, config) {
  const { teams, type, reversalRound } = config;
  const round = roundForPick(pick, teams);
  const i = (pick - 1) % teams;
  if (type === 'linear') return i + 1;
  let forward = round % 2 === 1;
  if (reversalRound && round >= reversalRound) forward = !forward;
  return forward ? i + 1 : teams - i;
}

export function nextUserPick(currentPick, config) {
  if (!config.userSlot) return null;
  for (let p = currentPick; p <= config.totalPicks; p++) {
    if (slotForPick(p, config) === config.userSlot) return p;
  }
  return null;
}

// Assign drafted players to lineup slots in draft order:
// dedicated single-position slots first, then flex slots, then bench.
export function assignRoster(myPlayers, slots) {
  const starters = slots.map((slot) => ({ ...slot, player: null }));
  const bench = [];

  for (const player of myPlayers) {
    const dedicated = starters.find(
      (s) => !s.player && s.positions.length === 1 && s.positions[0] === player.pos
    );
    if (dedicated) {
      dedicated.player = player;
      continue;
    }
    const flex = starters.find(
      (s) => !s.player && s.positions.length > 1 && s.positions.includes(player.pos)
    );
    if (flex) {
      flex.player = player;
      continue;
    }
    bench.push(player);
  }

  return { starters, bench };
}

export function rosterGaps(starters, round, rounds) {
  const gaps = [];
  const emptyByLabel = {};
  for (const s of starters) {
    if (!s.player && s.positions.length === 1) {
      emptyByLabel[s.label] = (emptyByLabel[s.label] || 0) + 1;
    }
  }
  for (const [label, count] of Object.entries(emptyByLabel)) {
    if ((label === 'K' || label === 'DST') && round < rounds - 3) continue; // expected to be open early
    gaps.push(count > 1 ? `${count} ${label} slots open` : `No ${label} drafted yet`);
  }
  return gaps;
}

export function byeWarnings(starters) {
  const byes = {};
  for (const s of starters) {
    if (s.player?.bye) byes[s.player.bye] = (byes[s.player.bye] || 0) + 1;
  }
  return Object.entries(byes)
    .filter(([, count]) => count >= 3)
    .map(([week, count]) => `${count} of your starters have a week ${week} bye`);
}
