# Bangman's Abode — Map Snapshot Pipeline

Press the **End** key on your Windows keyboard. A browser tab opens to your MineKeep Files page. Click the `world` folder, click download. Walk away. Five-ish minutes later, a notification tells you the map is updated and pushed to GitHub Pages.

That's the goal. This runbook gets you there from a fresh Windows machine in about 30 minutes.

---

## What this does

1. You press **End** anywhere on your Windows machine — even while Minecraft is focused
2. Your default browser opens MineKeep's Files page
3. You click the `world` folder → download (the script handles the rest)
4. Script extracts `world.zip` → runs BlueMap CLI → renders the map
5. Script copies the rendered output to your repo's `map/` subfolder
6. Script commits and pushes to GitHub
7. A toast notification confirms success

The map is **not live**. It updates only when you press End.

---

## One-time setup (do this once, never again)

### 1. Install Java 25

You started this earlier. Finish it: download the latest **Java 25 LTS** Temurin MSI from <https://adoptium.net/>, run the installer, and on the Custom Setup screen make sure these two are set to "Will be installed on local hard drive":

- **Modify PATH variable**
- **Set or override JAVA_HOME variable**

After install, open a fresh PowerShell window and run:

```
java -version
```

You should see `openjdk version "25"` or similar. If not, the installer skipped the PATH step — uninstall, reinstall, and pay closer attention to the Custom Setup screen.

### 2. Install Git for Windows

Grab it from <https://git-scm.com/download/win>. Run the installer. The defaults are fine — just keep clicking Next. The important defaults to leave on are "Use Git from the command line and also from 3rd-party software" and "Use the OpenSSL library".

After install, open a fresh PowerShell window:

```
git --version
```

You should see something like `git version 2.x.x.windows.1`.

### 3. Install AutoHotkey v2

Grab it from <https://www.autohotkey.com/>. Click the big "Download" button → choose **AutoHotkey v2** (not v1, they're different languages). Run the installer.

You don't need to test it yet — we'll do that in step 7.

### 4. Install BlueMap CLI

