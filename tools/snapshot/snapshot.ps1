# ---------------------------------------------------------------------
# Bangman's Abode -- Snapshot Pipeline
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
# ---------------------------------------------------------------------

# --- CONFIG ---------------------------------------------------------
# Edit these paths to match your machine.

$RepoPath        = "C:\Users\Westley Yarlott\bangmans-abode"   # local clone of the repo
$BlueMapPath     = "C:\bluemap"                                # where BlueMap-cli.jar + config live
$BlueMapJar      = "BlueMap-5.20-cli.jar"                      # exact jar filename in $BlueMapPath
$DownloadsPath   = "$env:USERPROFILE\Downloads"                # where the browser drops world.zip
$WorldZipName    = "world.zip"                                 # what MineKeep names the download
$StagingPath     = "C:\bluemap\staging"                        # scratch folder for extracted world
$MineKeepFilesURL = "https://minekeep.net/servers/y2getphljglwarhh/files"

# Timeouts (seconds)
$RenderTimeout   = 1800  # 30 min wait for render to finish (first render only; later renders incremental)

# --- HELPERS --------------------------------------------------------

function Show-Toast {
    param([string]$Title, [string]$Message)
    # Burnt Toast not assumed installed -- use plain Windows balloon via Add-Type
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
    Write-Host "-- $Text --" -ForegroundColor Cyan
}

# --- PRE-FLIGHT CHECKS ----------------------------------------------

Section "Pre-flight checks"

if (-not (Test-Path $RepoPath))     { Fail "Repo path not found: $RepoPath" }
if (-not (Test-Path $BlueMapPath))  { Fail "BlueMap path not found: $BlueMapPath" }
if (-not (Test-Path "$BlueMapPath\$BlueMapJar")) { Fail "BlueMap jar not found: $BlueMapPath\$BlueMapJar" }
if (-not (Test-Path $DownloadsPath)) { Fail "Downloads folder not found: $DownloadsPath" }

# Verify java is on PATH
try { $null = & java -version 2>&1 } catch { Fail "java not on PATH. Reinstall Temurin or fix JAVA_HOME / PATH." }

Write-Host "All pre-flight checks passed." -ForegroundColor Green

# --- STEP 1: PROMPT USER TO DOWNLOAD WORLD -------------------------

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
Start-Process $MineKeepFilesURL

# Wait for user to confirm download is complete
Read-Host "Press Enter once world.zip has finished downloading"

# Verify the file actually exists and is stable
if (-not (Test-Path $oldZip)) { Fail "world.zip not found in Downloads. Make sure the file is named '$WorldZipName'." }

$size1 = (Get-Item $oldZip).Length
Start-Sleep -Seconds 2
$size2 = (Get-Item $oldZip).Length
if ($size1 -ne $size2 -or $size1 -eq 0) { Fail "world.zip doesn't look fully downloaded yet (file size still changing). Wait a moment and run again." }

$sizeMB = [math]::Round((Get-Item $oldZip).Length / 1MB, 1)
Write-Host "Got world.zip ($sizeMB MB)" -ForegroundColor Green

# --- STEP 2: EXTRACT TO STAGING -------------------------------------

Section "Step 2: Extract world.zip"

if (Test-Path $StagingPath) {
    Write-Host "Cleaning old staging folder..."
    Remove-Item -Recurse -Force $StagingPath
}
New-Item -ItemType Directory -Path $StagingPath | Out-Null

# Extract to a temp subfolder, then normalize the result to $StagingPath\world\
# regardless of whether the zip is flat (region/ at root) or nested (world/region/...).
# The map configs point to $StagingPath\world, so this keeps them stable.
$extractTmp = Join-Path $StagingPath "_extract"
New-Item -ItemType Directory -Path $extractTmp | Out-Null

Write-Host "Extracting..."
Expand-Archive -Path $oldZip -DestinationPath $extractTmp -Force

$WorldTarget = Join-Path $StagingPath "world"
if (Test-Path "$extractTmp\region") {
    # Flat -- rename _extract to world
    Rename-Item -Path $extractTmp -NewName "world"
} else {
    # Nested -- find the inner folder containing region/ and promote it to staging\world
    $inner = Get-ChildItem -Path $extractTmp -Directory | Where-Object { Test-Path "$($_.FullName)\region" } | Select-Object -First 1
    if (-not $inner) { Fail "Could not find a region/ folder in the extracted zip. Is this a valid Minecraft world?" }
    Move-Item -Path $inner.FullName -Destination $WorldTarget
    Remove-Item -Recurse -Force $extractTmp
}

if (-not (Test-Path "$WorldTarget\region")) { Fail "World normalization failed -- no region/ folder at $WorldTarget" }

Write-Host "Extracted to $WorldTarget" -ForegroundColor Green

# --- STEP 3: BLUEMAP RENDER -----------------------------------------

Section "Step 3: BlueMap render"

# BlueMap reads world path from its map config in $BlueMapPath\config\maps\*.conf
# We trust that's already configured to point at $StagingPath\world (see runbook).
# Just kick off the render.

