import { useEffect, useMemo, useRef, useState } from 'react';
import SetupScreen from './components/SetupScreen.jsx';
import DraftHeader from './components/DraftHeader.jsx';
import PlayerList from './components/PlayerList.jsx';
import RosterPanel from './components/RosterPanel.jsx';
import RecommendationsPanel from './components/RecommendationsPanel.jsx';
import {
  TOTAL_PICKS,
  teamSlotForPick,
  nextUserPick,
  assignRoster,
  rosterGaps,
  byeWarnings,
  roundForPick,
} from './lib/draft.js';
import { localRecommendations } from './lib/recommend.js';
import { fetchAiRecommendations, DEFAULT_MODEL } from './lib/llm.js';
import { saveDraft, loadDraft, clearDraft } from './lib/storage.js';

const ENV_API_KEY = import.meta.env.VITE_OPENROUTER_API_KEY || '';
const AI_TRIGGER_WINDOW = 2; // fetch AI recs when the user's pick is this close

const idleAi = { status: 'idle', recs: null, forPick: null, error: null };

export default function App() {
  const [session, setSession] = useState(null); // { userSlot, players, apiKey, model, teamNames }
  const [picks, setPicks] = useState([]);
  const [savedDraft, setSavedDraft] = useState(() => loadDraft());
  const [aiState, setAiState] = useState(idleAi);
  const aiRequestRef = useRef(0);
  const abortRef = useRef(null);

  const currentPick = picks.length + 1;
  const complete = picks.length >= TOTAL_PICKS;

  const playersById = useMemo(() => {
    const map = new Map();
    for (const p of session?.players || []) map.set(p.id, p);
    return map;
  }, [session]);

  const draftedIds = useMemo(() => new Set(picks.map((p) => p.playerId)), [picks]);

  const myPlayers = useMemo(
    () =>
      picks
        .filter((p) => p.teamSlot === session?.userSlot)
        .map((p) => playersById.get(p.playerId))
        .filter(Boolean),
    [picks, session, playersById]
  );

  const available = useMemo(
    () => (session?.players || []).filter((p) => !draftedIds.has(p.id)),
    [session, draftedIds]
  );

  const { starters, bench } = useMemo(() => assignRoster(myPlayers), [myPlayers]);
  const gaps = useMemo(
    () => rosterGaps(starters, roundForPick(Math.min(currentPick, TOTAL_PICKS))),
    [starters, currentPick]
  );
  const byes = useMemo(() => byeWarnings(starters), [starters]);

  const fallbackRecs = useMemo(
    () => localRecommendations(available, myPlayers, Math.min(currentPick, TOTAL_PICKS)),
    [available, myPlayers, currentPick]
  );

  // AI recs are only shown for the pick they were generated for; anything
  // else falls back to the local engine so the panel is never stale or empty.
  const displayedRecs = useMemo(() => {
    if (aiState.status !== 'ready' || aiState.forPick !== currentPick) return fallbackRecs;
    const aiRecs = aiState.recs
      .map((r) => ({ player: playersById.get(r.id), reason: r.reason, tierBreak: false }))
      .filter((r) => r.player && !draftedIds.has(r.player.id));
    if (aiRecs.length === 0) return fallbackRecs;
    for (const fb of fallbackRecs) {
      if (aiRecs.length >= 5) break;
      if (!aiRecs.some((r) => r.player.id === fb.player.id)) aiRecs.push(fb);
    }
    return aiRecs.slice(0, 5);
  }, [aiState, currentPick, fallbackRecs, playersById, draftedIds]);

  const nextUp = session ? nextUserPick(currentPick, session.userSlot) : null;

  useEffect(() => {
    if (session)
      saveDraft({
        userSlot: session.userSlot,
        players: session.players,
        picks,
        model: session.model,
        teamNames: session.teamNames,
      });
  }, [session, picks]);

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
      userSlot: session.userSlot,
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

  // Auto-trigger when the user's next pick is close.
  useEffect(() => {
    if (!session?.apiKey || complete || nextUp === null) return;
    if (nextUp - currentPick > AI_TRIGGER_WINDOW) return;
    if (aiState.forPick === currentPick && aiState.status !== 'error') return;
    triggerAi();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentPick, session, complete]);

  function handleStart({ players, userSlot, apiKey, model, teamNames }) {
    clearDraft();
    setSavedDraft(null);
    setPicks([]);
    setAiState(idleAi);
    setSession({ players, userSlot, apiKey, model, teamNames });
  }

  function handleResume() {
    if (!savedDraft) return;
    setPicks(savedDraft.picks);
    setSession({
      players: savedDraft.players,
      userSlot: savedDraft.userSlot,
      apiKey: ENV_API_KEY,
      model: savedDraft.model || DEFAULT_MODEL,
      teamNames: savedDraft.teamNames || Array.from({ length: 10 }, (_, i) => `Team ${i + 1}`),
    });
    setSavedDraft(null);
  }

  function handleDiscardSaved() {
    clearDraft();
    setSavedDraft(null);
  }

  function draftPlayer(playerId) {
    if (complete || draftedIds.has(playerId)) return;
    setPicks((prev) => [
      ...prev,
      { pickNumber: prev.length + 1, playerId, teamSlot: teamSlotForPick(prev.length + 1) },
    ]);
  }

  function undo() {
    setPicks((prev) => prev.slice(0, -1));
  }

  // Correction affordance: flip a recent pick between "mine" and "another
  // team" (0 = generic other team) without disturbing the pick order.
  function togglePickOwner(pickNumber) {
    setPicks((prev) =>
      prev.map((p) => {
        if (p.pickNumber !== pickNumber) return p;
        const isMine = p.teamSlot === session.userSlot;
        return { ...p, teamSlot: isMine ? 0 : session.userSlot };
      })
    );
  }

  if (!session) {
    return (
      <SetupScreen
        savedDraft={savedDraft}
        onResume={handleResume}
        onDiscardSaved={handleDiscardSaved}
        defaultApiKey={ENV_API_KEY}
        onStart={handleStart}
      />
    );
  }

  const recentPicks = {
    onClockSlot: complete ? null : teamSlotForPick(currentPick),
    items: picks.slice(-4).map((pick) => ({
      pick,
      player: playersById.get(pick.playerId),
      isMine: pick.teamSlot === session.userSlot,
    })),
  };

  return (
    <div className="app">
      <DraftHeader
        currentPick={currentPick}
        userSlot={session.userSlot}
        teamNames={session.teamNames}
        nextUserPickNum={nextUp}
        recentPicks={recentPicks}
        onUndo={undo}
        onTogglePickOwner={togglePickOwner}
        complete={complete}
      />
      <div className="panels">
        <PlayerList
          players={session.players}
          draftedIds={draftedIds}
          onDraft={draftPlayer}
          disabled={complete}
        />
        <RosterPanel starters={starters} bench={bench} gaps={gaps} byes={byes} complete={complete} />
        <RecommendationsPanel
          recs={displayedRecs}
          aiState={aiState}
          model={session.model}
          hasApiKey={Boolean(session.apiKey)}
          onRefresh={triggerAi}
          onDraft={draftPlayer}
          disabled={complete}
        />
      </div>
    </div>
  );
}
