# Helpers for converting between Windows/macOS file paths and Rekordbox URI format.
# Rekordbox stores track locations as: file://localhost/D:/path/to/file.flac (Windows)
#                                       file://localhost/Users/name/Music/track.flac (macOS)

function Decode-RekordboxLocation([string]$location) {
    $path = $location -replace '^file://localhost/', ''
    $path = [Uri]::UnescapeDataString($path)
    if ($onWindows) { return $path.Replace('/', '\') }
    return "/$path"  # restore leading slash stripped by the URI prefix on macOS
}

function Encode-RekordboxLocation([string]$filePath) {
    # Normalise separators and strip leading slash before building the URI,
    # otherwise macOS absolute paths produce a double slash after localhost/
    $forward = $filePath.Replace('\', '/').TrimStart('/')
    $encoded = ($forward.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    return "file://localhost/$encoded"
}
