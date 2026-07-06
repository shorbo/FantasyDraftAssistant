import { useEffect, useMemo, useState } from 'react';
import { parseRankingsFile } from '../lib/csv.js';
import { fetchModelList, DEFAULT_MODEL } from '../lib/llm.js';
import { buildDraftConfig } from '../lib/draft.js';
import {
  getUser,
  getUserDrafts,
  getDraft,
  getLeagueUsers,
  currentSeason,
  parseDraftInput,
  loadPlayersDb,
  matchPlayersToSleeper,
} from '../lib/sleeper.js';

const STATUS_LABELS = {
  pre_draft: 'not started',
  drafting: 'LIVE',
  paused: 'paused',
  complete: 'complete',
};

export default function SetupScreen({
  savedSession,
  onResume,
  resuming,
  resumeError,
  onDiscardSaved,
  defaultApiKey,
  onStart,
}) {
  // rankings
  const [players, setPlayers] = useState(null);
  const [fileName, setFileName] = useState('');
  const [fileError, setFileError] = useState(null);

  // sleeper player db (background load, used for rankings ↔ sleeper matching)
  const [playersDb, setPlayersDb] = useState(null);

  // sleeper connection
  const [username, setUsername] = useState('');
  const [season, setSeason] = useState(currentSeason());
  const [user, setUser] = useState(null);
  const [drafts, setDrafts] = useState(null);
  const [findLoading, setFindLoading] = useState(false);
  const [draftInput, setDraftInput] = useState('');
  const [selectedDraft, setSelectedDraft] = useState(null);
  const [draftLoading, setDraftLoading] = useState(false);
  const [sleeperError, setSleeperError] = useState(null);
  const [manualSlot, setManualSlot] = useState(1);

  // AI
  const [apiKey, setApiKey] = useState(defaultApiKey || '');
  const [model, setModel] = useState(DEFAULT_MODEL);
  const [modelList, setModelList] = useState([]);

  const [starting, setStarting] = useState(false);
  const [startError, setStartError] = useState(null);

  useEffect(() => {
    fetchModelList()
      .then(setModelList)
      .catch(() => {}); // picker degrades to free text
    loadPlayersDb()
      .then(setPlayersDb)
      .catch(() => {}); // matching degrades to name-based resolution at pick time
  }, []);

  const matchedPlayers = useMemo(() => {
    if (!players) return null;
    if (!playersDb) return players;
    return matchPlayersToSleeper(players, playersDb);
  }, [players, playersDb]);

  const unmatched = useMemo(
    () => (matchedPlayers && playersDb ? matchedPlayers.filter((p) => !p.sleeperId) : []),
    [matchedPlayers, playersDb]
  );

  const draftOrderSlot = selectedDraft && user ? selectedDraft.draft_order?.[user.user_id] : null;
  const needsManualSlot = Boolean(selectedDraft && !draftOrderSlot);
  const unsupportedType = selectedDraft && selectedDraft.type === 'auction';

  async function handleFile(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    setFileError(null);
    setPlayers(null);
    try {
      const parsed = await parseRankingsFile(file);
      setPlayers(parsed);
      setFileName(file.name);
    } catch (err) {
      setFileError(err.message);
    }
  }

  async function resolveUser() {
    if (user && user.username?.toLowerCase() === username.trim().toLowerCase()) return user;
    const found = await getUser(username);
    if (!found) throw new Error(`No Sleeper user named “${username.trim()}”.`);
    setUser(found);
    return found;
  }

  async function handleFindDrafts() {
    setFindLoading(true);
    setSleeperError(null);
    setDrafts(null);
    try {
      const u = await resolveUser();
      const found = (await getUserDrafts(u.user_id, season)) || [];
      found.sort((a, b) => (b.start_time || b.created || 0) - (a.start_time || a.created || 0));
      setDrafts(found);
      if (found.length === 0) {
        setSleeperError(`No ${season} drafts found for ${u.display_name || u.username}.`);
      }
    } catch (err) {
      setSleeperError(String(err.message || err));
    } finally {
      setFindLoading(false);
    }
  }

  async function selectDraft(draftId) {
    setDraftLoading(true);
    setSleeperError(null);
    try {
      if (!username.trim()) {
        throw new Error('Enter your Sleeper username first so I know which team is yours.');
      }
      await resolveUser();
      const draft = await getDraft(draftId);
      if (!draft) throw new Error('Could not find that draft on Sleeper.');
      setSelectedDraft(draft);
    } catch (err) {
      setSleeperError(String(err.message || err));
    } finally {
      setDraftLoading(false);
    }
  }

  function handleLoadDraftInput() {
    const id = parseDraftInput(draftInput);
    if (!id) {
      setSleeperError('That doesn’t look like a Sleeper draft URL or id.');
      return;
    }
    selectDraft(id);
  }

  async function buildTeamNames(draft, teams, self) {
    const names = Array.from({ length: teams }, (_, i) => `Team ${i + 1}`);
    const order = draft.draft_order || {};
    const namesById = { [self.user_id]: self.display_name || self.username };
    if (draft.league_id) {
      try {
        for (const u of (await getLeagueUsers(draft.league_id)) || []) {
          namesById[u.user_id] = u.display_name || u.username;
        }
      } catch {
        // league names are a nicety, not a requirement
      }
    }
    for (const [uid, slot] of Object.entries(order)) {
      if (namesById[uid] && slot >= 1 && slot <= teams) names[slot - 1] = namesById[uid];
    }
    return names;
  }

  async function handleStart() {
    if (!matchedPlayers || !selectedDraft || !user || starting) return;
    setStarting(true);
    setStartError(null);
    try {
      const config = buildDraftConfig(selectedDraft, user.user_id);
      if (!config.userSlot) config.userSlot = manualSlot;
      const teamNames = await buildTeamNames(selectedDraft, config.teams, user);
      onStart({
        players: matchedPlayers,
        draft: selectedDraft,
        config,
        userId: user.user_id,
        apiKey: apiKey.trim(),
        model: model.trim() || DEFAULT_MODEL,
        teamNames,
      });
    } catch (err) {
      setStartError(String(err.message || err));
      setStarting(false);
    }
  }

  const selectedConfig = selectedDraft ? buildDraftConfig(selectedDraft, user?.user_id) : null;

  return (
    <div className="setup">
      <h1>🏈 Fantasy Football Assistant</h1>
      <div className="subtitle">Draft assistant · live-synced with your Sleeper draft</div>

      {savedSession && (
        <div className="resume-banner">
          <div>
            You were connected to <strong>{savedSession.draftName || 'a Sleeper draft'}</strong>.
            Rejoin it?
          </div>
          {resumeError && <div className="error">{resumeError}</div>}
          <div className="actions">
            <button className="primary" onClick={onResume} disabled={resuming}>
              {resuming ? 'Reconnecting…' : 'Rejoin draft'}
            </button>
            <button onClick={onDiscardSaved} disabled={resuming}>
              Start fresh
            </button>
          </div>
        </div>
      )}

      <div className="field">
        <label>Rankings CSV</label>
        <input type="file" accept=".csv,text/csv" onChange={handleFile} />
        <span className="hint">FantasyPros consensus export ("Draft ALL Rankings")</span>
        {players && (
          <span className="ok">
            ✓ Loaded {players.length} players from {fileName}
          </span>
        )}
        {players && playersDb && (
          <span className={unmatched.length > 0 ? 'hint' : 'ok'}>
            {unmatched.length === 0
              ? '✓ All ranked players matched to Sleeper'
              : `${players.length - unmatched.length}/${players.length} matched to Sleeper — unmatched: ${unmatched
                  .slice(0, 5)
                  .map((p) => p.name)
                  .join(', ')}${unmatched.length > 5 ? '…' : ''}`}
          </span>
        )}
        {fileError && <div className="error">{fileError}</div>}
      </div>

      <div className="field">
        <label>Your Sleeper username</label>
        <div className="connect-row">
          <input
            type="text"
            value={username}
            placeholder="username"
            onChange={(e) => {
              setUsername(e.target.value);
              setUser(null);
            }}
            onKeyDown={(e) => e.key === 'Enter' && username.trim() && handleFindDrafts()}
          />
          <select value={season} onChange={(e) => setSeason(e.target.value)}>
            {[currentSeason(), String(Number(currentSeason()) - 1)].map((y) => (
              <option key={y} value={y}>
                {y}
              </option>
            ))}
          </select>
          <button onClick={handleFindDrafts} disabled={!username.trim() || findLoading}>
            {findLoading ? 'Searching…' : 'Find drafts'}
          </button>
        </div>
        <span className="hint">Lists your Sleeper drafts (mocks included) for the season</span>
      </div>

      {drafts && drafts.length > 0 && (
        <div className="field">
          <label>Choose a draft</label>
          <div className="draft-list">
            {drafts.map((d) => (
              <button
                key={d.draft_id}
                className={`draft-option${selectedDraft?.draft_id === d.draft_id ? ' selected' : ''}`}
                onClick={() => selectDraft(d.draft_id)}
                disabled={draftLoading}
              >
                <span className="draft-name">{d.metadata?.name || 'Sleeper draft'}</span>
                <span className="draft-meta">
                  {d.settings?.teams}-team {d.type} · {STATUS_LABELS[d.status] || d.status}
                  {d.start_time ? ` · ${new Date(d.start_time).toLocaleDateString()}` : ''}
                </span>
              </button>
            ))}
          </div>
        </div>
      )}

      <div className="field">
        <label>…or paste a draft link</label>
        <div className="connect-row">
          <input
            type="text"
            value={draftInput}
            placeholder="https://sleeper.com/draft/nfl/…"
            onChange={(e) => setDraftInput(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && draftInput.trim() && handleLoadDraftInput()}
          />
          <button onClick={handleLoadDraftInput} disabled={!draftInput.trim() || draftLoading}>
            {draftLoading ? 'Loading…' : 'Load'}
          </button>
        </div>
      </div>

      {sleeperError && <div className="error">{sleeperError}</div>}

      {selectedDraft && selectedConfig && (
        <div className="draft-summary">
          <div className="draft-name">
            ✓ {selectedConfig.name} — {selectedConfig.teams}-team {selectedConfig.type},{' '}
            {selectedConfig.rounds} rounds ({STATUS_LABELS[selectedDraft.status] || selectedDraft.status})
          </div>
          {unsupportedType ? (
            <div className="error">Auction drafts aren’t supported yet — snake/linear only.</div>
          ) : needsManualSlot ? (
            <div className="connect-row">
              <span>You’re not in this draft’s order — which slot is yours?</span>
              <select value={manualSlot} onChange={(e) => setManualSlot(Number(e.target.value))}>
                {Array.from({ length: selectedConfig.teams }, (_, i) => (
                  <option key={i + 1} value={i + 1}>
                    Slot {i + 1}
                  </option>
                ))}
              </select>
            </div>
          ) : (
            <div className="hint">
              You’re drafting from slot {draftOrderSlot} as {user?.display_name || user?.username}
            </div>
          )}
        </div>
      )}

      <div className="field">
        <label>OpenRouter API key (for AI recommendations)</label>
        <input
          type="password"
          value={apiKey}
          placeholder="sk-or-..."
          onChange={(e) => setApiKey(e.target.value)}
        />
        <span className="hint">
          Optional — without it you still get instant local recommendations. Kept in memory only.
        </span>
      </div>

      <div className="field">
        <label>AI model</label>
        <input
          type="text"
          list="model-options"
          value={model}
          placeholder={DEFAULT_MODEL}
          onChange={(e) => setModel(e.target.value)}
        />
        <datalist id="model-options">
          {modelList.map((id) => (
            <option key={id} value={id} />
          ))}
        </datalist>
        <span className="hint">
          {modelList.length > 0
            ? `Type to search ${modelList.length} OpenRouter models`
            : 'Any OpenRouter model id (catalog unavailable — enter manually)'}
        </span>
      </div>

      {startError && <div className="error">{startError}</div>}

      <button
        className="primary"
        disabled={!players || !selectedDraft || !user || unsupportedType || starting}
        onClick={handleStart}
      >
        {starting ? 'Connecting…' : 'Connect to draft'}
      </button>
    </div>
  );
}
