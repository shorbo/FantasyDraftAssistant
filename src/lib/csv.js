import Papa from 'papaparse';

const REQUIRED_COLUMNS = ['RK', 'TIERS', 'PLAYER NAME', 'TEAM', 'POS', 'BYE'];
const VALID_POSITIONS = new Set(['QB', 'RB', 'WR', 'TE', 'K', 'DST']);

// Parses a FantasyPros rankings export. Headers may have trailing spaces,
// and POS embeds positional rank (e.g. "WR12"). Rejects files missing the
// expected columns with a message suitable for display.
export function parseRankingsFile(file) {
  return new Promise((resolve, reject) => {
    Papa.parse(file, {
      header: true,
      skipEmptyLines: true,
      transformHeader: (h) => h.trim(),
      complete: (results) => {
        try {
          resolve(toPlayers(results));
        } catch (err) {
          reject(err);
        }
      },
      error: () => reject(new Error('Could not read that file as CSV.')),
    });
  });
}

function toPlayers(results) {
  const fields = results.meta.fields || [];
  const missing = REQUIRED_COLUMNS.filter((c) => !fields.includes(c));
  if (missing.length > 0) {
    throw new Error(
      `This doesn't look like a FantasyPros rankings export — missing column(s): ${missing.join(', ')}.`
    );
  }

  const players = [];
  for (const row of results.data) {
    const rank = parseInt(row['RK'], 10);
    const name = (row['PLAYER NAME'] || '').trim();
    const posMatch = (row['POS'] || '').trim().match(/^([A-Z]+?)(\d+)$/);
    if (!Number.isFinite(rank) || !name || !posMatch || !VALID_POSITIONS.has(posMatch[1])) {
      continue; // skip malformed rows rather than failing the whole upload
    }
    players.push({
      id: rank,
      rank,
      tier: parseInt(row['TIERS'], 10) || null,
      name,
      team: (row['TEAM'] || '').trim(),
      pos: posMatch[1],
      posRank: parseInt(posMatch[2], 10),
      bye: parseInt(row['BYE'], 10) || null,
    });
  }

  if (players.length < 100) {
    throw new Error(
      `Only ${players.length} valid player rows found — expected a full rankings export. Check the file.`
    );
  }

  players.sort((a, b) => a.rank - b.rank);
  return players;
}
