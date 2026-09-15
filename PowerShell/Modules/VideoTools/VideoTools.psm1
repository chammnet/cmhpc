<#
.SYNOPSIS
    VideoTools - Video tools for field recording workflows.

.DESCRIPTION
    Provides tools for working with camera footage in field recording
    post-production workflows:

        Repair-VideoTimecode  Fixes TC stream placement and drops audio from
                              camera clips exported by Tentacle Timecode Tool

.NOTES
    Author   : Craig Hamm
    Version  : 1.0.0
    Requires : PowerShell 5.1 or later
               ffmpeg and ffprobe on the system PATH  (winget install ffmpeg)
#>

$Private = Get-ChildItem -Path "$PSScriptRoot\Private" -Filter '*.ps1' -ErrorAction SilentlyContinue
$Public = Get-ChildItem -Path "$PSScriptRoot\Public" -Filter '*.ps1' -ErrorAction SilentlyContinue

foreach ($file in ($Private + $Public)) {
    try {
        . $file.FullName
    }
    catch {
        Write-Error "VideoTools: Failed to import '$($file.FullName)': $_"
    }
}