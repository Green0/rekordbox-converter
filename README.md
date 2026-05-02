# rekordbox-converter

A PowerShell script that converts FLAC tracks in a Rekordbox XML database export to WAV, making playlists standalone-compatible with devices that don't support lossless formats.

## Requirements

- Windows (PowerShell 5.1+) or macOS ([PowerShell Core 7+](https://github.com/PowerShell/PowerShell))
- [ffmpeg](https://ffmpeg.org/download.html) available in PATH (macOS: `brew install ffmpeg`)
- A Rekordbox XML database export (`File > Export Collection in xml format`)

## Usage

```powershell
# Windows — first-time setup: allow local scripts to run
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Dry run — preview what would happen, nothing is touched
.\Convert-RekordboxFlac.ps1 -DryRun        # Windows
pwsh ./Convert-RekordboxFlac.ps1 -DryRun   # macOS

# Real run
.\Convert-RekordboxFlac.ps1        # Windows
pwsh ./Convert-RekordboxFlac.ps1   # macOS

# Windows only — real run as Administrator (required if Controlled Folder Access is enabled)
# Right-click PowerShell → Run as Administrator, then:
.\Convert-RekordboxFlac.ps1

# Force-reconvert files that already have a WAV alongside them
.\Convert-RekordboxFlac.ps1 -Force

# Show full ffmpeg output (useful for debugging failures)
.\Convert-RekordboxFlac.ps1 -Verbose
```

The script prompts for the XML path at startup, defaulting to `%APPDATA%\Pioneer\rekordbox\rekordbox.xml` on Windows and `~/Library/Application Support/Pioneer/rekordbox/rekordbox.xml` on macOS.

### Rekordbox setup

Before running the script for the first time, confirm Rekordbox is configured to use the correct XML file:

1. Open *Preferences > Advanced > Database* and verify that the **rekordbox xml** path points to `%APPDATA%\Pioneer\rekordbox\rekordbox.xml`.

After running the script:

2. In the Rekordbox browser pane, expand **rekordbox xml** and click the **sync** button to reload the updated database.
3. Drag the converted playlist from the **rekordbox xml** pane into your main collection to replace the original tracks.

## What it does

1. Backs up the XML file as `rekordbox_YYYY-MM-DD_HH-mm-ss.bak` before making any changes
2. Finds every `<TRACK>` entry whose `Location` ends in `.flac`
3. Converts each file to WAV in-place (same folder as the original) using ffmpeg, preserving metadata
4. Updates the `Location` and `Kind` attributes in the XML to point to the new WAV files
5. Writes a timestamped `convert-log_YYYY-MM-DD_HH-mm-ss.json` next to the XML with per-track results

## Output files

| File                 | Description                                                                       |
| -------------------- | --------------------------------------------------------------------------------- |
| `rekordbox-converter/rekordbox_*.bak`    | Timestamped backup of the XML created at the start of each run                    |
| `rekordbox-converter/convert-log_*.json` | Per-run conversion log with status, paths, and original XML values for each track |

## Notes

- WAV files are encoded as 16-bit PCM (`pcm_s16le`). Change to `pcm_s24le` in the script for 24-bit sources.
- The script is safe to re-run: already-converted files are skipped unless `-Force` is passed.
- If [Windows Controlled Folder Access](https://learn.microsoft.com/en-us/defender-endpoint/enable-controlled-folders) is enabled, run as Administrator — the script will temporarily whitelist ffmpeg and remove it from the whitelist once done.
