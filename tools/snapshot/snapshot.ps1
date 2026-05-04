# ─────────────────────────────────────────────────────────────────────
# Bangman's Abode — Snapshot Pipeline
# Triggered by AutoHotkey hotkey (End by default).
# Workflow:
#   1. Open MineKeep Files page in default browser, copy world download URL
#      to clipboard so user can grab world.zip
#   2. Watch Downloads folder for world.zip
#   3. Extract to staging folder
#   4. Run BlueMap CLI render
#   5. Copy rendered output to repo's map/ subfolder
#   6. git add / commit / push
#   7. Toast notification on completion
# ─────────────────────────────────────────────────────────────────────

# ─── CONFIG ─────────────────────────────────────────────────────────
# Edit these paths to match your machine.

$RepoPath        = "C:\Users\Westley\bangmans-abode"          # local clone of the repo
$BlueMapPath     = "C:\bluemap"                                # where BlueMap-cli.jar + config live
$BlueMapJar      = "BlueMap-5.18-cli.jar"                      # exact jar filename in $BlueMapPath
$DownloadsPath   = "$env:USERPROFILE\Downloads"                # where the browser drops world.zip
$WorldZipName    = "world.zip"                                 # what MineKeep names the download
$StagingPath     = "C:\bluemap\staging"                        # scratch folder for extracted world
$MineKeepFilesURL = "https://minekeep.net/servers/y2getphljglwarhh/files"

# Timeouts (seconds)
$DownloadTimeout = 300   # 5 min wait for the download to appear
$RenderTimeout   = 1800  # 30 min wait for render to finish (first render only; later renders incremental)

# ─── HELPERS ────────────────────────────────────────────────────────

function Show-Toast {
    param([string]$Title, [string]$Message)
    # Burnt Toast not assumed installed — use plain Windows balloon via Add-Type
    Add-Type -AssemblyName System.Windows.Forms
    $balloon = New-Object System.Windows.Forms.NotifyIcon
    $balloon.Icon = [System.Drawing.SystemIcons]::Information
    $balloon.BalloonTipTitle = $Title
    $balloon.BalloonTipText = $Message
    $balloon.Visible = $true
    $balloon.ShowBalloonTip(5000)
    Start-Sleep -Seconds 6
    $balloon.Dispose()
}

function Fail {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    Show-Toast -Title "Snapshot FAILED" -Message $Message
    exit 1
}

function Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "── $Text ──" -ForegroundColor Cyan
}

# ─── PRE-FLIGHT CHECKS ──────────────────────────────────────────────

Section "Pre-flight checks"

if (-not (Test-Path $RepoPath))     { Fail "Repo path not found: $RepoPath" }
if (-not (Test-Path $BlueMapPath))  { Fail "BlueMap path not found: $BlueMapPath" }
if (-not (Test-Path "$BlueMapPath\$BlueMapJar")) { Fail "BlueMap jar not found: $BlueMapPath\$BlueMapJar" }
if (-not (Test-Path $DownloadsPath)) { Fail "Downloads folder not found: $DownloadsPath" }

# Verify java is on PATH
try { $null = & java -version 2>&1 } catch { Fail "java not on PATH. Reinstall Temurin or fix JAVA_HOME / PATH." }

Write-Host "All pre-flight checks passed." -ForegroundColor Green

# ─── STEP 1: PROMPT USER TO DOWNLOAD WORLD ─────────────────────────

Section "Step 1: Download world.zip from MineKeep"

# Clean up any old world.zip in Downloads to avoid stale-file confusion
$oldZip = Join-Path $DownloadsPath $WorldZipName
if (Test-Path $oldZip) {
    Write-Host "Removing stale $WorldZipName from Downloads..."
    Remove-Item $oldZip -Force
}

# Open MineKeep Files page in default browser
Write-Host "Opening MineKeep Files page in your browser."
Write-Host "Click the 'world' folder, then click the download button."
Write-Host "(Waiting up to $DownloadTimeout seconds for $WorldZipName to appear in Downloads...)"
Start-Process $MineKeepFilesURL

# Watch for world.zip
$elapsed = 0
$found = $false
while ($elapsed -lt $DownloadTimeout) {
    if (Test-Path $oldZip) {
        # Wait an extra 3 seconds to make sure download is really finished (file size stable)
        $size1 = (Get-Item $oldZip).Length
        Start-Sleep -Seconds 3
        $size2 = (Get-Item $oldZip).Length
        if ($size1 -eq $size2 -and $size1 -gt 0) {
            $found = $true
            break
        }
    }
    Start-Sleep -Seconds 2
    $elapsed += 2
}

if (-not $found) { Fail "world.zip never appeared in Downloads within ${DownloadTimeout}s." }

$sizeMB = [math]::Round((Get-Item $oldZip).Length / 1MB, 1)
Write-Host "Got world.zip ($sizeMB MB)" -ForegroundColor Green

