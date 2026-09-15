<#
.SYNOPSIS
    AudioTools - Audio tools for field recording workflows.

.DESCRIPTION
    Provides tools for working with Zoom F6 multitrack recordings:

        Merge-AudioTakes  Merges split .TAKE WAV files into single RF64 .WAV files

.NOTES
    Author   : Craig Hamm
    Version  : 1.1.0
    Requires : PowerShell 5.1 or later
               ffmpeg on the system PATH  (winget install ffmpeg)
#>


# ══════════════════════════════════════════════════════════════════════════════
# PRIVATE: Copy-WavIxmlChunk
# ══════════════════════════════════════════════════════════════════════════════
#
# Reads the iXML chunk (BWF metadata used by Resolve, Reaper, etc. for track
# names, scene/take, project info) from a source WAV file and appends it to a
# destination WAV file, patching the RIFF/RF64 size header to keep the file
# well-formed.
#
# This exists because ffmpeg's WAV muxer doesn't preserve iXML chunks - there
# is no `-write_ixml` flag. So we let ffmpeg do the audio concat (which it's
# good at) and then graft the iXML back on as a post-process.
#
# Returns:
#   $true  - iXML found in source and successfully grafted onto destination
#   $false - source has no iXML chunk (returns silently, destination unchanged)
#
# Throws on malformed input or unsupported file states.
#
# Approach: chunks live at the container level, not the audio stream level.
# Walking RIFF/RF64 is just a sequence of FOURCC + size + bytes. We read until
# we find iXML, capture the chunk bytes verbatim (header + payload + word-align
# pad if needed), then append to the destination and update one size field.
#
# RF64 note: when total file size exceeds 4GB, the magic is "RF64" instead of
# "RIFF" and the real 64-bit size lives in a ds64 chunk at offset 12. The data
# chunk's size in the header reads 0xFFFFFFFF as a sentinel. For our purposes
# we only care about finding iXML (always small, always before the data chunk)
# and patching one size field on append.

function Copy-WavIxmlChunk {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    # -------------------------------------------------------------------------
    # Step 1: Locate and capture iXML chunk bytes from $Source
    # -------------------------------------------------------------------------
    $ixmlChunkBytes = $null

    $srcStream = [System.IO.File]::OpenRead($Source)
    try {
        $reader = New-Object System.IO.BinaryReader($srcStream)

        $magic = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne 'RIFF' -and $magic -ne 'RF64') {
            throw "Source is not a RIFF/RF64 file: $Source"
        }
        $null = $reader.ReadBytes(4)   # skip 32-bit size (or 0xFFFFFFFF for RF64)

        $wave = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($wave -ne 'WAVE') {
            throw "Source is not a WAVE file (missing WAVE tag): $Source"
        }

        # Walk chunks
        while ($srcStream.Position -lt $srcStream.Length) {
            $idBytes = $reader.ReadBytes(4)
            if ($idBytes.Length -lt 4) { break }
            $chunkId = [System.Text.Encoding]::ASCII.GetString($idBytes)
            $chunkSize = $reader.ReadUInt32()

            if ($chunkId -eq 'iXML') {
                $payload = $reader.ReadBytes([int]$chunkSize)

                # Word alignment: odd chunk sizes have an implicit pad byte
                $padByte = ($chunkSize % 2 -ne 0)

                $ms = New-Object System.IO.MemoryStream
                $writer = New-Object System.IO.BinaryWriter($ms)
                try {
                    $writer.Write([System.Text.Encoding]::ASCII.GetBytes('iXML'))
                    $writer.Write([uint32]$chunkSize)
                    $writer.Write($payload)
                    if ($padByte) { $writer.Write([byte]0) }
                    $writer.Flush()
                    $ixmlChunkBytes = $ms.ToArray()
                }
                finally {
                    $writer.Dispose()
                    $ms.Dispose()
                }
                break
            }

            if ($chunkId -eq 'data') {
                # iXML always appears before data in well-formed BWF files. If
                # we hit data without finding it, there's no iXML to graft.
                break
            }

            # Skip this chunk (with word-alignment padding)
            $skipSize = [long]$chunkSize
            if ($skipSize % 2 -ne 0) { $skipSize++ }
            $null = $srcStream.Seek($skipSize, [System.IO.SeekOrigin]::Current)
        }

        $reader.Dispose()
    }
    finally {
        $srcStream.Dispose()
    }

    if ($null -eq $ixmlChunkBytes) {
        return $false
    }

    # -------------------------------------------------------------------------
    # Step 2: Append iXML chunk to $Destination, patch size header
    # -------------------------------------------------------------------------
    $destStream = [System.IO.File]::Open(
        $Destination,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        $br = New-Object System.IO.BinaryReader($destStream)
        $bw = New-Object System.IO.BinaryWriter($destStream)
        try {
            $destStream.Position = 0
            $destMagic = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
            if ($destMagic -ne 'RIFF' -and $destMagic -ne 'RF64') {
                throw "Destination is not a RIFF/RF64 file: $Destination"
            }

            # Append iXML chunk at end of file. ffmpeg's WAV output already ends
            # on a word-aligned boundary (data chunk is padded if necessary), so
            # we can append directly without extra alignment.
            $destStream.Position = $destStream.Length
            $bw.Write($ixmlChunkBytes)
            $bw.Flush()
            $newFileSize = $destStream.Length

            # Update the appropriate size field
            if ($destMagic -eq 'RIFF') {
                # 32-bit RIFF size at offset 4. Value = total file size - 8.
                $newRiffSize = $newFileSize - 8
                if ($newRiffSize -gt [uint32]::MaxValue) {
                    throw ('File grew past 4GB RIFF limit after iXML graft. ' +
                        'This would require converting RIFF to RF64, which ' +
                        "is not supported by this tool. File: $Destination")
                }
                $destStream.Position = 4
                $bw.Write([uint32]$newRiffSize)
            }
            else {
                # RF64: 64-bit riffSize at offset 20, inside the ds64 chunk.
                #   offset 12: "ds64" (4)
                #   offset 16: ds64 chunk size (uint32, 4)
                #   offset 20: riffSize64 (uint64, 8)
                $destStream.Position = 12
                $ds64Tag = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
                if ($ds64Tag -ne 'ds64') {
                    throw "RF64 file missing ds64 chunk: $Destination"
                }
                $destStream.Position = 20
                $bw.Write([uint64]($newFileSize - 8))
            }

            $bw.Flush()
        }
        finally {
            $br.Dispose()
            $bw.Dispose()
        }
    }
    finally {
        $destStream.Dispose()
    }

    return $true
}


