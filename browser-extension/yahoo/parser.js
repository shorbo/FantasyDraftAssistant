/* global window */
// Yahoo does not publish a stable DOM contract. This parser deliberately
// prefers semantic data attributes and then a conservative set of common
// draft-board selectors. Inspect a live/mock room before widening selectors.
window.FantasyDraftYahooParser = (() => {
  const text = (node) => node?.textContent?.replace(/\s+/g, " ").trim() || "";
  const attribute = (node, names) => {
    for (const name of names) {
      const value = node?.getAttribute?.(name);
      if (value?.trim()) return value.trim();
    }
    return null;
  };
  const findText = (node, selectors) => {
    for (const selector of selectors) {
      const value = text(node.querySelector(selector));
      if (value) return value;
    }
    return null;
  };
  const number = (value) => {
    const match = String(value || "").match(/(?:overall\s*)?(?:pick\s*#?\s*)?(\d+)/i);
    return match ? Number(match[1]) : null;
  };
  const position = (value) => {
    const match = String(value || "").match(/\b(QB|RB|WR|TE|K|DST|DEF)\b/i);
    if (!match) return null;
    return match[1].toUpperCase() === "DEF" ? "DST" : match[1].toUpperCase();
  };
  const team = (value) => {
    const match = String(value || "").match(/\b([A-Z]{2,3})\b/);
    return match ? match[1] : null;
  };

  function parse(node) {
    const raw = text(node);
    const pick = Number(attribute(node, ["data-pick-number", "data-pick", "data-overall-pick"])) || number(raw);
    const playerName = attribute(node, ["data-player-name", "data-player"])
      || findText(node, ["[data-player-name]", ".player-name", ".playerName", ".name"]);
    if (!pick || !playerName || playerName.length < 3) return null;

    const details = attribute(node, ["data-position", "data-player-position"]) || raw;
    const nflTeam = attribute(node, ["data-nfl-team", "data-team"]) || team(findText(node, [".nfl-team", ".team"]));
    const draftSlot = Number(attribute(node, ["data-draft-slot", "data-slot", "data-team-slot"])) || null;
    const round = Number(attribute(node, ["data-round"])) || null;
    const fantasyTeam = attribute(node, ["data-fantasy-team", "data-team-name"])
      || findText(node, [".fantasy-team", ".team-name", ".manager-name"]);
    return {
      source: "yahoo",
      pick,
      round,
      draft_slot: draftSlot,
      fantasy_team: fantasyTeam,
      player_name: playerName,
      position: position(details),
      nfl_team: nflTeam
    };
  }

  // Current Yahoo draft rooms expose the completed pick in the sidebar as:
  // Last: / O. Hampton / (RB · LAC) / Rocco. Unlike generated CSS module
  // names, the `Last:` label is a stable semantic anchor.
  function parseLastPick(root = document) {
    const label = [...root.querySelectorAll("span")].find(node => text(node) === "Last:");
    if (!label) return null;
    const playerLine = label.parentElement;
    const card = playerLine?.parentElement;
    const fields = [...(playerLine?.querySelectorAll("span") || [])].map(text);
    const playerName = fields[1];
    const details = fields[2] || "";
    const owner = text(card?.lastElementChild);
    const detailMatch = details.match(/^\((QB|RB|WR|TE|K|DST|DEF)\s*[·•]\s*([^\s)]+)/i);
    if (!playerName || !detailMatch) return null;

    const clockText = [...document.querySelectorAll("span")]
      .map(text)
      .find(value => /Round\s+\d+,\s+Pick\s+\d+/i.test(value)) || "";
    const currentPick = Number(clockText.match(/Pick\s+(\d+)/i)?.[1]);
    const pick = currentPick - 1;
    if (!Number.isInteger(pick) || pick < 1) return null;

    const slot = [...document.querySelectorAll(".ys-team[data-id]")]
      .find(team => text(team) === owner)?.getAttribute("data-id");
    const uniqueSlots = new Set([...document.querySelectorAll(".ys-team[data-id]")]
      .map(team => Number(team.getAttribute("data-id")))
      .filter(Number.isFinite));
    const teams = uniqueSlots.size;
    const rawPosition = detailMatch[1].toUpperCase();
    return {
      source: "yahoo",
      pick,
      round: teams ? Math.ceil(pick / teams) : null,
      draft_slot: slot ? Number(slot) : null,
      fantasy_team: owner || null,
      player_name: playerName,
      position: rawPosition === "DEF" ? "DST" : rawPosition,
      nfl_team: detailMatch[2].toUpperCase()
    };
  }

  function candidates(root = document) {
    const lastPick = parseLastPick(root.ownerDocument || root);
    if (lastPick) {
      // Attach the already-normalized payload to a harmless local element so
      // content.js can use the same de-duplication and send path for all
      // parser strategies.
      return [{ __fantasyDraftPick: lastPick }];
    }
    const selector = "[data-pick-number], [data-overall-pick], [data-testid*='pick'], .draft-pick, .DraftPick";
    const nodes = [...root.querySelectorAll(selector)];
    if (root.matches?.(selector)) nodes.unshift(root);
    return nodes;
  }
  function parseCandidate(node) { return node.__fantasyDraftPick || parse(node); }
  return { parse: parseCandidate, candidates };
})();
