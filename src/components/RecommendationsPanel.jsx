export default function RecommendationsPanel({ recs, aiState, model, hasApiKey, onRefresh, disabled }) {
  const modelName = (model || '').split('/').pop() || 'AI';
  return (
    <section className="panel">
      <h2>Recommendations</h2>
      <div className="rec-status">
        {aiState.status === 'ready' && <span className="badge-ai">✦ {modelName}</span>}
        {aiState.status === 'loading' && <span>✦ Asking {modelName}…</span>}
        {aiState.status === 'error' && (
          <span className="badge-error" title={aiState.error}>
            AI unavailable — showing local rankings
          </span>
        )}
        {aiState.status === 'idle' && (
          <span className="badge-local">
            {hasApiKey ? 'Local — AI kicks in near your pick' : 'Local rankings (no API key)'}
          </span>
        )}
        <div className="spacer" style={{ flex: 1 }} />
        <button onClick={onRefresh} disabled={!hasApiKey || aiState.status === 'loading' || disabled}>
          ⟳ Ask AI
        </button>
      </div>
      <div className="scroll">
        {recs.map(({ player, reason, tierBreak }, i) => (
          <div key={player.id} className="rec-card">
            <div className="rec-top">
              <span style={{ color: 'var(--text-dim)' }}>{i + 1}.</span>
              <span className={`pos-badge pos-${player.pos}`}>
                {player.pos}
                {player.posRank}
              </span>
              <span className="name">{player.name}</span>
              <span className="tier-chip">
                #{player.rank} · T{player.tier ?? '—'}
              </span>
              {tierBreak && <span className="tier-break">TIER CLIFF</span>}
            </div>
            <div className="reason">{reason}</div>
          </div>
        ))}
        {recs.length === 0 && (
          <div style={{ padding: 12, color: 'var(--text-dim)' }}>No available players left.</div>
        )}
      </div>
    </section>
  );
}
