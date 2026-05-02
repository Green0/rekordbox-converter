#Requires -Version 5.1
# On macOS/Linux, run with PowerShell Core: pwsh Convert-RekordboxFlac.ps1
<#
.SYNOPSIS
    Converts FLAC tracks in a Rekordbox XML database to WAV, updating the XML in place.
.PARAMETER DryRun
    Preview all actions without converting files or modifying the database.
.PARAMETER Force
    Reconvert files that already have a WAV alongside them.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force
)

if ($DryRun) { Write-Host "[DRY RUN] No files will be converted and the database will not be modified.`n" -ForegroundColor Cyan }

# $IsWindows is undefined in Windows PowerShell 5.1 (only set in PowerShell Core 6+)
$onWindows = ($null -eq $IsWindows) -or $IsWindows

. (Join-Path $PSScriptRoot "lib/RekordboxXml.ps1")
. (Join-Path $PSScriptRoot "lib/Playlists.ps1")
. (Join-Path $PSScriptRoot "lib/InteractiveMenu.ps1")
if ($onWindows) { . (Join-Path $PSScriptRoot "lib/WindowsCFA.ps1") }

# ── Prompt for XML path ───────────────────────────────────────────────────────
$defaultPath = if ($onWindows) {
    Join-Path $env:APPDATA "Pioneer\rekordbox\rekordbox.xml"
} else {
    Join-Path $HOME "Library/Application Support/Pioneer/rekordbox/rekordbox.xml"
}
$xmlPath = Read-Host "Rekordbox XML path [$defaultPath]"
if ([string]::IsNullOrWhiteSpace($xmlPath)) { $xmlPath = $defaultPath }

if (-not (Test-Path $xmlPath)) {
    Write-Error "File not found: $xmlPath"
    exit 1
}

# ── Check ffmpeg ──────────────────────────────────────────────────────────────
$ffmpegCmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
if (-not $ffmpegCmd) {
    Write-Error "ffmpeg not found in PATH. Install it from https://ffmpeg.org/download.html and ensure it is in your PATH."
    exit 1
}
$ffmpegPath = $ffmpegCmd.Source

# ── Output folder (logs + backups) ───────────────────────────────────────────
$outputDir = Join-Path ([System.IO.Path]::GetDirectoryName($xmlPath)) "rekordbox-converter"
if (-not $DryRun -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
    Write-Host "Created output folder: $outputDir" -ForegroundColor Green
}

# ── Backup ────────────────────────────────────────────────────────────────────
$runTimestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$backupPath = Join-Path $outputDir ([System.IO.Path]::GetFileNameWithoutExtension($xmlPath) + "_$runTimestamp.bak")
if ($DryRun) {
    Write-Host "[DRY RUN] Would create backup: $backupPath" -ForegroundColor Cyan
} else {
    Copy-Item $xmlPath $backupPath
    Write-Host "Backup created: $backupPath" -ForegroundColor Green
}

# ── Whitelist ffmpeg in Controlled Folder Access (Windows only) ───────────────
$cfaState = $null
if ($onWindows -and -not $DryRun) {
    $cfaState = Register-FfmpegCFA $ffmpegPath
}

# ── Load XML ──────────────────────────────────────────────────────────────────
[xml]$db = Get-Content $xmlPath -Encoding UTF8

# ── Select target ─────────────────────────────────────────────────────────────
$playlists   = Get-RekordboxPlaylists $db
$menuOptions = @("Entire collection") + ($playlists | ForEach-Object { $_.DisplayName })
$selection   = Show-Menu -Title "What would you like to convert?" -Options $menuOptions

$targetTrackIds = $null  # $null means entire collection
if ($selection -gt 0) {
    $targetTrackIds = $playlists[$selection - 1].TrackIds
    Write-Host "  Target : $($playlists[$selection - 1].DisplayName)`n" -ForegroundColor White
} else {
    Write-Host "  Target : Entire collection`n" -ForegroundColor White
}

# ── Process tracks ────────────────────────────────────────────────────────────
$tracks     = $db.SelectNodes("//TRACK[@Location]")
$converted  = 0
$skipped    = 0
$errors     = [System.Collections.Generic.List[string]]::new()
$logEntries = [System.Collections.Generic.List[hashtable]]::new()