Push-Location $BlueMapPath
try {
    Write-Host "Running BlueMap CLI (this can take a while on first render)..."

    # Use System.Diagnostics.Process directly. Start-Process -RedirectStandard*
    # in Windows PowerShell 5.1 produces a Process whose ExitCode is unreliable
    # (often $null even after WaitForExit), which causes false failure reports.
    $logPath = "$BlueMapPath\last-render.log"
    $errPath = "$BlueMapPath\last-render.err"
    if (Test-Path $logPath) { Remove-Item $logPath -Force }
    if (Test-Path $errPath) { Remove-Item $errPath -Force }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "java"
    $psi.Arguments = "-jar `"$BlueMapJar`" -r"
    $psi.WorkingDirectory = $BlueMapPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $stdoutSb = New-Object System.Text.StringBuilder
    $stderrSb = New-Object System.Text.StringBuilder
    $stdoutEvent = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action {
        if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
    } -MessageData $stdoutSb
    $stderrEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action {
        if ($EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
    } -MessageData $stderrSb

    [void]$proc.Start()
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    $exited = $proc.WaitForExit($RenderTimeout * 1000)
    if (-not $exited) {
        try { $proc.Kill() } catch {}
        Unregister-Event -SourceIdentifier $stdoutEvent.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $stderrEvent.Name -ErrorAction SilentlyContinue
        Set-Content -Path $logPath -Value $stdoutSb.ToString() -Encoding UTF8
        Set-Content -Path $errPath -Value $stderrSb.ToString() -Encoding UTF8
        Fail "BlueMap render timed out after ${RenderTimeout}s. Check $logPath"
    }

    # Block until async readers finish flushing.
    $proc.WaitForExit()
    Unregister-Event -SourceIdentifier $stdoutEvent.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $stderrEvent.Name -ErrorAction SilentlyContinue

    Set-Content -Path $logPath -Value $stdoutSb.ToString() -Encoding UTF8
    Set-Content -Path $errPath -Value $stderrSb.ToString() -Encoding UTF8

    $exitCode = $proc.ExitCode
    if ($exitCode -ne 0) {
        Fail "BlueMap exited with code $exitCode. Check $errPath"
    }
} finally {
    Pop-Location
}

Write-Host "Render complete." -ForegroundColor Green

# --- STEP 4: COPY RENDERED MAP INTO REPO ----------------------------

Section "Step 4: Copy rendered output to repo/map"

$BlueMapWebOutput = "$BlueMapPath\web"  # default BlueMap CLI output folder
if (-not (Test-Path $BlueMapWebOutput)) { Fail "BlueMap web output folder missing: $BlueMapWebOutput" }

$RepoMapPath = "$RepoPath\map"
if (Test-Path $RepoMapPath) { Remove-Item -Recurse -Force $RepoMapPath }
New-Item -ItemType Directory -Path $RepoMapPath | Out-Null

# Robocopy is faster + handles long paths
robocopy $BlueMapWebOutput $RepoMapPath /E /NFL /NDL /NP /NJH /NJS | Out-Null
if ($LASTEXITCODE -gt 7) { Fail "robocopy failed with exit code $LASTEXITCODE" }

# Decompress textures.json.gz -> textures.json for every map.
# BlueMap's webapp requests "textures.json" (without .gz) and relies on the
# host doing transparent gzip negotiation. BlueMap's bundled webserver does
# this; GitHub Pages does not. So we ship the decompressed JSON directly.
Get-ChildItem -Path "$RepoMapPath\maps" -Recurse -Filter "textures.json.gz" -ErrorAction SilentlyContinue | ForEach-Object {
    $gzPath = $_.FullName
    $jsonPath = $gzPath.Substring(0, $gzPath.Length - 3)  # strip ".gz"
    $inFs  = [System.IO.File]::OpenRead($gzPath)
    $gzStream = New-Object System.IO.Compression.GZipStream($inFs, [System.IO.Compression.CompressionMode]::Decompress)
    $outFs = [System.IO.File]::Create($jsonPath)
    $gzStream.CopyTo($outFs)
    $outFs.Close(); $gzStream.Close(); $inFs.Close()
    Remove-Item $gzPath -Force
}

# Write a metadata file with timestamp for the dashboard "Last updated" indicator
$meta = @{
    timestamp = (Get-Date -Format "o")
    timestamp_human = (Get-Date -Format "MMMM d, yyyy 'at' h:mm tt")
    world_size_mb = $sizeMB
} | ConvertTo-Json
Set-Content -Path "$RepoMapPath\snapshot.json" -Value $meta -Encoding UTF8

# Sanity-check repo size before pushing -- bail if map/ is over 500 MB
$mapSizeMB = [math]::Round((Get-ChildItem -Recurse $RepoMapPath | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
if ($mapSizeMB -gt 500) {
    Fail "map/ folder is $mapSizeMB MB (cap is 500). Trim render-mask in BlueMap config and try again."
}
Write-Host "Map output: $mapSizeMB MB" -ForegroundColor Green

# --- STEP 5: GIT COMMIT + PUSH --------------------------------------

Section "Step 5: git commit & push"

Push-Location $RepoPath
try {
    git add map/ 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "git add failed" }

    # Check if there's actually anything to commit
    $status = git status --porcelain map/
    if (-not $status) {
        Write-Host "No changes to commit (map identical to last snapshot)." -ForegroundColor Yellow
        Show-Toast -Title "Snapshot complete" -Message "Map already up to date -- no changes pushed."
        exit 0
    }

    $commitMsg = "Map snapshot -- $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    git commit -m $commitMsg 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "git commit failed" }

    git push 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "git push failed (auth issue? check credential manager)" }
} finally {
    Pop-Location
}

Write-Host "Pushed!" -ForegroundColor Green
Show-Toast -Title "Snapshot complete" -Message "Map updated and pushed to GitHub Pages ($mapSizeMB MB)"
