<#
.SYNOPSIS
    CMHSystemTools - System administration utilities.

.DESCRIPTION
    Provides system diagnostics and administration tools:

        Get-FileLockProcess  Find which process(es) are locking a file (Windows & Linux)
        Get-MemoryUsage      Display physical memory usage with status (OK/Warning/Critical)
        Get-Uptime           Report system uptime and memory for local or remote computers

.NOTES
    Author   : Craig Hamm
    Version  : 1.0.0
    Requires : PowerShell 5.1 or later
               Get-FileLockProcess requires Windows Restart Manager API (Windows only for full functionality)
               Get-Uptime remote support requires PowerShell Remoting on target computers
#>


# ══════════════════════════════════════════════════════════════════════════════
# PUBLIC: Get-FileLockProcess
# ══════════════════════════════════════════════════════════════════════════════

function Get-FileLockProcess {
    <#
    .SYNOPSIS
        Check which process is locking a file.

    .DESCRIPTION
        On Windows, returns a List of System.Diagnostics.Process objects for
        each process holding a lock on the specified file, using the Windows
        Restart Manager API.

        On Linux/macOS, returns a PSCustomObject with equivalent properties
        via lsof.

    .PARAMETER FilePath
        Full path to the file to check. Mandatory. Accepts pipeline input.

    .EXAMPLE
        Get-FileLockProcess -FilePath "C:\Users\craig\Downloads\report.xlsx"
        Returns the process (e.g. EXCEL) that is locking the file.

    .EXAMPLE
        "C:\locked.log" | Get-FileLockProcess
        Pipeline usage.

    .NOTES
        Windows solution credit: https://stackoverflow.com/a/20623311
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True, ValueFromPipeline)]
        $FilePath
    )

    foreach ($FileName in $FilePath) {

        if (! $(Test-Path $FileName)) {
            Write-Error "The path $FileName was not found! Halting!"
            $global:FunctionResult = '1'
            return
        }

        if ($PSVersionTable.PSEdition -eq 'Desktop' -or $PSVersionTable.Platform -eq 'Win32NT' -or
            $($PSVersionTable.PSVersion.Major -le 5 -and $PSVersionTable.PSVersion.Major -ge 3)) {
            $CurrentlyLoadedAssemblies = [System.AppDomain]::CurrentDomain.GetAssemblies()

            $AssembliesFullInfo = $CurrentlyLoadedAssemblies | Where-Object {
                $_.GetName().Name -eq 'Microsoft.CSharp' -or
                $_.GetName().Name -eq 'mscorlib' -or
                $_.GetName().Name -eq 'System' -or
                $_.GetName().Name -eq 'System.Collections' -or
                $_.GetName().Name -eq 'System.Core' -or
                $_.GetName().Name -eq 'System.IO' -or
                $_.GetName().Name -eq 'System.Linq' -or
                $_.GetName().Name -eq 'System.Runtime' -or
                $_.GetName().Name -eq 'System.Runtime.Extensions' -or
                $_.GetName().Name -eq 'System.Runtime.InteropServices'
            }
            $AssembliesFullInfo = $AssembliesFullInfo | Where-Object { $_.IsDynamic -eq $False }

            $ReferencedAssemblies = $AssembliesFullInfo.FullName | Sort-Object | Get-Unique

            $usingStatementsAsString = @'
        using Microsoft.CSharp;
        using System.Collections.Generic;
        using System.Collections;
        using System.IO;
        using System.Linq;
        using System.Runtime.InteropServices;
        using System.Runtime;
        using System;
        using System.Diagnostics;
'@

            $TypeDefinition = @"
        $usingStatementsAsString

        namespace MyCore.Utils
        {
            static public class FileLockUtil
            {
                [StructLayout(LayoutKind.Sequential)]
                struct RM_UNIQUE_PROCESS
                {
                    public int dwProcessId;
                    public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
                }

                const int RmRebootReasonNone = 0;
                const int CCH_RM_MAX_APP_NAME = 255;
                const int CCH_RM_MAX_SVC_NAME = 63;

                enum RM_APP_TYPE
                {
                    RmUnknownApp = 0,
                    RmMainWindow = 1,
                    RmOtherWindow = 2,
                    RmService = 3,
                    RmExplorer = 4,
                    RmConsole = 5,
                    RmCritical = 1000
                }

                [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
                struct RM_PROCESS_INFO
                {
                    public RM_UNIQUE_PROCESS Process;

                    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)]
                    public string strAppName;

                    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)]
                    public string strServiceShortName;

                    public RM_APP_TYPE ApplicationType;
                    public uint AppStatus;
                    public uint TSSessionId;
                    [MarshalAs(UnmanagedType.Bool)]
                    public bool bRestartable;
                }

                [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
                static extern int RmRegisterResources(uint pSessionHandle,
                                                    UInt32 nFiles,
                                                    string[] rgsFilenames,
                                                    UInt32 nApplications,
                                                    [In] RM_UNIQUE_PROCESS[] rgApplications,
                                                    UInt32 nServices,
                                                    string[] rgsServiceNames);

                [DllImport("rstrtmgr.dll", CharSet = CharSet.Auto)]
                static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

                [DllImport("rstrtmgr.dll")]
                static extern int RmEndSession(uint pSessionHandle);

                [DllImport("rstrtmgr.dll")]
                static extern int RmGetList(uint dwSessionHandle,
                                            out uint pnProcInfoNeeded,
                                            ref uint pnProcInfo,
                                            [In, Out] RM_PROCESS_INFO[] rgAffectedApps,
                                            ref uint lpdwRebootReasons);

                static public List<Process> WhoIsLocking(string path)
                {
                    uint handle;
                    string key = Guid.NewGuid().ToString();
                    List<Process> processes = new List<Process>();

                    int res = RmStartSession(out handle, 0, key);
                    if (res != 0) throw new Exception("Could not begin restart session.  Unable to determine file locker.");

                    try
                    {
                        const int ERROR_MORE_DATA = 234;
                        uint pnProcInfoNeeded = 0,
                            pnProcInfo = 0,
                            lpdwRebootReasons = RmRebootReasonNone;

                        string[] resources = new string[] { path };

                        res = RmRegisterResources(handle, (uint)resources.Length, resources, 0, null, 0, null);

                        if (res != 0) throw new Exception("Could not register resource.");

                        res = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, null, ref lpdwRebootReasons);

                        if (res == ERROR_MORE_DATA)
                        {
                            RM_PROCESS_INFO[] processInfo = new RM_PROCESS_INFO[pnProcInfoNeeded];
                            pnProcInfo = pnProcInfoNeeded;

                            res = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, processInfo, ref lpdwRebootReasons);
                            if (res == 0)
                            {
                                processes = new List<Process>((int)pnProcInfo);

                                for (int i = 0; i < pnProcInfo; i++)
                                {
                                    try
                                    {
                                        processes.Add(Process.GetProcessById(processInfo[i].Process.dwProcessId));
                                    }
                                    catch (ArgumentException) { }
                                }
                            }
                            else throw new Exception("Could not list processes locking resource.");
                        }
                        else if (res != 0) throw new Exception("Could not list processes locking resource. Failed to get size of result.");
                    }
                    finally
                    {
                        RmEndSession(handle);
                    }

                    return processes;
                }
            }
        }
