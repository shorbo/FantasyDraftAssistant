import { roundForPick } from '../lib/draft.js';

export default function DraftHeader({
  currentPick,
  config,
  teamNames,
  nextUserPickNum,
  recentPicks,
  complete,
  draftStatus,
  syncError,
  lastSync,
  onLeave,
}) {
  function teamName(slot) {
    return teamNames?.[slot - 1] || `Team ${slot}`;
  }
  const clamped = Math.min(currentPick, config.totalPicks);
  const round = roundForPick(clamped, config.teams);
  const pickInRound = ((clamped - 1) % config.teams) + 1;

  return (
    <header className="draft-header">
      {complete ? (
        <span className="pick-status">🏁 Draft complete</span>
      ) : draftStatus === 'pre_draft' ? (
        <span className="pick-status">⏳ Waiting for the draft to start…</span>
      ) : (
        <>
          <span className="pick-status">
            {draftStatus === 'paused' && '⏸ '}
            Round {round} · Pick {pickInRound} (overall #{currentPick})
          </span>
          {recentPicks.onClockSlot === config.userSlot ? (
            <span className="on-clock you">🟢 You're on the clock!</span>
          ) : (
            <span className="on-clock">
              {teamName(recentPicks.onClockSlot)} on the clock
              {nextUserPickNum
                ? ` — you pick in ${nextUserPickNum - currentPick}`
                : ' — no picks left for you'}
            </span>
          )}
        </>
      )}

      <div className="spacer" />

      {recentPicks.items.length > 0 && (
        <div className="recent-picks">
          <span>Last:</span>
          {recentPicks.items.map(({ pickNumber, player, isMine }) => (
            <span key={pickNumber} className={`recent-pick${isMine ? ' mine' : ''}`}>
              #{pickNumber} {player.name}
            </span>
          ))}
        </div>
      )}

      {syncError ? (
        <span className="sync-badge error" title={syncError}>
          ⚠ sync error — retrying
        </span>
      ) : (
        <span className={`sync-badge${complete ? '' : ' live'}`} title={config.name}>
          {complete ? '✓ Sleeper' : '● Sleeper'}
          {!complete && lastSync ? ' live' : ''}
        </span>
      )}

      <button onClick={onLeave} title="Back to setup — you can rejoin anytime">
        ✕ Leave
      </button>
    </header>
  );
}
