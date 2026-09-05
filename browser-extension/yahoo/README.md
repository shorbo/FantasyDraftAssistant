# Yahoo extension (developer install)

1. In Chrome or Edge, open `chrome://extensions` (or `edge://extensions`).
2. Enable **Developer mode**.
3. Click **Load unpacked** and choose this `browser-extension/yahoo` folder.
4. In Fantasy Draft Assistant, choose **Yahoo Fantasy**, enter your league settings, and connect.
5. Open your Yahoo draft room. The extension only reads completed, visible picks and POSTs them to the app on `127.0.0.1` automatically.

If picks do not arrive, open the extension’s service-worker console from `chrome://extensions` and keep the Yahoo draft room open. The initial selectors are intentionally conservative; capture the relevant draft-board DOM from a mock draft so they can be tailored to Yahoo’s current markup.
