# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single PowerShell script (`Convert-RekordboxFlac.ps1`) that batch-converts FLAC tracks referenced in a Rekordbox XML database export to WAV, then rewrites the XML in place so Rekordbox points to the WAV files.

## Running the script

```powershell
.\Convert-RekordboxFlac.ps1 -DryRun          # preview only
.\Convert-RekordboxFlac.ps1                   # real run
.\Convert-RekordboxFlac.ps1 -Force            # reconvert even if WAV already exists
.\Convert-RekordboxFlac.ps1 -Verbose          # show full ffmpeg output
```

Must be run as Administrator when Windows Controlled Folder Access is enabled (common when music files live under `D:\Users\...\Music`).

## Architecture

The script runs as a single linear pipeline:

1. **Input validation** — prompts for XML path, checks ffmpeg is in PATH (`$ffmpegPath` via `Get-Command`)
2. **CFA handling** — detects Windows Controlled Folder Access via `Get-MpPreference`; if active and running as admin, temporarily whitelists ffmpeg (`Add-MpPreference`) and removes it after conversion
3. **XML parsing** — loads the database with `[xml]`, selects all `<TRACK Location="...">` nodes, filters to `.flac` extensions
4. **Conversion loop** — for each FLAC track: clears read-only attribute if set, calls ffmpeg with `pcm_s16le` + `-map_metadata 0`, restores read-only attribute, updates `Location` and `Kind` attributes on the XML node
5. **XML save** — writes back with `XmlWriter` (UTF-8 without BOM, indented) only if at least one track was converted
6. **Logging** — writes `convert-log_<timestamp>.json` next to the XML; each entry has `timestamp`, `flacPath`, `wavPath`, `status` (`"success"` or `"failed"`), and for successes: `originalLocation`, `newLocation`, `originalKind`

## Rekordbox location format

Track paths in the XML use a URI scheme: `file://localhost/D:/path/to/file.flac` with URL-encoded characters. Two helpers handle the round-trip:

- `Decode-RekordboxLocation` — strips the prefix, URL-decodes, converts forward slashes to backslashes
- `Encode-RekordboxLocation` — converts backslashes to forward slashes, URL-encodes each path segment with `[Uri]::EscapeDataString`, prepends `file://localhost/`

When modifying path handling, always test with filenames that contain spaces and special characters.

## Key parameters

| Parameter | Effect |
|---|---|
| `-DryRun` | Skips backup, ffmpeg, XML save, and log write; all output is prefixed `[DRY RUN]` |
| `-Force` | Bypasses the "WAV already exists" skip check; ffmpeg `-y` handles the actual overwrite |
| `-Verbose` | Removes `-loglevel error` from ffmpeg args, showing full conversion output |
