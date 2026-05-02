# Manages temporary whitelisting of ffmpeg in Windows Controlled Folder Access (CFA).
# CFA is a Windows Defender feature that blocks untrusted apps from writing to
# protected folders (Music, Documents, etc.), causing ffmpeg to fail with exit -13.

function Register-FfmpegCFA([string]$ffmpegPath) {
    $state = @{ cfaEnabled = $false; isAdmin = $false; ffmpegAllowed = $false }

    $state.isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    try {
        $state.cfaEnabled = (Get-MpPreference -ErrorAction Stop).EnableControlledFolderAccess -eq 1
    } catch {
        # Defender cmdlets unavailable; assume CFA is not active
    }

    if ($state.cfaEnabled) {
        if (-not $state.isAdmin) {
            Write-Warning "Windows Controlled Folder Access is enabled but the script is not running as Administrator. Conversions may fail with 'Permission denied'. Re-run as Administrator to allow the script to whitelist ffmpeg automatically."
        } else {
            $state.ffmpegAllowed = (Get-MpPreference).ControlledFolderAccessAllowedApplications -contains $ffmpegPath
            if (-not $state.ffmpegAllowed) {
                Add-MpPreference -ControlledFolderAccessAllowedApplications $ffmpegPath
                Write-Host "ffmpeg whitelisted in Controlled Folder Access." -ForegroundColor Green
            }
        }
    }

    return $state
}

function Unregister-FfmpegCFA([string]$ffmpegPath, [hashtable]$state) {
    if ($state.cfaEnabled -and $state.isAdmin -and -not $state.ffmpegAllowed) {
        Remove-MpPreference -ControlledFolderAccessAllowedApplications $ffmpegPath
        Write-Host "ffmpeg removed from Controlled Folder Access whitelist." -ForegroundColor Green
    }
}
