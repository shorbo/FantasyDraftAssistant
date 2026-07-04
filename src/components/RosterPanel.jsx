export default function RosterPanel({ starters, bench, gaps, byes, complete }) {
  return (
    <section className="panel">
      <h2>My Roster</h2>
      {complete && <div className="complete-banner">Final roster</div>}
      {(gaps.length > 0 || byes.length > 0) && (
        <div className="warnings">
          {gaps.map((g) => (
            <div key={g} className="warning">
              ⚠️ {g}
            </div>
          ))}
          {byes.map((b) => (
            <div key={b} className="warning">
              📅 {b}
            </div>
          ))}
        </div>
      )}
      <div className="scroll">
        {starters.map((slot) => (
          <div key={slot.key} className={`roster-slot${slot.player ? ' filled' : ''}`}>
            <span className="slot-label">{slot.key}</span>
            {slot.player ? <PlayerLine p={slot.player} /> : <span className="empty">empty</span>}
          </div>
        ))}
        <div className="bench-header">Bench ({bench.length}/6)</div>
        {bench.map((p) => (
          <div key={p.id} className="roster-slot filled">
            <span className="slot-label">BN</span>
            <PlayerLine p={p} />
          </div>
        ))}
      </div>
    </section>
  );
}

function PlayerLine({ p }) {
  return (
    <>
      <span className={`pos-badge pos-${p.pos}`}>
        {p.pos}
        {p.posRank}
      </span>
      <span className="name">{p.name}</span>
      <span className="meta" style={{ color: 'var(--text-dim)', fontSize: 12 }}>
        {p.team} · bye {p.bye ?? '—'}
      </span>
    </>
  );
}
