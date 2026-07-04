const KEY = 'fantasy-draft-assistant-v1';

// Players are persisted along with picks so a mid-draft refresh can resume
// without re-uploading the CSV.
export function saveDraft({ userSlot, players, picks, model, teamNames }) {
  try {
    localStorage.setItem(
      KEY,
      JSON.stringify({ userSlot, players, picks, model, teamNames, savedAt: Date.now() })
    );
  } catch {
    // Quota/private-mode failures shouldn't break the draft.
  }
}

export function loadDraft() {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return null;
    const data = JSON.parse(raw);
    if (!data || !Array.isArray(data.players) || !Array.isArray(data.picks) || !data.userSlot) {
      return null;
    }
    return data;
  } catch {
    return null;
  }
}

export function clearDraft() {
  try {
    localStorage.removeItem(KEY);
  } catch {
    // ignore
  }
}
