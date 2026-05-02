# Renders an arrow-key-navigable selection menu in the terminal.
# Returns the index of the selected option.

function Show-Menu {
    param(
        [string]$Title,
        [string[]]$Options,
        [int]$PageSize = 12
    )

    $selected  = 0
    $scrollTop = 0

    Write-Host "`n  $Title" -ForegroundColor White
    Write-Host "  Arrow keys to navigate, Enter to confirm.`n" -ForegroundColor DarkGray

    # Record where the menu starts, then pre-fill lines so the terminal
    # does not scroll when we redraw in place later.
    $menuStartRow = [Console]::CursorTop
    $totalLines   = $PageSize + 2  # +2 for the top/bottom scroll indicators
    for ($i = 0; $i -lt $totalLines; $i++) { Write-Host "" }

    [Console]::CursorVisible = $false
    try {
        while ($true) {
            # Keep the selected item inside the visible window
            if ($selected -lt $scrollTop) { $scrollTop = $selected }
            if ($selected -ge $scrollTop + $PageSize) { $scrollTop = $selected - $PageSize + 1 }

            [Console]::SetCursorPosition(0, $menuStartRow)

            $maxLabelWidth = [Math]::Max(10, [Console]::WindowWidth - 8)
            $visibleEnd    = [Math]::Min($scrollTop + $PageSize, $Options.Count)

            # Top scroll indicator
            $topMsg = if ($scrollTop -gt 0) { "  ^ ($scrollTop more above)" } else { "" }
            Write-Host $topMsg.PadRight([Console]::WindowWidth - 1) -ForegroundColor DarkGray

            # Visible options
            for ($i = $scrollTop; $i -lt $visibleEnd; $i++) {
                $label = $Options[$i]
                if ($label.Length -gt $maxLabelWidth) {
                    $label = $label.Substring(0, $maxLabelWidth - 3) + "..."
                }
                $line  = if ($i -eq $selected) { "  > $label" } else { "    $label" }
                $color = if ($i -eq $selected) { "Cyan" } else { "Gray" }
                Write-Host $line.PadRight([Console]::WindowWidth - 1) -ForegroundColor $color
            }

            # Fill remaining rows so the layout stays stable when the list is short
            for ($i = $visibleEnd; $i -lt $scrollTop + $PageSize; $i++) {
                Write-Host "".PadRight([Console]::WindowWidth - 1)
            }

            # Bottom scroll indicator
            $remaining = $Options.Count - $visibleEnd
            $botMsg    = if ($remaining -gt 0) { "  v ($remaining more below)" } else { "" }
            Write-Host $botMsg.PadRight([Console]::WindowWidth - 1) -ForegroundColor DarkGray

            # Input
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { if ($selected -gt 0) { $selected-- } }
                'DownArrow' { if ($selected -lt $Options.Count - 1) { $selected++ } }
                'Home'      { $selected = 0; $scrollTop = 0 }
                'End'       { $selected = $Options.Count - 1 }
                'Enter'     { return $selected }
            }
        }
    } finally {
        [Console]::CursorVisible = $true
        [Console]::SetCursorPosition(0, $menuStartRow + $totalLines)
        Write-Host ""
    }
}
