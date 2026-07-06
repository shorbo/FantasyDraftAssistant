import { assignRoster, roundForPick } from './draft.js';

// Deterministic best-available-by-need recommendations. This renders
// instantly and is the panel's floor when the AI is slow or down.
export function localRecommendations(available, myPlayers, currentPick, config) {
  const round = roundForPick(currentPick, config.teams);
  const { starters } = assignRoster(myPlayers, config.slots);
  const openPositions = new Set(
    starters
      .filter((s) => !s.player && s.positions.length === 1)
      .flatMap((s) => s.positions)
  );
  const openFlexPositions = new Set(
    starters
      .filter((s) => !s.player && s.positions.length > 1)
      .flatMap((s) => s.positions)
  );
  const lastInTier = tierBreakSet(available);
  const lateRounds = config.rounds - 2; // when K/DST become fair game
  const scarcityRound = Math.max(2, config.rounds - 7); // when open QB/TE turns urgent

  const scored = available.map((p) => {
    let score = p.rank;
    let reason = null;

    if (openPositions.has(p.pos) && p.pos !== 'K' && p.pos !== 'DST') {
      score -= 12;
      reason = `Fills your open ${p.pos} slot as the best one available.`;
    } else if (openFlexPositions.has(p.pos)) {
      score -= 4;
      reason = `Best available for your open flex slot.`;
    }

    // Don't burn early picks on K/DST; make them urgent at the end.
    if (p.pos === 'K' || p.pos === 'DST') {
      if (round < lateRounds) score += 500;
      else if (openPositions.has(p.pos)) {
        score -= 100;
        reason = `Time to lock in your ${p.pos} — top option still on the board.`;
      }
    }

    // Positional scarcity: don't leave QB/TE open into the late-middle rounds.
    if ((p.pos === 'QB' || p.pos === 'TE') && openPositions.has(p.pos) && round >= scarcityRound) {
      score -= 15;
      reason = `The ${p.pos} pool thins out fast — don't wait much longer.`;
    }

    if (lastInTier.has(p.id)) {
      score -= 8;
      if (!reason) reason = `Last ${p.pos} left in tier ${p.tier} — a cliff follows.`;
    }

    if (!reason) reason = `Best player available at overall rank ${p.rank}.`;
    return { player: p, score, reason, tierBreak: lastInTier.has(p.id) };
  });

  scored.sort((a, b) => a.score - b.score);
  return scored.slice(0, 5);
}

// Player ids that are the last available in their tier at their position.
function tierBreakSet(available) {
  const counts = {};
  for (const p of available) {
    if (!p.tier) continue;
    const key = `${p.pos}:${p.tier}`;
    counts[key] = (counts[key] || 0) + 1;
  }
  const set = new Set();
  for (const p of available) {
    if (p.tier && counts[`${p.pos}:${p.tier}`] === 1) set.add(p.id);
  }
  return set;
}