# ─── STEP 2: EXTRACT TO STAGING ─────────────────────────────────────

Section "Step 2: Extract world.zip"

if (Test-Path $StagingPath) {
    Write-Host "Cleaning old staging folder..."
    Remove-Item -Recurse -Force $StagingPath
}
New-Item -ItemType Directory -Path $StagingPath | Out-Null

Write-Host "Extracting..."
Expand-Archive -Path $oldZip -DestinationPath $StagingPath -Force

# MineKeep zips usually contain a top-level 'world' folder.
# Verify it has a region/ subfolder which is the actual world data.
$worldDir = Get-ChildItem -Path $StagingPath -Directory | Select-Object -First 1
if (-not $worldDir) { Fail "Extracted zip is empty?" }
if (-not (Test-Path "$($worldDir.FullName)\region")) {
    Fail "Extracted folder doesn't look like a Minecraft world (no region/ subfolder). Got: $($worldDir.FullName)"
}

Write-Host "Extracted to $($worldDir.FullName)" -ForegroundColor Green

# ─── STEP 3: BLUEMAP RENDER ─────────────────────────────────────────

Section "Step 3: BlueMap render"

# BlueMap reads world path from its map config in $BlueMapPath\config\maps\*.conf
# We trust that's already configured to point at $StagingPath\world (see runbook).
# Just kick off the render.

Push-Location $BlueMapPath
try {
    Write-Host "Running BlueMap CLI (this can take a while on first render)..."
    $proc = Start-Process -FilePath "java" `
        -ArgumentList "-jar", $BlueMapJar, "-r" `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput "$BlueMapPath\last-render.log" `
        -RedirectStandardError  "$BlueMapPath\last-render.err"
    if (-not $proc.WaitForExit($RenderTimeout * 1000)) {
        $proc.Kill()
        Fail "BlueMap render timed out after ${RenderTimeout}s. Check $BlueMapPath\last-render.log"
    }
    if ($proc.ExitCode -ne 0) {
        Fail "BlueMap exited with code $($proc.ExitCode). Check $BlueMapPath\last-render.err"
    }
} finally {
    Pop-Location
}

Write-Host "Render complete." -ForegroundColor Green

# ─── STEP 4: COPY RENDERED MAP INTO REPO ────────────────────────────

Section "Step 4: Copy rendered output to repo/map"

$BlueMapWebOutput = "$BlueMapPath\web"  # default BlueMap CLI output folder
if (-not (Test-Path $BlueMapWebOutput)) { Fail "BlueMap web output folder missing: $BlueMapWebOutput" }

$RepoMapPath = "$RepoPath\map"
if (Test-Path $RepoMapPath) { Remove-Item -Recurse -Force $RepoMapPath }
New-Item -ItemType Directory -Path $RepoMapPath | Out-Null

# Robocopy is faster + handles long paths
robocopy $BlueMapWebOutput $RepoMapPath /E /NFL /NDL /NP /NJH /NJS | Out-Null
if ($LASTEXITCODE -gt 7) { Fail "robocopy failed with exit code $LASTEXITCODE" }

# Write a metadata file with timestamp for the dashboard "Last updated" indicator
$meta = @{
    timestamp = (Get-Date -Format "o")
    timestamp_human = (Get-Date -Format "MMMM d, yyyy 'at' h:mm tt")
    world_size_mb = $sizeMB
} | ConvertTo-Json
Set-Content -Path "$RepoMapPath\snapshot.json" -Value $meta -Encoding UTF8

# Sanity-check repo size before pushing — bail if map/ is over 500 MB
$mapSizeMB = [math]::Round((Get-ChildItem -Recurse $RepoMapPath | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
if ($mapSizeMB -gt 500) {
    Fail "map/ folder is $mapSizeMB MB (cap is 500). Trim render-mask in BlueMap config and try again."
}
Write-Host "Map output: $mapSizeMB MB" -ForegroundColor Green

# ─── STEP 5: GIT COMMIT + PUSH ──────────────────────────────────────

Section "Step 5: git commit & push"

Push-Location $RepoPath
try {
    git add map/ 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "git add failed" }

    # Check if there's actually anything to commit
    $status = git status --porcelain map/
    if (-not $status) {
        Write-Host "No changes to commit (map identical to last snapshot)." -ForegroundColor Yellow
        Show-Toast -Title "Snapshot complete" -Message "Map already up to date — no changes pushed."
        exit 0
    }

    $commitMsg = "Map snapshot — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    git commit -m $commitMsg 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "git commit failed" }

    git push 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "git push failed (auth issue? check credential manager)" }
} finally {
    Pop-Location
}

Write-Host "Pushed!" -ForegroundColor Green
Show-Toast -Title "Snapshot complete" -Message "Map updated and pushed to GitHub Pages ($mapSizeMB MB)"
