# Bangman's Abode

Single-page server dashboard for the **Bangman's Abode** Minecraft server. Live status, copy-paste connection guides for every platform, BlueMap world view, and a Canvas-based text reflow playground.

Built as a single static `index.html` — no build step, no bundler, just open it.

## Features

- **Live status** — polls [mcsrvstat.us](https://mcsrvstat.us) for online state, player count, version, and MOTD
- **One-click address copy** — Java and Bedrock addresses, big and obvious
- **Cross-platform connect guides** — PC, Xbox, PlayStation, Switch (including the BedrockConnect DNS workaround for consoles)
- **BlueMap embed** — drop in your URL once the plugin is running
- **Reflow playground** — Pretext-inspired Canvas text measurement, drag blocks and watch text wrap around them

## Tech

- React 18 (CDN, no build)
- Babel standalone for in-browser JSX
- Chakra Petch + JetBrains Mono (Google Fonts)
- Canvas `measureText` for DOM-free text layout
- mcsrvstat.us for status

## Deploy to GitHub Pages

```bash
git init
git add .
git commit -m "Initial deploy"
git branch -M main
git remote add origin git@github.com:YOUR_USERNAME/bangmans-abode.git
git push -u origin main
```

Then in your repo: **Settings → Pages → Source → `main` branch, `/ (root)`**. Site goes live at `https://YOUR_USERNAME.github.io/bangmans-abode/`.

## Configuration

All config lives at the top of `index.html`:

```js
const SERVER_BEDROCK = "bangmansabode.bedrock.minekeep.gg";
const SERVER_JAVA = "bangmansabode.minekeep.gg";
const BLUEMAP_URL = ""; // paste once BlueMap is running
const REFRESH_MS = 60000;
```

## BlueMap setup

1. Grab the Paper jar from [bluemap.bluecolored.de](https://bluemap.bluecolored.de)
2. Drop it in `plugins/` on the MineKeep server
3. Restart, edit `plugins/BlueMap/core.conf` → `accept-download: true`
4. Restart again — map renders at `your-ip:8100`
5. Paste the URL into `BLUEMAP_URL` in `index.html`, commit, push

## Local development

It's just a static file. Open it directly, or:

```bash
python3 -m http.server 8000
# → http://localhost:8000
```

## Structure

```
bangmans-abode/
├── index.html    # entire app
├── README.md
└── LICENSE
```

---

Built by [Westopoli](https://westopoli.com) · MIT
