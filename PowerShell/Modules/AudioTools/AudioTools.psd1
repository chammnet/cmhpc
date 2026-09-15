@{
    RootModule        = 'AudioTools.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = 'C72CF190-2956-4C6F-A892-C24A31402CAF'
    Author            = 'Craig Hamm'
    Description       = 'Audio tools for field recording workflows. Merges split Zoom F6 .TAKE WAV files into single RF64 .WAV files via ffmpeg.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Merge-AudioTakes')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('Audio', 'WAV', 'Zoom', 'ffmpeg', 'Recording')
        }
    }
}