"@

            $CheckMyCoreUtilsFileLockUtilLoaded = $CurrentlyLoadedAssemblies | Where-Object { $_.ExportedTypes -like 'MyCore.Utils.FileLockUtil*' }
            if ($CheckMyCoreUtilsFileLockUtilLoaded.Count -eq 0) {
                Add-Type -ReferencedAssemblies $ReferencedAssemblies -TypeDefinition $TypeDefinition
            }
            else {
                Write-Verbose 'The Namespace MyCore.Utils Class FileLockUtil is already loaded and available!'
            }

            $Result = [MyCore.Utils.FileLockUtil]::WhoIsLocking($FileName)
        }

        if ($null -ne $PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
            $lsofOutput = lsof $FileName

            function ConvertFrom-lsofStrings ($lsofOutput, $Index) {
                $($lsofOutput[$Index] -split ' ' | ForEach-Object {
                        if (![String]::IsNullOrWhiteSpace($_)) {
                            $_
                        }
                    }).Trim()
            }

            $lsofOutputHeaders = ConvertFrom-lsofStrings -lsofOutput $lsofOutput -Index 0
            $lsofOutputValues = ConvertFrom-lsofStrings -lsofOutput $lsofOutput -Index 1

            $Result = [pscustomobject]@{}
            for ($i = 0; $i -lt $lsofOutputHeaders.Count; $i++) {
                $Result | Add-Member -MemberType NoteProperty -Name $lsofOutputHeaders[$i] -Value $lsofOutputValues[$i]
            }
        }

        $Result
    }
}


