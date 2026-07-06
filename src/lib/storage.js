const KEY = 'fantasy-football-assistant-v2';

// Picks are NOT stored — Sleeper is the source of truth, so resuming a
// session just reconnects to the draft and re-fetches them. We persist the
// matched rankings so a mid-draft refresh doesn't need the CSV again.
export function saveSession({ draftId, draftName, userId, players, model, teamNames }) {
  try {
    localStorage.setItem(
      KEY,
      JSON.stringify({ draftId, draftName, userId, players, model, teamNames, savedAt: Date.now() })
    );
  } catch {
    // Quota/private-mode failures shouldn't break the draft.
  }
}

export function loadSession() {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return null;
    const data = JSON.parse(raw);
    if (!data || !data.draftId || !data.userId || !Array.isArray(data.players)) return null;
    return data;
  } catch {
    return null;
  }
}

export function clearSession() {
  try {
    localStorage.removeItem(KEY);
  } catch {
    // ignore
  }
}
