import { useEffect, useState } from 'react';
import { getDraft, getDraftPicks } from '../lib/sleeper.js';

const POLL_MS = 3000;
const DRAFT_REFRESH_TICKS = 5; // re-fetch the draft object (for status) every Nth poll

// Live-syncs a Sleeper draft: polls picks every few seconds and refreshes the
// draft object periodically to track status (pre_draft → drafting → complete).
// Polling stops once the draft is complete.
export function useSleeperDraft(initialDraft) {
  const draftId = initialDraft?.draft_id || null;
  const [draft, setDraft] = useState(null);
  const [picks, setPicks] = useState([]);
  const [error, setError] = useState(null);
  const [lastSync, setLastSync] = useState(null);

  useEffect(() => {
    if (!draftId) return undefined;
    let stopped = false;
    let timer = null;
    let ticks = 0;
    let status = initialDraft.status;
    const totalPicks =
      (initialDraft.settings?.teams || 0) * (initialDraft.settings?.rounds || 0);

    setDraft(initialDraft);
    setPicks([]);
    setError(null);

    async function tick() {
      try {
        const latest = await getDraftPicks(draftId);
        if (stopped) return;
        setPicks(latest || []);
        setLastSync(Date.now());
        setError(null);

        ticks += 1;
        const looksDone = totalPicks > 0 && (latest?.length || 0) >= totalPicks;
        if (status !== 'complete' && (looksDone || ticks % DRAFT_REFRESH_TICKS === 0)) {
          const fresh = await getDraft(draftId);
          if (stopped) return;
          if (fresh) {
            status = fresh.status;
            setDraft(fresh);
          }
        }
      } catch (err) {
        if (!stopped) setError(String(err.message || err));
      }
      if (!stopped && status !== 'complete') timer = setTimeout(tick, POLL_MS);
    }

    tick();
    return () => {
      stopped = true;
      clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draftId]);

  return { draft: draft || initialDraft || null, picks, error, lastSync };
}
