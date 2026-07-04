export const TEAMS = 10;
export const ROUNDS = 15;
export const TOTAL_PICKS = TEAMS * ROUNDS;

export const FLEX_POSITIONS = ['RB', 'WR', 'TE'];

export const STARTING_SLOTS = [
  { key: 'QB', label: 'QB', positions: ['QB'] },
  { key: 'RB1', label: 'RB', positions: ['RB'] },
  { key: 'RB2', label: 'RB', positions: ['RB'] },
  { key: 'WR1', label: 'WR', positions: ['WR'] },
  { key: 'WR2', label: 'WR', positions: ['WR'] },
  { key: 'TE', label: 'TE', positions: ['TE'] },
  { key: 'FLEX', label: 'FLEX', positions: FLEX_POSITIONS },
  { key: 'K', label: 'K', positions: ['K'] },
  { key: 'DST', label: 'DST', positions: ['DST'] },
];

export const BENCH_SIZE = 6; // 15 roster spots - 9 starters

export function roundForPick(pick) {
  return Math.ceil(pick / TEAMS);
}

// Snake order: odd rounds 1→10, even rounds 10→1.
export function teamSlotForPick(pick) {
  const round = roundForPick(pick);
  const i = (pick - 1) % TEAMS;
  return round % 2 === 1 ? i + 1 : TEAMS - i;
}

export function userPickNumbers(userSlot) {
  const picks = [];
  for (let p = 1; p <= TOTAL_PICKS; p++) {
    if (teamSlotForPick(p) === userSlot) picks.push(p);
  }
  return picks;
}

export function nextUserPick(currentPick, userSlot) {
  for (let p = currentPick; p <= TOTAL_PICKS; p++) {
    if (teamSlotForPick(p) === userSlot) return p;
  }
  return null;
}

// Assign drafted players to lineup slots in draft order:
// dedicated slots first, then FLEX, then bench.
export function assignRoster(myPlayers) {
  const starters = STARTING_SLOTS.map((slot) => ({ ...slot, player: null }));
  const bench = [];

  for (const player of myPlayers) {
    const dedicated = starters.find(
      (s) => !s.player && s.key !== 'FLEX' && s.positions.includes(player.pos)
    );
    if (dedicated) {
      dedicated.player = player;
      continue;
    }
    const flex = starters.find(
      (s) => !s.player && s.key === 'FLEX' && s.positions.includes(player.pos)
    );
    if (flex) {
      flex.player = player;
      continue;
    }
    bench.push(player);
  }

  return { starters, bench };
}

export function rosterGaps(starters, round) {
  const gaps = [];
  const emptyByLabel = {};
  for (const s of starters) {
    if (!s.player) emptyByLabel[s.label] = (emptyByLabel[s.label] || 0) + 1;
  }
  for (const [label, count] of Object.entries(emptyByLabel)) {
    if ((label === 'K' || label === 'DST') && round < 12) continue; // expected to be open early
    if (label === 'FLEX') continue; // fills from RB/WR/TE depth
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
