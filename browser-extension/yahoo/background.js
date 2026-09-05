// Content scripts only inspect the visible draft room. The service worker is
// the sole component allowed to make the localhost request.
chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "draft-pick") return;
  (async () => {
    const response = await fetch("http://127.0.0.1:8765/api/draft/pick", {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify(message.pick)
    });
    if (!response.ok) throw new Error(`Receiver returned ${response.status}.`);
    sendResponse({ ok: true });
  })().catch(error => {
    console.warn("Fantasy Draft Assistant: could not send Yahoo pick", error);
    sendResponse({ ok: false, error: error.message });
  });
  return true;
});

function isYahooDraft(url) {
  try {
    const parsed = new URL(url);
    return /(^|\.)fantasysports\.yahoo\.com$|(^|\.)sports\.yahoo\.com$/.test(parsed.hostname)
      && /draft/i.test(parsed.pathname + parsed.hash);
  } catch {
    return false;
  }
}

// Yahoo can turn a mock-lobby tab into the draft client without navigating to
// a new document. Reinforce the manifest-declared content script on either a
// normal page load or that URL transition.
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  const url = changeInfo.url || tab.url;
  if (!isYahooDraft(url) || (changeInfo.status !== "complete" && !changeInfo.url)) return;
  chrome.scripting.executeScript({
    target: { tabId },
    files: ["parser.js", "content.js"]
  }).catch(error => console.warn("Fantasy Draft Assistant: could not attach to Yahoo draft", error));
});
