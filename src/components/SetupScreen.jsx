import { useEffect, useState } from 'react';
import { parseRankingsFile } from '../lib/csv.js';
import { fetchModelList, DEFAULT_MODEL } from '../lib/llm.js';
import { TEAMS } from '../lib/draft.js';

export default function SetupScreen({ savedDraft, onResume, onDiscardSaved, defaultApiKey, onStart }) {
  const [players, setPlayers] = useState(null);
  const [fileName, setFileName] = useState('');
  const [userSlot, setUserSlot] = useState(1);
  const [teamNames, setTeamNames] = useState(() =>
    Array.from({ length: TEAMS }, (_, i) => `Team ${i + 1}`)
  );
  const [apiKey, setApiKey] = useState(defaultApiKey || '');
  const [model, setModel] = useState(DEFAULT_MODEL);
  const [modelList, setModelList] = useState([]);
  const [error, setError] = useState(null);

  function setTeamName(index, value) {
    setTeamNames((prev) => prev.map((n, i) => (i === index ? value : n)));
  }

  useEffect(() => {
    fetchModelList()
      .then(setModelList)
      .catch(() => {}); // picker degrades to free text
  }, []);

  async function handleFile(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    setError(null);
    setPlayers(null);
    try {
      const parsed = await parseRankingsFile(file);
      setPlayers(parsed);
      setFileName(file.name);
    } catch (err) {
      setError(err.message);
    }
  }

  return (
    <div className="setup">
      <h1>🏈 Fantasy Draft Assistant</h1>

      {savedDraft && (
        <div className="resume-banner">
          <div>
            A draft in progress was found (pick {savedDraft.picks.length + 1}, slot{' '}
            {savedDraft.userSlot}). Resume it?
          </div>
          <div className="actions">
            <button className="primary" onClick={onResume}>
              Resume draft
            </button>
            <button onClick={onDiscardSaved}>Start fresh</button>
          </div>
        </div>
      )}

      <div className="field">
        <label>Rankings CSV</label>
        <input type="file" accept=".csv,text/csv" onChange={handleFile} />
        <span className="hint">FantasyPros PPR consensus export ("Draft ALL Rankings")</span>
        {players && (
          <span className="ok">
            ✓ Loaded {players.length} players from {fileName}
          </span>
        )}
      </div>

      {error && <div className="error">{error}</div>}

      <div className="field">
        <label>Your draft slot</label>
        <select value={userSlot} onChange={(e) => setUserSlot(Number(e.target.value))}>
          {Array.from({ length: TEAMS }, (_, i) => (
            <option key={i + 1} value={i + 1}>
              Pick {i + 1} of {TEAMS}
            </option>
          ))}
        </select>
        <span className="hint">Snake draft: odd rounds 1→10, even rounds 10→1</span>
      </div>

      <div className="field">
        <label>Team names (optional)</label>
        <div className="team-names-grid">
          {teamNames.map((name, i) => (
            <div key={i} className="team-name-entry">
              <span className="team-name-slot">#{i + 1}</span>
              <input
                type="text"
                value={name}
                placeholder={`Team ${i + 1}`}
                onChange={(e) => setTeamName(i, e.target.value)}
              />
            </div>
          ))}
        </div>
        <span className="hint">Name each team so picks are easier to track</span>
      </div>

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

      <button
        className="primary"
        disabled={!players}
        onClick={() =>
          onStart({ players, userSlot, apiKey: apiKey.trim(), model: model.trim() || DEFAULT_MODEL, teamNames })
        }
      >
        Start draft
      </button>
    </div>
  );
}
