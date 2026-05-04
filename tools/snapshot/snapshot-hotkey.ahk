; ─────────────────────────────────────────────────────────────────────
; Bangman's Abode — Snapshot Hotkey
; Press End (anywhere — even with Minecraft focused) to trigger
; the snapshot pipeline.
;
; Requires AutoHotkey v2.0+
; ─────────────────────────────────────────────────────────────────────

#Requires AutoHotkey v2.0
#SingleInstance Force

; Path to the snapshot script. EDIT THIS to match your machine.
SnapshotScript := "C:\Users\Westley\bangmans-abode\tools\snapshot\snapshot.ps1"

; Press End to trigger snapshot.
; Use $ prefix to prevent recursive triggering.
$End:: {
    global SnapshotScript

    ; Confirm with a brief tooltip so accidental presses don't trigger renders
    ToolTip("Snapshot starting…", 100, 100)
    SetTimer(() => ToolTip(), -2000)

    ; Launch PowerShell hidden, run the script, keep window open on error
    Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' SnapshotScript '"', , "Min")
}

; Optional: Ctrl+End to reload this AHK script while you're tweaking it
^End:: {
    Reload()
}
