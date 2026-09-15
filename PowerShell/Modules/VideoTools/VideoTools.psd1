#
# Module manifest for VideoTools
#
# Author : Craig Hamm
# Created: 2026-05-13
#

@{
    # Module file
    RootModule        = 'VideoTools.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b3f2d8a1-4c7e-4f9b-a021-6d3e5f1c8b47'

    Author            = 'Craig Hamm'
    CompanyName       = 'CMH Computer Services, LLC'
    Copyright         = '(c) 2026 Craig Hamm. All rights reserved.'

    Description       = 'Video tools for field recording post-production workflows.'

    PowerShellVersion = '5.1'

    # External tools required at runtime (not enforced by PS, but documented here)
    # - ffmpeg   (winget install ffmpeg)
    # - ffprobe  (included with ffmpeg)

    FunctionsToExport = @(
        'Repair-VideoTimecode'
    )

    AliasesToExport   = @()
    CmdletsToExport   = @()
    VariablesToExport = @()

    PrivateData       = @{
        PSData = @{
            Tags         = @('ffmpeg', 'timecode', 'video', 'DaVinci Resolve', 'field recording')
            ProjectUri   = ''
            ReleaseNotes = @'
1.0.0 - 2026-05-13
    Initial release.
    Repair-VideoTimecode: copies TC from timed metadata stream into video
    stream and strips camera audio. Designed for Tentacle Timecode Tool
    exports used in Zoom F6 / Sony Alpha sync workflows.
'@
        }
    }
}