foreach ($track in $tracks) {
    if ($null -ne $targetTrackIds -and $targetTrackIds -notcontains $track.GetAttribute("TrackID")) { continue }

    $location = $track.GetAttribute("Location")
    if ($location -notmatch '\.flac$') { continue }

    $srcPath = Decode-RekordboxLocation $location
    $wavPath = [System.IO.Path]::ChangeExtension($srcPath, ".wav")

    if ($DryRun) {
        Write-Host "[DRY RUN] Would convert: $srcPath  ->  $wavPath" -ForegroundColor Cyan
    } else {
        Write-Host "Converting: $srcPath" -ForegroundColor Gray
    }

    if (-not (Test-Path $srcPath)) {
        $msg = "Source not found, skipping: $srcPath"
        Write-Host "  ERROR: $msg" -ForegroundColor Red
        $errors.Add($msg)
        $skipped++
        if (-not $DryRun) {
            $logEntries.Add(@{ timestamp = (Get-Date -Format "o"); flacPath = $srcPath; wavPath = $wavPath; status = "failed"; error = $msg })
        }
        continue
    }

    if ($DryRun) {
        if ((Test-Path $wavPath) -and -not $Force) { Write-Host "  WAV already exists, would skip conversion: $wavPath" -ForegroundColor Yellow }
    } else {
        if ((Test-Path $wavPath) -and -not $Force) {
            Write-Host "  WAV already exists, skipping conversion: $wavPath" -ForegroundColor Yellow
        } else {
            $wasReadOnly = (Get-Item $srcPath).IsReadOnly
            if ($wasReadOnly) { Set-ItemProperty $srcPath -Name IsReadOnly -Value $false }

            # -c:a pcm_s16le  standard 16-bit WAV; change to pcm_s24le for 24-bit sources
            $loglevel   = if ($VerbosePreference -ne 'SilentlyContinue') { @() } else { @("-loglevel", "error") }
            $ffmpegArgs = $loglevel + @("-i", $srcPath, "-y", "-c:a", "pcm_s16le", "-map_metadata", "0", "-id3v2_version", "3", $wavPath)
            & $ffmpegPath @ffmpegArgs

            if ($wasReadOnly) { Set-ItemProperty $srcPath -Name IsReadOnly -Value $true }

            if ($LASTEXITCODE -ne 0) {
                $msg = "ffmpeg failed for: $srcPath (exit $LASTEXITCODE)"
                Write-Host "  ERROR: $msg" -ForegroundColor Red
                $errors.Add($msg)
                $skipped++
                $logEntries.Add(@{ timestamp = (Get-Date -Format "o"); flacPath = $srcPath; wavPath = $wavPath; status = "failed"; error = $msg })
                continue
            }
        }

        Write-Host "  -> $wavPath" -ForegroundColor Green

        $originalLocation = $location
        $originalKind     = if ($track.HasAttribute("Kind")) { $track.GetAttribute("Kind") } else { $null }
        $newLocation      = Encode-RekordboxLocation $wavPath

        $track.SetAttribute("Location", $newLocation)
        if ($track.HasAttribute("Kind")) { $track.SetAttribute("Kind", "WAV File") }

        $logEntries.Add(@{
            timestamp        = (Get-Date -Format "o")
            flacPath         = $srcPath
            wavPath          = $wavPath
            status           = "success"
            originalLocation = $originalLocation
            newLocation      = $newLocation
            originalKind     = $originalKind
        })
    }

    $converted++
}

# ── Remove ffmpeg from Controlled Folder Access whitelist ─────────────────────
if ($onWindows -and -not $DryRun -and $cfaState) {
    Unregister-FfmpegCFA $ffmpegPath $cfaState
}

# ── Save updated XML ──────────────────────────────────────────────────────────
if ($DryRun) {
    Write-Host "`n[DRY RUN] Database would be updated: $xmlPath" -ForegroundColor Cyan
} elseif ($converted -gt 0) {
    $settings          = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent   = $true
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)  # UTF-8 without BOM

    $writer = [System.Xml.XmlWriter]::Create($xmlPath, $settings)
    $db.Save($writer)
    $writer.Close()
    Write-Host "`nDatabase updated: $xmlPath" -ForegroundColor Green
} else {
    Write-Host "`nNo tracks were converted; database unchanged." -ForegroundColor Yellow
}

# ── Write convert log ─────────────────────────────────────────────────────────
$logPath = Join-Path $outputDir "convert-log_$runTimestamp.json"
if (-not $DryRun -and $logEntries.Count -gt 0) {
    @{
        timestamp  = (Get-Date -Format "o")
        xmlPath    = $xmlPath
        backupPath = $backupPath
        tracks     = $logEntries.ToArray()
    } | ConvertTo-Json -Depth 5 | Set-Content $logPath -Encoding UTF8
    Write-Host "Convert log written: $logPath" -ForegroundColor Green
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Summary$(if ($DryRun) { ' (DRY RUN)' }) ===" -ForegroundColor White
Write-Host "  $(if ($DryRun) { 'Would convert' } else { 'Converted   ' }): $converted" -ForegroundColor $(if ($converted -gt 0) { 'Green' } else { 'Gray' })
Write-Host "  Skipped   : $skipped" -ForegroundColor $(if ($skipped -gt 0) { 'Yellow' } else { 'Gray' })
if ($errors.Count -gt 0) {
    Write-Host "  Errors    : $($errors.Count)" -ForegroundColor Red
}
