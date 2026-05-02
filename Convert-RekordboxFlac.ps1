#Requires -Version 5.1
# On macOS/Linux, run with PowerShell Core: pwsh Convert-RekordboxFlac.ps1
<#
.SYNOPSIS
    Converts FLAC tracks in a Rekordbox XML database to WAV, updating the XML in place.
.PARAMETER DryRun
    Preview all actions without converting files or modifying the database.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force
)

if ($DryRun) { Write-Host "[DRY RUN] No files will be converted and the database will not be modified.`n" -ForegroundColor Cyan }

# $IsWindows is undefined in Windows PowerShell 5.1 (only set in PowerShell Core 6+)
$onWindows = ($null -eq $IsWindows) -or $IsWindows

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

# ── Whitelist ffmpeg in Controlled Folder Access (Windows only) ───────────────
$isAdmin       = $false
$cfaEnabled    = $false
$ffmpegAllowed = $false
if ($onWindows -and -not $DryRun) {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    try {
        $cfaEnabled = (Get-MpPreference -ErrorAction Stop).EnableControlledFolderAccess -eq 1
    }
    catch {
        # Defender cmdlets unavailable; assume CFA is not active
    }

    if ($cfaEnabled) {
        if (-not $isAdmin) {
            Write-Warning "Windows Controlled Folder Access is enabled but the script is not running as Administrator. Conversions may fail with 'Permission denied'. Re-run as Administrator to allow the script to whitelist ffmpeg automatically."
        }
        else {
            $ffmpegAllowed = (Get-MpPreference).ControlledFolderAccessAllowedApplications -contains $ffmpegPath
            if (-not $ffmpegAllowed) {
                Add-MpPreference -ControlledFolderAccessAllowedApplications $ffmpegPath
                Write-Host "ffmpeg whitelisted in Controlled Folder Access." -ForegroundColor Green
            }
        }
    }
}

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
}
else {
    Copy-Item $xmlPath $backupPath
    Write-Host "Backup created: $backupPath" -ForegroundColor Green
}

# ── Load XML ──────────────────────────────────────────────────────────────────
[xml]$db = Get-Content $xmlPath -Encoding UTF8

# ── Helpers ───────────────────────────────────────────────────────────────────
function Decode-RekordboxLocation([string]$location) {
    # Location format: file://localhost/D:/path/to/file.flac (Windows)
    #                  file://localhost/Users/name/Music/track.flac (macOS)
    $path = $location -replace '^file://localhost/', ''
    $path = [Uri]::UnescapeDataString($path)
    if ($onWindows) { return $path.Replace('/', '\') }
    return "/$path"  # restore leading slash stripped by the URI prefix
}

function Encode-RekordboxLocation([string]$filePath) {
    # Normalise to forward slashes and strip leading slash on macOS before building URI
    $forward = $filePath.Replace('\', '/').TrimStart('/')
    # URL-encode each path segment (spaces → %20, etc.) but keep slashes and colons intact
    $encoded = ($forward.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    return "file://localhost/$encoded"
}

# ── Process tracks ────────────────────────────────────────────────────────────
$tracks = $db.SelectNodes("//TRACK[@Location]")
$converted = 0
$skipped = 0
$errors = [System.Collections.Generic.List[string]]::new()
$logEntries = [System.Collections.Generic.List[hashtable]]::new()

foreach ($track in $tracks) {
    $location = $track.GetAttribute("Location")
    if ($location -notmatch '\.flac$') { continue }

    $srcPath = Decode-RekordboxLocation $location
    $wavPath = [System.IO.Path]::ChangeExtension($srcPath, ".wav")

    if ($DryRun) {
        Write-Host "[DRY RUN] Would convert: $srcPath  ->  $wavPath" -ForegroundColor Cyan
    }
    else {
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
    }
    else {
        if ((Test-Path $wavPath) -and -not $Force) {
            Write-Host "  WAV already exists, skipping conversion: $wavPath" -ForegroundColor Yellow
        }
        else {
            # -y     overwrite without prompt (shouldn't happen given check above, safety net)
            # -c:a   pcm_s16le  standard CD-quality WAV; change to pcm_s24le for 24-bit sources
            $wasReadOnly = (Get-Item $srcPath).IsReadOnly
            if ($wasReadOnly) { Set-ItemProperty $srcPath -Name IsReadOnly -Value $false }

            $loglevel = if ($VerbosePreference -ne 'SilentlyContinue') { @() } else { @("-loglevel", "error") }
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

        # Update XML attribute
        $originalLocation = $location
        $originalKind = if ($track.HasAttribute("Kind")) { $track.GetAttribute("Kind") } else { $null }
        $newLocation = Encode-RekordboxLocation $wavPath

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

# ── Remove ffmpeg from Controlled Folder Access whitelist ────────────────────
if (-not $DryRun -and $cfaEnabled -and $isAdmin -and -not $ffmpegAllowed) {
    Remove-MpPreference -ControlledFolderAccessAllowedApplications $ffmpegPath
    Write-Host "ffmpeg removed from Controlled Folder Access whitelist." -ForegroundColor Green
}

# ── Save updated XML ──────────────────────────────────────────────────────────
if ($DryRun) {
    Write-Host "`n[DRY RUN] Database would be updated: $xmlPath" -ForegroundColor Cyan
}
elseif ($converted -gt 0) {
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)  # UTF-8 without BOM

    $writer = [System.Xml.XmlWriter]::Create($xmlPath, $settings)
    $db.Save($writer)
    $writer.Close()
    Write-Host "`nDatabase updated: $xmlPath" -ForegroundColor Green
}
else {
    Write-Host "`nNo tracks were converted; database unchanged." -ForegroundColor Yellow
}

# ── Write convert log ────────────────────────────────────────────────────────
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
