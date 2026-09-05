/* global FantasyDraftYahooParser, chrome */
(() => {
  if (window.__fantasyDraftYahooContentLoaded) return;
  window.__fantasyDraftYahooContentLoaded = true;

  // Yahoo can transition from its mock lobby into the draft client without a
  // full page load. Stay attached on Yahoo pages and let the observer wait for
  // a completed-pick card rather than exiting before the board is rendered.
  const seenPicks = new Set();
  function inspect(root) {
    for (const node of FantasyDraftYahooParser.candidates(root)) {
      const pick = FantasyDraftYahooParser.parse(node);
      if (!pick || seenPicks.has(pick.pick)) continue;
      seenPicks.add(pick.pick);
      chrome.runtime.sendMessage({ type: "draft-pick", pick }, response => {
        if (chrome.runtime.lastError || !response?.ok) {
          console.warn("Fantasy Draft Assistant: Yahoo pick was not delivered", chrome.runtime.lastError?.message || response?.error);
        }
      });
    }
  }

  inspect(document);
  const observer = new MutationObserver(records => {
    for (const record of records) {
      for (const node of record.addedNodes) {
        if (node.nodeType === Node.ELEMENT_NODE) inspect(node);
      }
    }
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
})();