1. Go to <https://bluemap.bluecolored.de/wiki/getting-started/Installation.html>
2. Click the version link in the docs to get to the downloads page
3. Pick the **CLI** download — file will be named something like `BlueMap-5.18-cli.jar` (the version number will be whatever's current)
4. Create folder `C:\bluemap` and drop the jar inside

### 5. Generate BlueMap config files

Open PowerShell, then:

```
cd C:\bluemap
java -jar BlueMap-5.18-cli.jar
```

(Replace the jar filename with whatever yours is named.)

It'll create a `config/` folder with config files inside, then exit complaining about `accept-download`. That's expected.

### 6. Configure BlueMap

Open `C:\bluemap\config\core.conf` in Notepad. Find this line:

```
accept-download: false
```

Change it to:

```
accept-download: true
```

Save and close.

Now open `C:\bluemap\config\maps\overworld.conf` (and `nether.conf`, `end.conf` if you care about those — for friend-group snapshots, just overworld is fine; you can delete the other two `.conf` files entirely if you want).

In `overworld.conf`, find the `world:` line. Change it to:

```
world: "C:/bluemap/staging/world"
```

(Yes, forward slashes — BlueMap config is HOCON and is happier with forward slashes on Windows.)

Make sure `dimension:` is set to `"minecraft:overworld"`.

For a friend-group server, also consider trimming the render area to keep file size down. Find the `render-mask:` section and add a circle around spawn:

```
render-mask: [
  { type: "circle", center-x: 0, center-z: 0, radius: 500 }
]
```

That limits the render to a 500-block radius around (0,0). For your friends-only ~100×100 explored world, even 250 would be plenty.

### 7. Clone the repo on Windows

Pick where you want it. Suggestion: `C:\Users\YOURNAME\bangmans-abode`. Open PowerShell:

```
cd C:\Users\YOURNAME
git clone https://github.com/Westopoli/bangmans-abode.git
cd bangmans-abode
```

Set your git identity if you haven't already on this machine:

```
git config user.name "Westley"
git config user.email "your@email.here"
```

For pushing to GitHub, the easiest path is **Git Credential Manager**, which Git for Windows installs by default. The first time you `git push`, Windows will pop up a browser window asking you to log into GitHub. After that, it remembers.

To verify pushing works, make a tiny change and push:

```
echo "" >> README.md
git add README.md
git commit -m "Test push from Windows"
git push
```

If that succeeds, you're set. If it asks for a password and rejects it: GitHub no longer accepts passwords for HTTPS pushes — you need either Credential Manager (which uses OAuth, recommended) or a Personal Access Token. Credential Manager should "just work" on a fresh Git for Windows install.

### 8. Drop the snapshot scripts into the repo

Create folder `tools\snapshot\` inside your repo:

```
cd C:\Users\YOURNAME\bangmans-abode
mkdir tools\snapshot
```

Copy these three files into `tools\snapshot\`:

- `snapshot.ps1`
- `snapshot-hotkey.ahk`
- `README.md` (this file)

### 9. Edit the paths in `snapshot.ps1`

Open `snapshot.ps1` in Notepad or VS Code. At the top, edit the CONFIG block:

```powershell
$RepoPath        = "C:\Users\YOURNAME\bangmans-abode"
$BlueMapPath     = "C:\bluemap"
$BlueMapJar      = "BlueMap-5.18-cli.jar"   # match your downloaded version
```

The MineKeep Files URL is already filled in for your server.

### 10. Edit the path in `snapshot-hotkey.ahk`

Open `snapshot-hotkey.ahk`. Edit this line to match where you cloned the repo:

```
SnapshotScript := "C:\Users\YOURNAME\bangmans-abode\tools\snapshot\snapshot.ps1"
```

### 11. Test the pipeline manually first

**Don't bind the hotkey yet.** Run the script directly to make sure each stage works.

Open PowerShell as your normal user (not admin), then:

```
cd C:\Users\YOURNAME\bangmans-abode\tools\snapshot
powershell -ExecutionPolicy Bypass -File .\snapshot.ps1
```

Walk through it:

- It should pass pre-flight checks
- It should open your browser to MineKeep
- You manually click the `world` folder and download
- It should detect `world.zip`, extract, render, copy, commit, push
- A toast notification should appear at the end

If anything fails, the error message in red will tell you which step. Common issues:

- **Java not found:** PATH didn't take. Reinstall Temurin.
- **BlueMap exits non-zero:** check `C:\bluemap\last-render.err`. Most common: world path in `overworld.conf` is wrong.
- **Extracted folder has no region/:** MineKeep zipped a different structure. Check by manually opening the zip — adjust `snapshot.ps1` if the world folder isn't at the top level.
- **git push fails:** credential issue. Try a manual `git push` first to make sure auth is set up.

### 12. Bind the hotkey

Once the manual run works end-to-end, double-click `snapshot-hotkey.ahk`. AutoHotkey will start (you'll see a green "H" icon in your system tray) and the End key will now trigger snapshots.

To make this run automatically when Windows starts:

1. Right-click `snapshot-hotkey.ahk` → "Show more options" → "Send to" → "Desktop (create shortcut)"
2. Press `Win+R`, type `shell:startup`, hit Enter
3. Drag the desktop shortcut into the Startup folder that opens

Now End triggers a snapshot on every fresh boot.

---

## Day-to-day usage

You're playing Minecraft. Friend just finished an awesome build. You want a snapshot.

1. Press **End**
2. Browser tab opens to MineKeep
3. Click the `world` folder, click download
4. Switch back to Minecraft, keep playing
5. ~5–10 minutes later, a Windows notification: **"Snapshot complete — Map updated and pushed to GitHub Pages"**
6. GitHub Pages takes another 1-2 minutes to actually serve the new files

The first render is slow (could be 10-15 minutes). Subsequent renders are incremental — they only re-render chunks that changed since last time, so they're typically under a minute.

---

## Troubleshooting

**"Snapshot FAILED" toast appears immediately**
PowerShell threw before reaching the BlueMap stage. Run the script manually from a PowerShell window to see the error.

**Render finishes but `map/` folder is huge**
Trim the `render-mask` in `overworld.conf` to a smaller radius. For a friend-group server, 500 blocks around spawn is overkill — try 250.

**Toast says "Map already up to date — no changes pushed"**
Working as intended. Means the world hasn't changed since your last snapshot, so there's nothing to commit.

**Browser doesn't open when I press End**
AutoHotkey isn't running. Check the system tray for the green "H" icon. If missing, double-click `snapshot-hotkey.ahk` again.

**End key triggers but nothing happens after**
The PowerShell script is failing silently. Open `snapshot-hotkey.ahk` and change `, "Min"` at the end of the Run line to nothing — that'll show the PowerShell window so you can see the error.

**git push wants a password every time**
Credential Manager isn't caching. Run `git config --global credential.helper manager-core` and try again.

---

## What gets pushed to the repo

Each snapshot updates `map/` with the latest BlueMap render. That folder typically contains:

```
map/
├── settings.json
├── snapshot.json          ← timestamp metadata for dashboard
├── maps/
│   └── overworld/
│       ├── tiles/         ← the actual map data (lots of small files)
│       └── ...
├── assets/
└── index.html
```

The dashboard's `BLUEMAP_URL` will be set to `./map/` so GitHub Pages serves the static map directly.

`map/snapshot.json` contains a timestamp the dashboard reads to display "Last updated: 5 minutes ago".

---

## File size warning

The script bails if `map/` exceeds 500 MB. GitHub has a soft 1 GB repo limit and a hard 100 MB per-file limit. BlueMap tiles are small (~10-50 KB each), so the file limit isn't an issue, but a fully-rendered large world can blow up the repo. The render-mask is your friend.

---

## Where everything lives

```
C:\bluemap\                              ← BlueMap CLI installation
├── BlueMap-5.18-cli.jar
├── config\
│   ├── core.conf
│   └── maps\
│       └── overworld.conf
├── staging\                              ← extracted world goes here (auto-managed)
└── web\                                  ← rendered output (auto-managed)

C:\Users\YOURNAME\bangmans-abode\         ← repo clone
├── index.html
├── map\                                  ← pushed to GitHub Pages
└── tools\snapshot\
    ├── snapshot.ps1                      ← the pipeline
    ├── snapshot-hotkey.ahk               ← End key binder
    └── README.md                         ← this file
```
