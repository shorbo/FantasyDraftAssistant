import { TOTAL_PICKS, TEAMS, roundForPick } from '../lib/draft.js';

export default function DraftHeader({
  currentPick,
  userSlot,
  teamNames,
  nextUserPickNum,
  recentPicks,
  onUndo,
  onTogglePickOwner,
  complete,
}) {
  function teamName(slot) {
    return teamNames?.[slot - 1] || `Team ${slot}`;
  }
  const round = roundForPick(Math.min(currentPick, TOTAL_PICKS));
  const pickInRound = ((Math.min(currentPick, TOTAL_PICKS) - 1) % TEAMS) + 1;

  return (
    <header className="draft-header">
      {complete ? (
        <span className="pick-status">🏁 Draft complete</span>
      ) : (
        <>
          <span className="pick-status">
            Round {round} · Pick {pickInRound} (overall #{currentPick})
          </span>
          {recentPicks.onClockSlot === userSlot ? (
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
          {recentPicks.items.map(({ pick, player, isMine }) => (
            <span key={pick.pickNumber} className={`recent-pick${isMine ? ' mine' : ''}`}>
              #{pick.pickNumber} {player.name}
              <button
                title={isMine ? 'Reassign to another team' : 'Reassign to my roster'}
                onClick={() => onTogglePickOwner(pick.pickNumber)}
              >
                {isMine ? 'mine ✕' : '→ mine'}
              </button>
            </span>
          ))}
        </div>
      )}

      <button onClick={onUndo} disabled={recentPicks.items.length === 0}>
        ↩ Undo pick
      </button>
    </header>
  );
}
