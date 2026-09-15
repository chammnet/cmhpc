@{
    RootModule        = 'CMHSystemTools.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'FD61C411-800F-4A65-84AD-4A412CC3FC31'
    Author            = 'Craig Hamm'
    Description       = 'System administration utilities: file lock detection, memory usage, and uptime reporting.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-FileLockProcess', 'Get-MemoryUsage', 'Get-Uptime')
    CmdletsToExport   = @()
    AliasesToExport   = @('gmu')
    VariablesToExport = @()
    PrivateData       = @{
        PSData = @{
            Tags = @('System', 'Diagnostics', 'Memory', 'Uptime', 'FileLock')
        }
    }
}