# ══════════════════════════════════════════════════════════════════════════════
# PRIVATE: Test-MemoryUsage (helper for Get-MemoryUsage)
# ══════════════════════════════════════════════════════════════════════════════

function Test-MemoryUsage {
    [CmdletBinding()]
    param()

    $os = Get-CimInstance Win32_OperatingSystem
    $pctFree = [math]::Round(($os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 2)

    if ($pctFree -ge 45) {
        $Status = 'OK'
    }
    elseif ($pctFree -ge 15) {
        $Status = 'Warning'
    }
    else {
        $Status = 'Critical'
    }

    $os | Select-Object @{Name = 'Status'; Expression = { $Status } },
    @{Name = 'PctFree'; Expression = { $pctFree } },
    @{Name = 'FreeGB'; Expression = { [math]::Round($_.FreePhysicalMemory / 1mb, 2) } },
    @{Name = 'TotalGB'; Expression = { [int]($_.TotalVisibleMemorySize / 1mb) } }
}


# ══════════════════════════════════════════════════════════════════════════════
# PUBLIC: Get-MemoryUsage
# ══════════════════════════════════════════════════════════════════════════════

function Get-MemoryUsage {
    <#
    .SYNOPSIS
        Displays physical memory usage with a status indicator.

    .DESCRIPTION
        Reports total RAM, free RAM, and percentage free. Status is color-coded:
            Green  (OK)       - 45% or more free
            Yellow (Warning)  - 15-44% free
            Red    (Critical) - less than 15% free

    .EXAMPLE
        Get-MemoryUsage
        Displays the memory report for the local computer.

    .EXAMPLE
        gmu
        Short alias for Get-MemoryUsage.
    #>
    [CmdletBinding()]
    param()

    $data = Test-MemoryUsage

    switch ($data.Status) {
        'OK' { $color = 'Green' }
        'Warning' { $color = 'Yellow' }
        'Critical' { $color = 'Red' }
    }

    $title = @'

Memory Check
------------
'@
    Write-Host $title -ForegroundColor Cyan
    $data | Format-Table -AutoSize | Out-String | Write-Host -ForegroundColor $color
}

Set-Alias -Name gmu -Value Get-MemoryUsage


# ══════════════════════════════════════════════════════════════════════════════
# PUBLIC: Get-Uptime
# ══════════════════════════════════════════════════════════════════════════════

function Get-Uptime {
    <#
    .SYNOPSIS
        Reports system uptime and memory for local or remote computers.

    .DESCRIPTION
        Returns boot time, uptime duration, total RAM, free RAM, and percent
        free for the local computer or one or more remote computers via
        PowerShell Remoting.

    .PARAMETER ComputerName
        One or more remote computer names. Omit for the local computer.
        Accepts pipeline input.

    .PARAMETER Credential
        Credentials for remote connections. If ComputerName is specified and
        Credential is omitted, you will be prompted.

    .EXAMPLE
        Get-Uptime
        Reports uptime for the local computer.

    .EXAMPLE
        Get-Uptime -ComputerName Server01, Server02
        Reports uptime for two remote computers (will prompt for credentials).

    .EXAMPLE
        'Server01', 'Server02' | Get-Uptime -Credential (Get-Credential)
        Pipeline usage with pre-supplied credentials.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Name')]
        [string[]]$ComputerName,
        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential
    )

    begin {
        if (-not $Credential -and $ComputerName) {
            $Credential = Get-Credential
        }

        $scriptBlock = {
            $os = Get-CimInstance Win32_OperatingSystem
            $uptime = (Get-Date) - $os.LastBootUpTime

            [PSCustomObject]@{
                ComputerName = $env:COMPUTERNAME
                OS           = $os.Caption
                BootTime     = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')
                Uptime       = '{0}d {1}h {2}m {3}s' -f $uptime.Days, $uptime.Hours, $uptime.Minutes, $uptime.Seconds
                Memory       = [string]::Format('{0} GB', [math]::Round($os.TotalVisibleMemorySize / 1MB, 1))
                FreeMemory   = [string]::Format('{0} GB', [math]::Round($os.FreePhysicalMemory / 1MB, 1))
                PercentFree  = [string]::Format('{0}%', [math]::Round(($os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 1))
            }
        }
    }

    process {
        if (-not $ComputerName) {
            & $scriptBlock
        }
        else {
            $invokeParams = @{
                ComputerName = $ComputerName
                ScriptBlock  = $scriptBlock
                ErrorAction  = 'Stop'
            }
            if ($Credential) { $invokeParams['Credential'] = $Credential }

            try {
                Invoke-Command @invokeParams |
                    Select-Object ComputerName, OS, BootTime, Uptime, Memory, FreeMemory, PercentFree
            }
            catch {
                Write-Warning "$($_.Exception.Message)"
            }
        }
    }

    end {}
}

# ══════════════════════════════════════════════════════════════════════════════
# PUBLIC: Get-ListeningPortService
# ══════════════════════════════════════════════════════════════════════════════
function Get-ListeningPortService {
    <#
    .SYNOPSIS
        Lists listening TCP ports with their owning process and Windows service name.
    .PARAMETER Name
        Optional. Filter by process/image name (wildcards ok, e.g. "*PIDFLO*").
    .PARAMETER Port
        Optional. Filter to a specific local port.
    .EXAMPLE
        Get-ListeningPortService
    .EXAMPLE
        Get-ListeningPortService -Name DDTI.PIDFLO.Service
    .EXAMPLE
        Get-ListeningPortService -Port 8080
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Alias('ImageName')]
        [string]$Name,

        [Parameter()]
        [int]$Port
    )

    $connections = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Select-Object -Unique LocalPort, OwningProcess

    if ($Port) {
        $connections = $connections | Where-Object LocalPort -EQ $Port
    }

    if ($Name) {
        $matchingIds = (Get-Process -Name $Name -ErrorAction SilentlyContinue).Id
        $connections = $connections | Where-Object { $_.OwningProcess -in $matchingIds }
    }

    $connections | ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        $svc = Get-CimInstance Win32_Service -Filter "ProcessId=$($_.OwningProcess)" -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Port        = $_.LocalPort
            PID         = $_.OwningProcess
            ProcessName = $proc.ProcessName
            ServiceName = ($svc.Name -join ', ')
        }
    } | Sort-Object Port
}

# ══════════════════════════════════════════════════════════════════════════════
# EXPORTS
# ══════════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function 'Get-FileLockProcess', 'Get-MemoryUsage', 'Get-Uptime' `
    -Alias 'gmu'
