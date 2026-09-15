function Repair-VideoTimecode {
    <#
    .SYNOPSIS
        Copies TC from any stream into the video stream and strips audio.
        No re-encode.

    .DESCRIPTION
        Reads timecode from whichever stream holds it (video, format, or timed
        metadata), then writes a new video-only file with that TC embedded in
        the video stream where DaVinci Resolve can find it for auto-align.

        Designed for MP4 files exported by the Tentacle Timecode Tool, which
        correctly decodes 29.97DF LTC but places it in the wrong stream.

    .PARAMETER Path
        Path(s) to the input video file(s). Accepts pipeline input.

    .PARAMETER Suffix
        String appended to the base filename for the output file.
        Default: '-tcfix'

    .PARAMETER Overwrite
        If specified, replaces the original file in place rather than writing
        a suffixed copy. Uses a temp file during the operation for safety.
        Also allows overwriting an existing suffixed output file.

    .EXAMPLE
        Repair-VideoTimecode -Path 'X:\Capture\Camera\C0002_1.MP4'
        # Produces C0002_1-tcfix.MP4 alongside the original

    .EXAMPLE
        Get-ChildItem 'X:\Capture\Camera' -Filter '*_1.MP4' |
            Repair-VideoTimecode -Suffix '-tcfix'

    .EXAMPLE
        Repair-VideoTimecode -Path 'X:\Capture\Camera\C0002_1.MP4' -Overwrite

    .EXAMPLE
        Repair-VideoTimecode -Path 'X:\Capture\Camera\C0002_1.MP4' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string[]]$Path,

        [string]$Suffix = '-tcfix',

        [switch]$Overwrite
    )

    process {
        foreach ($p in $Path) {
            $file = Get-Item -LiteralPath $p

            # ------------------------------------------------------------------
            # Probe: find TC in whichever stream holds it
            # ------------------------------------------------------------------
            $probeJson = & ffprobe -v quiet -show_streams -show_format -of json `
                $file.FullName 2>$null

            if (-not $probeJson) {
                Write-Warning "[$($file.Name)] ffprobe returned no output -- skipping"
                continue
            }

            $probe = $probeJson | ConvertFrom-Json
            $tc = $null

            foreach ($stream in $probe.streams) {
                if ($stream.tags.timecode) {
                    $tc = $stream.tags.timecode
                    Write-Verbose "[$($file.Name)] TC found in stream $($stream.index) ($($stream.codec_type)): $tc"
                    break
                }
            }

            if (-not $tc -and $probe.format.tags.timecode) {
                $tc = $probe.format.tags.timecode
                Write-Verbose "[$($file.Name)] TC found in format tags: $tc"
            }

            if (-not $tc) {
                Write-Warning "[$($file.Name)] No timecode found in any stream or format tags -- skipping"
                continue
            }

            $tc = $tc.Trim()
            Write-Host "[$($file.Name)]  TC: $tc  (audio will be stripped)" -ForegroundColor Cyan

            # ------------------------------------------------------------------
            # Output path
            # ------------------------------------------------------------------
            if ($Overwrite) {
                $outPath = Join-Path $file.DirectoryName ($file.BaseName + '_DFTMP' + $file.Extension)
            }
            else {
                $outPath = Join-Path $file.DirectoryName ($file.BaseName + $Suffix + $file.Extension)

                if (Test-Path -LiteralPath $outPath) {
                    Write-Warning "[$($file.Name)] Output already exists: $(Split-Path $outPath -Leaf) -- skipping. Use -Overwrite to replace."
                    continue
                }
            }

            # ------------------------------------------------------------------
            # ffmpeg: copy video stream, drop audio, embed TC in video stream
            # ------------------------------------------------------------------
            if ($PSCmdlet.ShouldProcess($file.Name, "Write video-only copy with TC in video stream -> $outPath")) {
                & ffmpeg -i $file.FullName -c copy -an -timecode $tc $outPath

                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "[$($file.Name)] ffmpeg exited with code $LASTEXITCODE"
                    if ($Overwrite -and (Test-Path $outPath)) {
                        Remove-Item -LiteralPath $outPath
                        Write-Warning "[$($file.Name)] Temp file removed -- original untouched"
                    }
                    continue
                }

                if ($Overwrite) {
                    Remove-Item -LiteralPath $file.FullName
                    Rename-Item -LiteralPath $outPath -NewName $file.Name
                    Write-Host "[$($file.Name)] Overwritten in place" -ForegroundColor Green
                }
                else {
                    Write-Host "[$($file.Name)] Written to: $(Split-Path $outPath -Leaf)" -ForegroundColor Green
                }
            }
        }
    }
}