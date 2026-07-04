import { useMemo, useState } from 'react';

const TABS = ['All', 'QB', 'RB', 'WR', 'TE', 'K', 'DST'];

export default function PlayerList({ players, draftedIds, onDraft, disabled }) {
  const [tab, setTab] = useState('All');
  const [query, setQuery] = useState('');
  const [hideDrafted, setHideDrafted] = useState(false);

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    return players.filter((p) => {
      if (tab !== 'All' && p.pos !== tab) return false;
      if (hideDrafted && draftedIds.has(p.id)) return false;
      if (q && !p.name.toLowerCase().includes(q)) return false;
      return true;
    });
  }, [players, tab, query, hideDrafted, draftedIds]);

  return (
    <section className="panel">
      <h2>Available Players</h2>
      <div className="player-controls">
        <div className="search-wrap">
          <input
            type="text"
            placeholder="Search players…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
          {query && (
            <button className="search-clear" onClick={() => setQuery('')} title="Clear search">
              ✕
            </button>
          )}
        </div>
        <div className="pos-tabs">
          {TABS.map((t) => (
            <button key={t} className={tab === t ? 'active' : ''} onClick={() => setTab(t)}>
              {t}
            </button>
          ))}
        </div>
        <label className="toggle-drafted">
          <input
            type="checkbox"
            checked={hideDrafted}
            onChange={(e) => setHideDrafted(e.target.checked)}
          />
          Hide drafted players
        </label>
      </div>
      <div className="scroll">
        {visible.map((p) => {
          const drafted = draftedIds.has(p.id);
          return (
            <div
              key={p.id}
              className={`player-row${drafted ? ' drafted' : ''}`}
              onClick={() => !drafted && !disabled && onDraft(p.id)}
              title={drafted || disabled ? undefined : 'Click to mark as drafted'}
            >
              <span className="rank">{p.rank}</span>
              <span className={`pos-badge pos-${p.pos}`}>
                {p.pos}
                {p.posRank}
              </span>
              <span className="name">{p.name}</span>
              <span className="meta">
                {p.team} · bye {p.bye ?? '—'}
              </span>
              <span className="tier-chip">T{p.tier ?? '—'}</span>
            </div>
          );
        })}
        {visible.length === 0 && (
          <div style={{ padding: 12, color: 'var(--text-dim)' }}>No players match.</div>
        )}
      </div>
    </section>
  );
}
