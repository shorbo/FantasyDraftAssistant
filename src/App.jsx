import { useEffect, useMemo, useRef, useState } from 'react';
import SetupScreen from './components/SetupScreen.jsx';
import DraftHeader from './components/DraftHeader.jsx';
import PlayerList from './components/PlayerList.jsx';
import RosterPanel from './components/RosterPanel.jsx';
import RecommendationsPanel from './components/RecommendationsPanel.jsx';
import {
  buildDraftConfig,
  slotForPick,
  nextUserPick,
  assignRoster,
  rosterGaps,
  byeWarnings,
  roundForPick,
} from './lib/draft.js';
import { getDraft, buildPickResolver } from './lib/sleeper.js';
import { useSleeperDraft } from './hooks/useSleeperDraft.js';
import { localRecommendations } from './lib/recommend.js';
import { fetchAiRecommendations, DEFAULT_MODEL } from './lib/llm.js';
import { saveSession, loadSession, clearSession } from './lib/storage.js';

const ENV_API_KEY = import.meta.env.VITE_OPENROUTER_API_KEY || '';
const AI_TRIGGER_WINDOW = 2; // fetch AI recs when the user's pick is this close

const idleAi = { status: 'idle', recs: null, forPick: null, error: null };

export default function App() {
  // session: { players, draft, config, userId, apiKey, model, teamNames }
  const [session, setSession] = useState(null);
  const [savedSession, setSavedSession] = useState(() => loadSession());
  const [resuming, setResuming] = useState(false);
  const [resumeError, setResumeError] = useState(null);
  const [aiState, setAiState] = useState(idleAi);
  const aiRequestRef = useRef(0);
  const abortRef = useRef(null);

  const { draft: liveDraft, picks: rawPicks, error: syncError, lastSync } = useSleeperDraft(
    session?.draft
  );

  const config = session?.config || null;
  const draftStatus = liveDraft?.status || 'pre_draft';

  const resolvePick = useMemo(() => buildPickResolver(session?.players || []), [session]);

  // Sleeper picks → view picks. draft_slot (not picked_by) decides ownership
  // so autopicked players still land on the right roster.
  const picks = useMemo(
    () =>
      (rawPicks || [])
        .map((pk) => ({
          pickNumber: pk.pick_no,
          slot: pk.draft_slot,
          player: resolvePick(pk),
          isMine: pk.draft_slot === config?.userSlot,
        }))
        .sort((a, b) => a.pickNumber - b.pickNumber),
    [rawPicks, resolvePick, config]
  );

  const currentPick = picks.length + 1;
  const complete =
    draftStatus === 'complete' || (config ? picks.length >= config.totalPicks : false);
  const clampedPick = config ? Math.min(currentPick, config.totalPicks) : 1;

  const draftedIds = useMemo(() => new Set(picks.map((p) => p.player.id)), [picks]);
  const myPlayers = useMemo(() => picks.filter((p) => p.isMine).map((p) => p.player), [picks]);
  const available = useMemo(
    () => (session?.players || []).filter((p) => !draftedIds.has(p.id)),
    [session, draftedIds]
  );

  const { starters, bench } = useMemo(
    () => (config ? assignRoster(myPlayers, config.slots) : { starters: [], bench: [] }),
    [myPlayers, config]
  );
  const gaps = useMemo(
    () => (config ? rosterGaps(starters, roundForPick(clampedPick, config.teams), config.rounds) : []),
    [starters, clampedPick, config]
  );
  const byes = useMemo(() => byeWarnings(starters), [starters]);

  const fallbackRecs = useMemo(
    () => (config ? localRecommendations(available, myPlayers, clampedPick, config) : []),
    [available, myPlayers, clampedPick, config]
  );

  // AI recs are only shown for the pick they were generated for; anything
  // else falls back to the local engine so the panel is never stale or empty.
  const displayedRecs = useMemo(() => {
    if (aiState.status !== 'ready' || aiState.forPick !== currentPick) return fallbackRecs;
    const availableById = new Map(available.map((p) => [p.id, p]));
    const aiRecs = aiState.recs
      .map((r) => ({ player: availableById.get(r.id), reason: r.reason, tierBreak: false }))
      .filter((r) => r.player);
    if (aiRecs.length === 0) return fallbackRecs;
    for (const fb of fallbackRecs) {
      if (aiRecs.length >= 5) break;
      if (!aiRecs.some((r) => r.player.id === fb.player.id)) aiRecs.push(fb);
    }
    return aiRecs.slice(0, 5);
  }, [aiState, currentPick, fallbackRecs, available]);

  const nextUp = config ? nextUserPick(currentPick, config) : null;

  useEffect(() => {
    if (session)
      saveSession({
        draftId: session.config.draftId,
        draftName: session.config.name,
        userId: session.userId,
        players: session.players,
        model: session.model,
        teamNames: session.teamNames,
      });
  }, [session]);

  function triggerAi() {
    if (!session?.apiKey || complete || available.length === 0) return;
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    const requestId = ++aiRequestRef.current;
    const forPick = currentPick;
    setAiState({ status: 'loading', recs: null, forPick, error: null });
    fetchAiRecommendations({
      apiKey: session.apiKey,
      model: session.model,
      available,
      myPlayers,
      currentPick,
      config,
      signal: controller.signal,
    })
      .then((recs) => {
        if (aiRequestRef.current !== requestId) return; // stale response
        setAiState({ status: 'ready', recs, forPick, error: null });
      })
      .catch((err) => {
        if (aiRequestRef.current !== requestId || err.name === 'AbortError') return;
        setAiState({ status: 'error', recs: null, forPick, error: String(err.message || err) });
      });
  }

  // Auto-trigger when the draft is live and the user's next pick is close.
  useEffect(() => {
    if (!session?.apiKey || complete || nextUp === null) return;
    if (draftStatus !== 'drafting') return;
    if (nextUp - currentPick > AI_TRIGGER_WINDOW) return;
    if (aiState.forPick === currentPick && aiState.status !== 'error') return;
    triggerAi();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentPick, session, complete, draftStatus]);

  function handleStart({ players, draft, config: newConfig, userId, apiKey, model, teamNames }) {
    clearSession();
    setSavedSession(null);
    setAiState(idleAi);
    setSession({ players, draft, config: newConfig, userId, apiKey, model, teamNames });
  }

  async function handleResume() {
    if (!savedSession || resuming) return;
    setResuming(true);
    setResumeError(null);
    try {
      const draft = await getDraft(savedSession.draftId);
      if (!draft) throw new Error('That draft no longer exists on Sleeper.');
      const resumedConfig = buildDraftConfig(draft, savedSession.userId);
      setAiState(idleAi);
      setSession({
        players: savedSession.players,
        draft,
        config: resumedConfig,
        userId: savedSession.userId,
        apiKey: ENV_API_KEY,
        model: savedSession.model || DEFAULT_MODEL,
        teamNames: savedSession.teamNames || [],
      });
      setSavedSession(null);
    } catch (err) {
      setResumeError(String(err.message || err));
    } finally {
      setResuming(false);
    }
  }

  function handleDiscardSaved() {
    clearSession();
    setSavedSession(null);
    setResumeError(null);
  }

  function handleLeave() {
    abortRef.current?.abort();
    setAiState(idleAi);
    setSession(null);
    setSavedSession(loadSession()); // the session was auto-saved; offer to rejoin
  }

  if (!session) {
    return (
      <SetupScreen
        savedSession={savedSession}
        onResume={handleResume}
        resuming={resuming}
        resumeError={resumeError}
        onDiscardSaved={handleDiscardSaved}
        defaultApiKey={ENV_API_KEY}
        onStart={handleStart}
      />
    );
  }

  const recentPicks = {
    onClockSlot: complete ? null : slotForPick(clampedPick, config),
    items: picks.slice(-4),
  };

  return (
    <div className="app">
      <DraftHeader
        currentPick={currentPick}
        config={config}
        teamNames={session.teamNames}
        nextUserPickNum={nextUp}
        recentPicks={recentPicks}
        complete={complete}
        draftStatus={draftStatus}
        syncError={syncError}
        lastSync={lastSync}
        onLeave={handleLeave}
      />
      <div className="panels">
        <PlayerList players={session.players} draftedIds={draftedIds} />
        <RosterPanel
          starters={starters}
          bench={bench}
          benchSize={config.benchSize}
          gaps={gaps}
          byes={byes}
          complete={complete}
        />
        <RecommendationsPanel
          recs={displayedRecs}
          aiState={aiState}
          model={session.model}
          hasApiKey={Boolean(session.apiKey)}
          onRefresh={triggerAi}
          disabled={complete}
        />
      </div>
    </div>
  );
}