# ══════════════════════════════════════════════════════════════════════════════
# PUBLIC: Merge-AudioTakes
# ══════════════════════════════════════════════════════════════════════════════

function Merge-AudioTakes {
    <#
    .SYNOPSIS
        Merges split Zoom F6 .TAKE WAV files into single RF64 .WAV files.

    .DESCRIPTION
        Opens a GUI tool that scans a root folder for .TAKE directories,
        groups them by session number, and concatenates split recordings
        per track using ffmpeg. Single-part sessions are skipped. Cross-date
        sessions within 1 calendar day are merged using the later date.
        Sessions spanning more than 1 day are flagged and skipped.
        Output is lossless (pure PCM stream copy, no re-encoding).
        BWF metadata is preserved from the first part:
          - bext chunk (TimeReference / timecode, origination date/time, etc.)
            is preserved via ffmpeg's -write_bext flag and -map_metadata.
          - iXML chunk (track names, scene/take, project info, redundant
            TimeReference) is grafted onto the merged file as a post-process,
            since ffmpeg cannot preserve iXML natively.
        Merged files retain sample-accurate timecode for sync in Resolve /
        Reaper. Originals are never modified.
        Requires ffmpeg on the system PATH (winget install ffmpeg).

    .EXAMPLE
        Merge-AudioTakes

    .NOTES
        Zoom F6 naming conventions handled:
            Pattern A (single/first part, no split number): YYMMDD_SSS.TAKE
            Pattern B (split parts):                        YYMMDD_SSS_PPPP.TAKE
        Where SSS = session number, PPPP = zero-padded split number.
        Pattern A is always treated as the first part when mixed with Pattern B.
    #>

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # ---------------------------------------------------------------------------
    # Helpers
    # ---------------------------------------------------------------------------
    function Write-Log {
        param(
            [string]$Message,
            [System.Drawing.Color]$Color = [System.Drawing.Color]::FromArgb(220, 220, 220)
        )
        $script:rtb.SelectionStart = $script:rtb.TextLength
        $script:rtb.SelectionLength = 0
        $script:rtb.SelectionColor = $Color
        $script:rtb.AppendText("$Message`n")
        $script:rtb.ScrollToCaret()
        $script:form.Refresh()
    }

    function Show-Error {
        param([string]$Title, [string]$Body)
        [System.Windows.Forms.MessageBox]::Show(
            $Body, $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }

    function Test-Ffmpeg {
        param([string]$Path)
        try { $null = & $Path -version 2>&1; return $true }
        catch { return $false }
    }

    # ---------------------------------------------------------------------------
    # ConvertFrom-TakeFolderName
    # Returns $null if the name doesn't match either pattern
    #
    # Pattern A: YYMMDD_SSS.TAKE          -> Date=YYMMDD, Session=SSS, Split=-1
    # Pattern B: YYMMDD_SSS_PPPP.TAKE     -> Date=YYMMDD, Session=SSS, Split=PPPP
    # ---------------------------------------------------------------------------
    function ConvertFrom-TakeFolderName {
        param([string]$Name)
        $base = $Name -replace '\.TAKE$', ''

        if ($base -match '^(\d{6})_(\d{3})_(\d{4})$') {
            return [PSCustomObject]@{
                Date    = $Matches[1]
                Session = $Matches[2]
                Split   = [int]$Matches[3]
                IsPartA = $false
            }
        }
        if ($base -match '^(\d{6})_(\d{3})$') {
            return [PSCustomObject]@{
                Date    = $Matches[1]
                Session = $Matches[2]
                Split   = -1
                IsPartA = $true
            }
        }
        return $null
    }

    # ---------------------------------------------------------------------------
    # ConvertTo-Date
    # ---------------------------------------------------------------------------
    function ConvertTo-Date {
        param([string]$YYMMDD)
        return [datetime]::ParseExact($YYMMDD, 'yyMMdd', $null)
    }

    # ---------------------------------------------------------------------------
    # Get-SessionGroups
    # ---------------------------------------------------------------------------
    function Get-SessionGroups {
        param([string]$Root)

        $takeFolders = Get-ChildItem -Path $Root -Directory |
            Where-Object { $_.Name -match '\.TAKE$' } |
            Sort-Object Name

        if (-not $takeFolders) { return 'NO_TAKES' }

        $sessions = [System.Collections.Generic.SortedDictionary[string,
        System.Collections.Generic.List[object]]]::new()
        $unparsed = [System.Collections.Generic.List[string]]::new()

        foreach ($td in $takeFolders) {
            $parsed = ConvertFrom-TakeFolderName $td.Name
            if (-not $parsed) { $unparsed.Add($td.Name); continue }

            $wavFiles = Get-ChildItem -Path $td.FullName -Filter '*.WAV' | Sort-Object Name
            if (-not $wavFiles) { continue }

            $tracks = @{}
            foreach ($wav in $wavFiles) {
                if ($wav.BaseName -match '_(Tr\d+)$') {
                    $trk = $Matches[1]
                    if (-not $tracks.ContainsKey($trk)) { $tracks[$trk] = $wav.FullName }
                }
            }

            $entry = [PSCustomObject]@{
                FolderName = $td.Name
                FolderPath = $td.FullName
                Date       = $parsed.Date
                Session    = $parsed.Session
                Split      = $parsed.Split
                IsPartA    = $parsed.IsPartA
                Tracks     = $tracks
            }

            if (-not $sessions.ContainsKey($parsed.Session)) {
                $sessions[$parsed.Session] = [System.Collections.Generic.List[object]]::new()
            }
            $sessions[$parsed.Session].Add($entry)
        }

        if ($sessions.Count -eq 0) { return 'NO_MATCHES' }

        $mergeGroups = [System.Collections.Generic.List[object]]::new()
        $skipGroups = [System.Collections.Generic.List[object]]::new()
        $warningGroups = [System.Collections.Generic.List[object]]::new()

        foreach ($sessionNum in $sessions.Keys) {
            $parts = $sessions[$sessionNum] | Sort-Object Split

            # Single Pattern A only -> skip
            if ($parts.Count -eq 1 -and $parts[0].IsPartA) {
                $skipGroups.Add([PSCustomObject]@{
                        Session = $sessionNum
                        Parts   = $parts
                    })
                continue
            }

            # Date sanity check
            $dates = $parts | ForEach-Object { ConvertTo-Date $_.Date }
            $minDate = ($dates | Measure-Object -Minimum).Minimum
            $maxDate = ($dates | Measure-Object -Maximum).Maximum
            $daySpan = ($maxDate - $minDate).Days
            $latestDate = $maxDate.ToString('yyMMdd')

            if ($daySpan -gt 1) {
                $warningGroups.Add([PSCustomObject]@{
                        Session = $sessionNum
                        Parts   = $parts
                        DaySpan = $daySpan
                        MinDate = $minDate.ToString('yyMMdd')
                        MaxDate = $latestDate
                    })
                continue
            }

            # Build per-track file lists
            $allTracks = $parts | ForEach-Object { $_.Tracks.Keys } | Sort-Object -Unique
            $trackLists = @{}
            foreach ($trk in $allTracks) {
                $trackLists[$trk] = [System.Collections.Generic.List[string]]::new()
                foreach ($part in $parts) {
                    if ($part.Tracks.ContainsKey($trk)) {
                        $trackLists[$trk].Add($part.Tracks[$trk])
                    }
                }
            }

            $mergeGroups.Add([PSCustomObject]@{
                    Session    = $sessionNum
                    Parts      = $parts
                    LatestDate = $latestDate
                    TrackLists = $trackLists
                    CrossDate  = ($daySpan -eq 1)
                })
        }

        return [PSCustomObject]@{
            MergeGroups   = $mergeGroups
            SkipGroups    = $skipGroups
            WarningGroups = $warningGroups
            Unparsed      = $unparsed
            TakeCount     = $takeFolders.Count
        }
    }

    # ---------------------------------------------------------------------------
    # Start-Merge
    # ---------------------------------------------------------------------------
    function Start-Merge {
        param(
            [string]$OutputFolder,
            [object]$ScanResult,
            [string]$FfmpegPath
        )

        # [char] variables for Unicode symbols - PS5-safe, displays correctly in both PS5 and PS7
        $charArrow = [char]0x25B6   # ▶
        $charWarn = [char]0x26A0   # ⚠
        $charCheck = [char]0x2714   # ✔
        $charCross = [char]0x2718   # ✘
        $charDot = [char]0x00B7   # ·

        $tempDir = Join-Path $env:TEMP "MergeAudioTakes_$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        $success = 0
        $failed = 0

        foreach ($group in $ScanResult.MergeGroups) {
            Write-Log ''
            Write-Log "$charArrow  Session $($group.Session)  ($($group.Parts.Count) part(s))" `
            ([System.Drawing.Color]::FromArgb(100, 180, 255))

            if ($group.CrossDate) {
                Write-Log "   $charWarn  Cross-date session - within 1-day threshold, proceeding." `
                ([System.Drawing.Color]::FromArgb(255, 200, 80))
            }

            foreach ($part in $group.Parts) {
                Write-Log "     $($part.FolderName)" ([System.Drawing.Color]::FromArgb(100, 100, 100))
            }

            foreach ($trk in ($group.TrackLists.Keys | Sort-Object)) {
                $files = $group.TrackLists[$trk]
                $outName = "$($group.LatestDate)_$($group.Session)_${trk}.WAV"
                $outPath = Join-Path $OutputFolder $outName

                Write-Log "     -> $outName" ([System.Drawing.Color]::FromArgb(160, 160, 160))

                $safeSuffix = "$($group.Session)_${trk}"
                $listFile = Join-Path $tempDir "list_${safeSuffix}.txt"
                $stderrFile = Join-Path $tempDir "stderr_${safeSuffix}.txt"

                $listLines = [System.Collections.Generic.List[string]]::new()
                foreach ($f in $files) {
                    $singleQuote = [char]39
                    $replacement = "$singleQuote\$singleQuote$singleQuote"
                    $listLines.Add("file '" + $f.Replace([string]$singleQuote, $replacement) + "'")
                }
                Set-Content -Path $listFile -Value $listLines -Encoding UTF8

                # ffmpeg invocation:
                #   -map_metadata 0   pull bext fields (TimeReference, etc.) from input
                #   -c copy           true PCM stream copy, no re-encode, source bit depth preserved
                #   -rf64 auto        write RF64 if final size > 4GB, otherwise standard RIFF
                #   -write_bext 1     emit the BWF bext chunk in the output mux
                $firstSource = $files[0]

                $ffArgs = @(
                    '-y',
                    '-f', 'concat', '-safe', '0',
                    '-i', "`"$listFile`"",
                    '-i', "`"$firstSource`"",
                    '-map', '0:a',
                    '-map_metadata', '1',
                    '-c', 'copy',
                    '-rf64', 'auto',
                    '-write_bext', '1',
                    '-f', 'wav',
                    "`"$outPath`""
                )

                $proc = Start-Process -FilePath $FfmpegPath `
                    -ArgumentList $ffArgs `
                    -Wait -PassThru -NoNewWindow `
                    -RedirectStandardError $stderrFile

                if ($proc.ExitCode -eq 0) {
                    # Graft iXML chunk from first part onto merged output. ffmpeg
                    # doesn't preserve iXML natively, so we do it as a post-process.
                    $firstPartFile = $files[0]
                    $ixmlStatus = $null
                    try {
                        $grafted = Copy-WavIxmlChunk -Source $firstPartFile -Destination $outPath
                        $ixmlStatus = if ($grafted) { 'preserved' } else { 'none in source' }
                    }
                    catch {
                        $ixmlStatus = "graft failed: $($_.Exception.Message)"
                    }

                    $sizeMB = [math]::Round((Get-Item $outPath).Length / 1MB, 1)
                    Write-Log "       $charCheck  Done - $sizeMB MB" `
                    ([System.Drawing.Color]::FromArgb(100, 220, 100))

                    # iXML status line (informational, subdued color)
                    if ($ixmlStatus -like 'graft failed*') {
                        Write-Log "          $charDot iXML: $ixmlStatus" `
                        ([System.Drawing.Color]::FromArgb(255, 180, 80))
                    }
                    else {
                        Write-Log "          $charDot iXML: $ixmlStatus" `
                        ([System.Drawing.Color]::FromArgb(120, 120, 120))
                    }

                    $success++
                }
                else {
                    $errText = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
                    Write-Log "       $charCross  ffmpeg failed (exit $($proc.ExitCode))" `
                    ([System.Drawing.Color]::FromArgb(255, 100, 100))
                    Write-Log "          $errText" `
                    ([System.Drawing.Color]::FromArgb(255, 150, 150))
                    $failed++
                }
            }
        }

        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

        Write-Log ''
        Write-Log '─────────────────────────────────────────' `
        ([System.Drawing.Color]::FromArgb(80, 80, 80))

        if ($ScanResult.SkipGroups.Count -gt 0) {
            Write-Log "  Skipped $($ScanResult.SkipGroups.Count) single-part session(s) - originals untouched." `
            ([System.Drawing.Color]::FromArgb(140, 140, 140))
        }
        if ($ScanResult.WarningGroups.Count -gt 0) {
            Write-Log "  Skipped $($ScanResult.WarningGroups.Count) session(s) - date span exceeded threshold." `
            ([System.Drawing.Color]::FromArgb(255, 200, 80))
        }
        if ($failed -eq 0) {
            Write-Log "  All done!  $success track file(s) merged successfully." `
            ([System.Drawing.Color]::FromArgb(100, 220, 100))
        }
        else {
            Write-Log "  Finished with errors:  $success succeeded,  $failed failed." `
            ([System.Drawing.Color]::FromArgb(255, 180, 80))
        }
        Write-Log "  Output: $OutputFolder" `
        ([System.Drawing.Color]::FromArgb(180, 180, 180))
    }

    # ===========================================================================
    # BUILD THE FORM
    # ===========================================================================
    $ACCENT = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $BG = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $PANEL_BG = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $FG = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $SUBTLE = [System.Drawing.Color]::FromArgb(100, 100, 100)
    $WARN = [System.Drawing.Color]::FromArgb(255, 200, 80)
    $OK = [System.Drawing.Color]::FromArgb(100, 220, 100)
    $ERR = [System.Drawing.Color]::FromArgb(255, 100, 100)
    $FONT = [System.Drawing.Font]::new('Segoe UI', 9)
    $FONT_SM = [System.Drawing.Font]::new('Segoe UI', 8)
    $FONT_H = [System.Drawing.Font]::new('Segoe UI Semibold', 9)

    # Unicode symbols for form labels - PS5-safe
    $charArrow = [char]0x25B6   # ▶
    $charWarn = [char]0x26A0   # ⚠
    $charEllip = [char]0x2026   # …

    $script:form = New-Object System.Windows.Forms.Form
    $form = $script:form
    $form.Text = 'Audio Take Merger  -  Zoom F6'
    $form.Size = New-Object System.Drawing.Size(760, 660)
    $form.MinimumSize = New-Object System.Drawing.Size(640, 540)
    $form.BackColor = $BG
    $form.ForeColor = $FG
    $form.Font = $FONT
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'

    # ── Title ────────────────────────────────────────────────────────────────────
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = 'Audio Take Merger  -  Zoom F6'
    $lblTitle.Font = [System.Drawing.Font]::new('Segoe UI Semibold', 13)
    $lblTitle.ForeColor = $FG
    $lblTitle.Location = New-Object System.Drawing.Point(16, 14)
    $lblTitle.Size = New-Object System.Drawing.Size(500, 28)
    $form.Controls.Add($lblTitle)

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = 'Merges split .TAKE sessions into lossless RF64 .WAV files. Originals are never modified.'
    $lblSub.Font = $FONT_SM
    $lblSub.ForeColor = $SUBTLE
    $lblSub.Location = New-Object System.Drawing.Point(18, 42)
    $lblSub.Size = New-Object System.Drawing.Size(720, 16)
    $form.Controls.Add($lblSub)

    $sep1 = New-Object System.Windows.Forms.Panel
    $sep1.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $sep1.Location = New-Object System.Drawing.Point(0, 64)
    $sep1.Size = New-Object System.Drawing.Size(760, 1)
    $form.Controls.Add($sep1)

    # ── Field rows ───────────────────────────────────────────────────────────────
    function New-FieldRow {
        param([string]$LabelText, [int]$Top, [string]$Placeholder, [System.Drawing.Color]$TxtColor)

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $LabelText
        $lbl.Font = $FONT_H
        $lbl.ForeColor = $FG
        $lbl.Location = New-Object System.Drawing.Point(16, $Top)
        $lbl.Size = New-Object System.Drawing.Size(100, 22)
        $form.Controls.Add($lbl)

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Location = New-Object System.Drawing.Point(122, ($Top - 2))
        $txt.Size = New-Object System.Drawing.Size(510, 22)
        $txt.BackColor = $PANEL_BG
        $txt.ForeColor = $TxtColor
        $txt.BorderStyle = 'FixedSingle'
        $txt.Text = $Placeholder
        $txt.Anchor = 'Top,Left,Right'
        $form.Controls.Add($txt)

        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = "Browse$charEllip"
        $btn.Location = New-Object System.Drawing.Point(642, ($Top - 4))
        $btn.Size = New-Object System.Drawing.Size(82, 26)
        $btn.BackColor = $PANEL_BG
        $btn.ForeColor = $FG
        $btn.FlatStyle = 'Flat'
        $btn.Anchor = 'Top,Right'
        $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
        $form.Controls.Add($btn)

        return $txt, $btn
    }

    $PLACEHOLDER_OUT = '(defaults to root folder)'
    $PLACEHOLDER_SUB = '(optional - subfolder within output, e.g. Merged)'
    $PLACEHOLDER_FF = 'ffmpeg  (on PATH - change only if needed)'

    $txtRoot, $btnBrowseRoot = New-FieldRow 'Root folder' 82 '' $SUBTLE
    $txtOut, $btnBrowseOut = New-FieldRow 'Output folder' 116 $PLACEHOLDER_OUT $SUBTLE
    $txtSub, $btnClearSub = New-FieldRow 'Subfolder' 150 $PLACEHOLDER_SUB $SUBTLE
    $txtFf, $btnBrowseFf = New-FieldRow 'ffmpeg path' 184 $PLACEHOLDER_FF $SUBTLE

    $btnClearSub.Text = 'Clear'
    $btnClearSub.ForeColor = $SUBTLE

    $sep2 = New-Object System.Windows.Forms.Panel
    $sep2.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $sep2.Location = New-Object System.Drawing.Point(0, 220)
    $sep2.Size = New-Object System.Drawing.Size(760, 1)
    $form.Controls.Add($sep2)

    # ── Action buttons ───────────────────────────────────────────────────────────
    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = 'Scan Folder'
    $btnScan.Location = New-Object System.Drawing.Point(16, 232)
    $btnScan.Size = New-Object System.Drawing.Size(120, 32)
    $btnScan.BackColor = $PANEL_BG
    $btnScan.ForeColor = $FG
    $btnScan.FlatStyle = 'Flat'
    $btnScan.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $form.Controls.Add($btnScan)

    $btnMerge = New-Object System.Windows.Forms.Button
    $btnMerge.Text = "$charArrow  Run Merge"
    $btnMerge.Location = New-Object System.Drawing.Point(148, 232)
    $btnMerge.Size = New-Object System.Drawing.Size(120, 32)
    $btnMerge.BackColor = $ACCENT
    $btnMerge.ForeColor = [System.Drawing.Color]::White
    $btnMerge.FlatStyle = 'Flat'
    $btnMerge.FlatAppearance.BorderSize = 0
    $btnMerge.Enabled = $false
    $form.Controls.Add($btnMerge)

    $btnClearLog = New-Object System.Windows.Forms.Button
    $btnClearLog.Text = 'Clear Log'
    $btnClearLog.Location = New-Object System.Drawing.Point(280, 232)
    $btnClearLog.Size = New-Object System.Drawing.Size(80, 32)
    $btnClearLog.BackColor = $PANEL_BG
    $btnClearLog.ForeColor = $SUBTLE
    $btnClearLog.FlatStyle = 'Flat'
    $btnClearLog.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $form.Controls.Add($btnClearLog)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = ''
    $lblStatus.Font = $FONT_SM
    $lblStatus.ForeColor = $SUBTLE
    $lblStatus.Location = New-Object System.Drawing.Point(370, 240)
    $lblStatus.Size = New-Object System.Drawing.Size(368, 20)
    $lblStatus.Anchor = 'Top,Right'
    $lblStatus.TextAlign = 'MiddleRight'
    $form.Controls.Add($lblStatus)

    $sep3 = New-Object System.Windows.Forms.Panel
    $sep3.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $sep3.Location = New-Object System.Drawing.Point(0, 274)
    $sep3.Size = New-Object System.Drawing.Size(760, 1)
    $form.Controls.Add($sep3)

    # ── Log ──────────────────────────────────────────────────────────────────────
    $script:rtb = New-Object System.Windows.Forms.RichTextBox
    $rtb = $script:rtb
    $rtb.Location = New-Object System.Drawing.Point(0, 275)
    $rtb.Size = New-Object System.Drawing.Size(760, 348)
    $rtb.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 18)
    $rtb.ForeColor = $FG
    $rtb.Font = [System.Drawing.Font]::new('Cascadia Mono', 8.5)
    $rtb.ReadOnly = $true
    $rtb.BorderStyle = 'None'
    $rtb.ScrollBars = 'Vertical'
    $rtb.WordWrap = $false
    $rtb.Anchor = 'Top,Bottom,Left,Right'
    $form.Controls.Add($rtb)

    foreach ($s in @($sep1, $sep2, $sep3, $lblSub)) { $s.Anchor = 'Top,Left,Right' }

    # ===========================================================================
    # EVENTS
    # ===========================================================================

    $btnBrowseRoot.Add_Click({
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Select the root folder containing your .TAKE directories'
            $dlg.ShowNewFolderButton = $false
            if ($txtRoot.Text -and (Test-Path $txtRoot.Text)) { $dlg.SelectedPath = $txtRoot.Text }
            if ($dlg.ShowDialog() -eq 'OK') {
                $txtRoot.Text = $dlg.SelectedPath
                $txtRoot.ForeColor = $FG
                $btnMerge.Enabled = $false
                $script:scanResult = $null
                $lblStatus.Text = "Click 'Scan Folder' to preview."
                $lblStatus.ForeColor = $SUBTLE
            }
        })

    $btnBrowseOut.Add_Click({
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Select output folder'
            $dlg.ShowNewFolderButton = $true
            if ($txtOut.Text -and (Test-Path $txtOut.Text)) { $dlg.SelectedPath = $txtOut.Text }
            if ($dlg.ShowDialog() -eq 'OK') {
                $txtOut.Text = $dlg.SelectedPath
                $txtOut.ForeColor = $FG
            }
        })

    $btnClearSub.Add_Click({
            $txtSub.Text = ''
            $txtSub.ForeColor = $FG
        })

    $btnBrowseFf.Add_Click({
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title = 'Locate ffmpeg.exe'
            $dlg.Filter = 'ffmpeg.exe|ffmpeg.exe|All executables|*.exe'
            if ($dlg.ShowDialog() -eq 'OK') {
                $txtFf.Text = $dlg.FileName
                $txtFf.ForeColor = $FG
            }
        })

    $btnClearLog.Add_Click({ $rtb.Clear() })

    # ── Scan ─────────────────────────────────────────────────────────────────────
    $btnScan.Add_Click({
            $root = $txtRoot.Text.Trim()

            if (-not $root) {
                Show-Error 'No folder selected' 'Please choose a root folder first.'
                return
            }
            if (-not (Test-Path $root -PathType Container)) {
                Show-Error 'Folder not found' "The path does not exist:`n`n$root"
                return
            }

            $ffPath = $txtFf.Text.Trim()
            if ($ffPath -eq $PLACEHOLDER_FF -or -not $ffPath) { $ffPath = 'ffmpeg' }

            if (-not (Test-Ffmpeg $ffPath)) {
                Show-Error 'ffmpeg not found' (
                    "Cannot locate ffmpeg at '$ffPath'.`n`n" +
                    "Install it with:  winget install ffmpeg`n" +
                    'Or use the Browse button to locate ffmpeg.exe manually.'
                )
                return
            }

            $rtb.Clear()
            Write-Log "Scanning: $root" $SUBTLE

            $result = Get-SessionGroups -Root $root

            if ($result -eq 'NO_TAKES') {
                $btnMerge.Enabled = $false
                $script:scanResult = $null
                $lblStatus.Text = 'No .TAKE folders found.'
                $lblStatus.ForeColor = $ERR
                Show-Error 'No .TAKE folders found' (
                    "No directories ending in .TAKE were found in:`n`n$root`n`n" +
                    "Expected folder names:`n" +
                    "  YYMMDD_SSS.TAKE          (single part)`n" +
                    "  YYMMDD_SSS_PPPP.TAKE     (split part)`n`n" +
                    "Example:`n" +
                    "  251031_001.TAKE`n" +
                    "  251031_002_0001.TAKE`n" +
                    '  251031_002_0002.TAKE'
                )
                return
            }

            if ($result -eq 'NO_MATCHES') {
                $btnMerge.Enabled = $false
                $script:scanResult = $null
                $lblStatus.Text = 'No recognizable session folders found.'
                $lblStatus.ForeColor = $ERR
                Show-Error 'No matching folders' (
                    "Found .TAKE folders but none matched the expected Zoom F6 naming pattern.`n`n" +
                    'Expected:  YYMMDD_SSS.TAKE  or  YYMMDD_SSS_PPPP.TAKE'
                )
                return
            }

            # Unparseable folders
            if ($result.Unparsed.Count -gt 0) {
                Write-Log ''
                Write-Log "$charWarn  Folders with unrecognized names (ignored):" $WARN
                foreach ($u in $result.Unparsed) {
                    Write-Log "     $u" ([System.Drawing.Color]::FromArgb(180, 140, 40))
                }
            }

            # Skipped single-part sessions
            if ($result.SkipGroups.Count -gt 0) {
                Write-Log ''
                Write-Log '  Single-part sessions - no merge needed:' $SUBTLE
                foreach ($sg in $result.SkipGroups) {
                    Write-Log "     Session $($sg.Session)  -  $($sg.Parts[0].FolderName)" `
                    ([System.Drawing.Color]::FromArgb(80, 80, 80))
                }
            }

            # Warning groups (date span too large)
            if ($result.WarningGroups.Count -gt 0) {
                Write-Log ''
                Write-Log "$charWarn  Sessions skipped - date span exceeds 1-day threshold:" $WARN
                foreach ($wg in $result.WarningGroups) {
                    Write-Log "     Session $($wg.Session)  ($($wg.MinDate) to $($wg.MaxDate) - $($wg.DaySpan) days)" $WARN
                    foreach ($p in $wg.Parts) {
                        Write-Log "       $($p.FolderName)" ([System.Drawing.Color]::FromArgb(160, 120, 40))
                    }
                    Write-Log '     Please verify these parts belong together before merging manually.' `
                    ([System.Drawing.Color]::FromArgb(160, 120, 40))
                }
            }

            # Nothing to merge
            if ($result.MergeGroups.Count -eq 0) {
                $btnMerge.Enabled = $false
                $script:scanResult = $null
                $lblStatus.Text = 'Nothing to merge.'
                $lblStatus.ForeColor = $SUBTLE
                Write-Log ''
                Write-Log '  No sessions require merging.' $SUBTLE
                return
            }

            # Merge preview
            Write-Log ''
            Write-Log '  Sessions to merge:' $FG

            foreach ($mg in $result.MergeGroups) {
                Write-Log ''
                $crossNote = if ($mg.CrossDate) { "  $charWarn cross-date (within threshold)" } else { '' }
                Write-Log "  Session $($mg.Session)  ($($mg.Parts.Count) parts)$crossNote" `
                ([System.Drawing.Color]::FromArgb(100, 180, 255))

                foreach ($part in $mg.Parts) {
                    Write-Log "     $($part.FolderName)" ([System.Drawing.Color]::FromArgb(100, 100, 100))
                }
                foreach ($trk in ($mg.TrackLists.Keys | Sort-Object)) {
                    $outName = "$($mg.LatestDate)_$($mg.Session)_${trk}.WAV"
                    Write-Log "     -> $outName  ($($mg.TrackLists[$trk].Count) file(s))" `
                    ([System.Drawing.Color]::FromArgb(160, 160, 160))
                }
            }

            $script:scanResult = $result
            $btnMerge.Enabled = $true
            $totalTracks = ($result.MergeGroups |
                    ForEach-Object { $_.TrackLists.Count } |
                    Measure-Object -Sum).Sum
            $lblStatus.Text = "$($result.MergeGroups.Count) session(s), $totalTracks track file(s) ready."
            $lblStatus.ForeColor = $OK
        })

    # ── Merge ────────────────────────────────────────────────────────────────────
    $btnMerge.Add_Click({
            if (-not $script:scanResult) { return }

            $root = $txtRoot.Text.Trim()
            $ffPath = $txtFf.Text.Trim()
            if ($ffPath -eq $PLACEHOLDER_FF -or -not $ffPath) { $ffPath = 'ffmpeg' }

            # Resolve output folder
            $outFolder = $txtOut.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($outFolder) -or $outFolder -eq $PLACEHOLDER_OUT) {
                $outFolder = $root
            }

            $sub = $txtSub.Text.Trim()
            if (-not [string]::IsNullOrWhiteSpace($sub) -and $sub -ne $PLACEHOLDER_SUB) {
                $outFolder = Join-Path $outFolder $sub
            }

            if (-not (Test-Path $outFolder)) {
                try { New-Item -ItemType Directory -Path $outFolder | Out-Null }
                catch { Show-Error 'Cannot create output folder' $_; return }
            }

            $totalTracks = ($script:scanResult.MergeGroups |
                    ForEach-Object { $_.TrackLists.Count } |
                    Measure-Object -Sum).Sum

            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "Merge $($script:scanResult.MergeGroups.Count) session(s) / $totalTracks track file(s) into:`n`n" +
                "$outFolder`n`nOriginals will not be modified. Proceed?",
                'Confirm Merge',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($confirm -ne 'Yes') { return }

            $btnScan.Enabled = $false
            $btnMerge.Enabled = $false
            $btnBrowseRoot.Enabled = $false
            $lblStatus.Text = 'Running...'
            $lblStatus.ForeColor = $WARN

            $rtb.AppendText("`n")
            Write-Log '─────────────────────────────────────────' `
            ([System.Drawing.Color]::FromArgb(60, 60, 60))
            Write-Log "  Starting merge -> $outFolder" $SUBTLE

            Start-Merge -OutputFolder $outFolder `
                -ScanResult $script:scanResult `
                -FfmpegPath $ffPath

            $btnScan.Enabled = $true
            $btnMerge.Enabled = $true
            $btnBrowseRoot.Enabled = $true
            $lblStatus.Text = 'Finished.'
            $lblStatus.ForeColor = $OK
        })

    # ── Resize ───────────────────────────────────────────────────────────────────
    $form.Add_Resize({
            $w = $form.ClientSize.Width
            foreach ($s in @($sep1, $sep2, $sep3)) { $s.Width = $w }
            $rtb.Width = $w
        })

    # ===========================================================================
    # LAUNCH
    # ===========================================================================
    [System.Windows.Forms.Application]::EnableVisualStyles()

    Write-Log 'Zoom F6 Audio Take Merger  -  ready.' $SUBTLE
    Write-Log '1. Browse to your root recording folder.  2. Scan.  3. Run Merge.' `
    ([System.Drawing.Color]::FromArgb(70, 70, 70))

    [void]$form.ShowDialog()
}


# ══════════════════════════════════════════════════════════════════════════════
# EXPORTS
# ══════════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function 'Merge-AudioTakes'