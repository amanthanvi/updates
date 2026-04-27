Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TestCount = 0
$script:FailureCount = 0
$script:WindowsTestHelpersRoot = $PSScriptRoot

function New-TestRoot {
    param(
        [string]$Prefix = 'updates-windows-test'
    )

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('{0}-{1}' -f $Prefix, [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $root -Force
    return $root
}

function Remove-TestRoot {
    param(
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $dir = Split-Path -Parent $Path
    if ($dir) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-CmdStub {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    $bodyLines = @()
    if ($null -ne $Lines) {
        $bodyLines = @($Lines)
    }
    $content = "@echo off`r`nsetlocal EnableExtensions`r`n" + (($bodyLines + 'exit /b 0') -join "`r`n") + "`r`n"
    Write-Utf8NoBom -Path $Path -Content $content
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $Data
    )

    $json = $Data | ConvertTo-Json -Depth 10
    Write-Utf8NoBom -Path $Path -Content $json
}

function Quote-PowerShellLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return "'" + ($Value -replace "'", "''") + "'"
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        $Expected,
        [Parameter(Mandatory = $true)]
        $Actual,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Expected -cne $Actual) {
        throw "{0}`nExpected: {1}`nActual:   {2}" -f $Message, $Expected, $Actual
    }
}

function Assert-Match {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Text -notmatch $Pattern) {
        throw "{0}`nPattern: {1}`nText:`n{2}" -f $Message, $Pattern, $Text
    }
}

function Assert-FileExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "{0}: {1}" -f $Message, $Path
    }
}

function Get-PwshPath {
    $candidate = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    $command = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw 'pwsh is required to run Windows-native tests.'
}

function Get-CmdPath {
    $candidate = Join-Path $env:SystemRoot 'System32\cmd.exe'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw 'cmd.exe is required to run Windows-native tests.'
    }

    return $candidate
}

function Ensure-ConsoleSignalTestSupport {
    if ('UpdatesWindowsSignalTestSupport' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class UpdatesWindowsSpawnedProcess
{
    public IntPtr ProcessHandle { get; set; }
    public int ProcessId { get; set; }
}

public static class UpdatesWindowsSignalTestSupport
{
    private const uint CTRL_C_EVENT = 0;
    private const uint CTRL_BREAK_EVENT = 1;
    private const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_TIMEOUT = 0x00000102;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(
        string lpApplicationName,
        string lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr handle, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr handle, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(IntPtr handlerRoutine, bool add);

    private static string QuoteArgument(string arg)
    {
        if (string.IsNullOrEmpty(arg))
        {
            return "\"\"";
        }

        bool needsQuotes = arg.IndexOfAny(new[] { ' ', '\t', '"' }) >= 0;
        if (!needsQuotes)
        {
            return arg;
        }

        var sb = new StringBuilder();
        sb.Append('"');
        int backslashCount = 0;

        foreach (char c in arg)
        {
            if (c == '\\')
            {
                backslashCount++;
                continue;
            }

            if (c == '"')
            {
                sb.Append('\\', backslashCount * 2 + 1);
                sb.Append('"');
                backslashCount = 0;
                continue;
            }

            if (backslashCount > 0)
            {
                sb.Append('\\', backslashCount);
                backslashCount = 0;
            }

            sb.Append(c);
        }

        if (backslashCount > 0)
        {
            sb.Append('\\', backslashCount * 2);
        }

        sb.Append('"');
        return sb.ToString();
    }

    private static string BuildCommandLine(string applicationPath, string[] arguments)
    {
        var sb = new StringBuilder();
        sb.Append(QuoteArgument(applicationPath));
        if (arguments != null)
        {
            foreach (string arg in arguments)
            {
                sb.Append(' ');
                sb.Append(QuoteArgument(arg ?? string.Empty));
            }
        }
        return sb.ToString();
    }

    public static UpdatesWindowsSpawnedProcess StartInNewProcessGroup(string applicationPath, string workingDirectory, string[] arguments)
    {
        STARTUPINFO startupInfo = new STARTUPINFO();
        startupInfo.cb = Marshal.SizeOf<STARTUPINFO>();
        PROCESS_INFORMATION processInformation;
        string commandLine = BuildCommandLine(applicationPath, arguments);

        bool ok = CreateProcessW(
            null,
            commandLine,
            IntPtr.Zero,
            IntPtr.Zero,
            false,
            CREATE_NEW_PROCESS_GROUP,
            IntPtr.Zero,
            workingDirectory,
            ref startupInfo,
            out processInformation);

        if (!ok)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        try
        {
            return new UpdatesWindowsSpawnedProcess
            {
                ProcessHandle = processInformation.hProcess,
                ProcessId = processInformation.dwProcessId
            };
        }
        finally
        {
            if (processInformation.hThread != IntPtr.Zero)
            {
                CloseHandle(processInformation.hThread);
            }
        }
    }

    public static bool WaitForExit(UpdatesWindowsSpawnedProcess process, int timeoutMs)
    {
        if (process == null || process.ProcessHandle == IntPtr.Zero)
        {
            throw new InvalidOperationException("Process handle is not available.");
        }

        uint waitResult = WaitForSingleObject(process.ProcessHandle, unchecked((uint)timeoutMs));
        if (waitResult == WAIT_OBJECT_0)
        {
            return true;
        }
        if (waitResult == WAIT_TIMEOUT)
        {
            return false;
        }

        throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public static int GetExitCode(UpdatesWindowsSpawnedProcess process)
    {
        if (process == null || process.ProcessHandle == IntPtr.Zero)
        {
            throw new InvalidOperationException("Process handle is not available.");
        }

        uint exitCode;
        if (!GetExitCodeProcess(process.ProcessHandle, out exitCode))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        return unchecked((int)exitCode);
    }

    public static void Kill(UpdatesWindowsSpawnedProcess process)
    {
        if (process == null || process.ProcessHandle == IntPtr.Zero)
        {
            return;
        }

        if (!TerminateProcess(process.ProcessHandle, 1))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void Close(UpdatesWindowsSpawnedProcess process)
    {
        if (process == null || process.ProcessHandle == IntPtr.Zero)
        {
            return;
        }

        IntPtr handle = process.ProcessHandle;
        process.ProcessHandle = IntPtr.Zero;
        CloseHandle(handle);
    }

    public static void SendCtrlC()
    {
        if (!GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void SendCtrlBreak(int processGroupId)
    {
        if (!GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, (uint)processGroupId))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void SetIgnoreCtrlC(bool ignore)
    {
        if (!SetConsoleCtrlHandler(IntPtr.Zero, ignore))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@
}

function Start-ProcessInstance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [hashtable]$Environment = @{}
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false

    foreach ($arg in $ArgumentList) {
        $null = $psi.ArgumentList.Add($arg)
    }

    foreach ($entry in $Environment.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            $null = $psi.Environment.Remove([string]$entry.Key)
            continue
        }

        $psi.Environment[[string]$entry.Key] = [string]$entry.Value
    }

    return [System.Diagnostics.Process]::Start($psi)
}

function Invoke-ProcessCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [hashtable]$Environment = @{}
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    foreach ($arg in $ArgumentList) {
        $null = $psi.ArgumentList.Add($arg)
    }

    foreach ($entry in $Environment.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            $null = $psi.Environment.Remove([string]$entry.Key)
            continue
        }

        $psi.Environment[[string]$entry.Key] = [string]$entry.Value
    }

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
        Output   = $stdout + $stderr
    }
}

function Invoke-CmdScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [hashtable]$Environment = @{}
    )

    return Invoke-ProcessCapture `
        -FilePath (Get-CmdPath) `
        -ArgumentList (@('/d', '/c', 'call', $ScriptPath) + $ArgumentList) `
        -WorkingDirectory $WorkingDirectory `
        -Environment $Environment
}

function Copy-RequiredFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $true)]
        [string]$MissingMessage
    )

    Assert-FileExists -Path $SourcePath -Message $MissingMessage
    $dir = Split-Path -Parent $DestinationPath
    if ($dir) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
}

function Copy-RepoWindowsCmd {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    Copy-RequiredFile `
        -SourcePath (Join-Path $RepoRoot 'updates.cmd') `
        -DestinationPath (Join-Path $InstallRoot 'updates.cmd') `
        -MissingMessage 'Missing native Windows launcher'
}

function Copy-RepoWindowsBootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    Copy-RequiredFile `
        -SourcePath (Join-Path $RepoRoot 'updates.ps1') `
        -DestinationPath (Join-Path $InstallRoot 'updates.ps1') `
        -MissingMessage 'Missing native Windows bootstrap'
}

function Resolve-RepoWindowsPayloadSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $candidates = @()
    if ($env:UPDATES_WINDOWS_PAYLOAD_UNDER_TEST) {
        $candidates += $env:UPDATES_WINDOWS_PAYLOAD_UNDER_TEST
    }
    $candidates += (Join-Path $RepoRoot 'updates-main.ps1')

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'Missing Windows payload source. Set UPDATES_WINDOWS_PAYLOAD_UNDER_TEST or add updates-main.ps1.'
}

function Install-RepoWindowsRuntime {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [string]$Version = '2.0.0',
        [switch]$WithReceipt
    )

    Copy-RepoWindowsCmd -RepoRoot $RepoRoot -InstallRoot $InstallRoot
    Copy-RepoWindowsBootstrap -RepoRoot $RepoRoot -InstallRoot $InstallRoot
    New-VersionedPayload -InstallRoot $InstallRoot -Version $Version -PayloadPath (Resolve-RepoWindowsPayloadSource -RepoRoot $RepoRoot)
    Set-VersionPointers -InstallRoot $InstallRoot -CurrentVersion $Version
    if ($WithReceipt) {
        Write-InstallReceipt -InstallRoot $InstallRoot -InstalledVersion $Version
    } else {
        $receiptPath = Join-Path $InstallRoot 'install-source.json'
        if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
            Remove-Item -LiteralPath $receiptPath -Force
        }
    }
}

function New-VersionedPayload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [string]$PayloadPath,
        [string]$PayloadContent,
        [string]$EntryScript = 'updates-main.ps1',
        [int]$BootstrapMin = 1
    )

    $versionRoot = Join-Path $InstallRoot (Join-Path 'versions' $Version)
    $null = New-Item -ItemType Directory -Path $versionRoot -Force

    $manifest = [ordered]@{
        version       = $Version
        bootstrap_min = $BootstrapMin
        entry_script  = $EntryScript
    }
    Write-JsonFile -Path (Join-Path $versionRoot 'manifest.json') -Data $manifest

    if ($PayloadPath) {
        Copy-Item -LiteralPath $PayloadPath -Destination (Join-Path $versionRoot $EntryScript) -Force
    } elseif ($null -ne $PayloadContent) {
        Write-Utf8NoBom -Path (Join-Path $versionRoot $EntryScript) -Content $PayloadContent
    }
}

function Set-VersionPointers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [Parameter(Mandatory = $true)]
        [string]$CurrentVersion,
        [string]$PreviousVersion
    )

    Write-Utf8NoBom -Path (Join-Path $InstallRoot 'current.txt') -Content ($CurrentVersion + "`n")
    if ($PreviousVersion) {
        Write-Utf8NoBom -Path (Join-Path $InstallRoot 'previous.txt') -Content ($PreviousVersion + "`n")
    } else {
        $previousPath = Join-Path $InstallRoot 'previous.txt'
        if (Test-Path -LiteralPath $previousPath -PathType Leaf) {
            Remove-Item -LiteralPath $previousPath -Force
        }
    }
}

function Write-InstallReceipt {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [Parameter(Mandatory = $true)]
        [string]$InstalledVersion,
        [string]$SourceRepo = 'amanthanvi/updates',
        [string]$Kind = 'standalone',
        [string]$Channel = 'github-release',
        [string]$Scope = 'user'
    )

    $receipt = [ordered]@{
        kind              = $Kind
        channel           = $Channel
        source_repo       = $SourceRepo
        scope             = $Scope
        installed_version = $InstalledVersion
    }
    Write-JsonFile -Path (Join-Path $InstallRoot 'install-source.json') -Data $receipt
}

function Invoke-Bootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{}
    )

    return Invoke-ProcessCapture `
        -FilePath (Get-PwshPath) `
        -ArgumentList (@('-NoLogo', '-NoProfile', '-File', (Join-Path $InstallRoot 'updates.ps1')) + $ArgumentList) `
        -WorkingDirectory $InstallRoot `
        -Environment $Environment
}

function Invoke-Launcher {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{}
    )

    return Invoke-CmdScript `
        -ScriptPath (Join-Path $InstallRoot 'updates.cmd') `
        -ArgumentList $ArgumentList `
        -WorkingDirectory $InstallRoot `
        -Environment $Environment
}

function Start-BootstrapProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{}
    )

    return Start-ProcessInstance `
        -FilePath (Get-PwshPath) `
        -ArgumentList (@('-NoLogo', '-NoProfile', '-File', (Join-Path $InstallRoot 'updates.ps1')) + $ArgumentList) `
        -WorkingDirectory $InstallRoot `
        -Environment $Environment
}

function Start-BootstrapProcessInNewGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [string[]]$ArgumentList = @()
    )

    Ensure-ConsoleSignalTestSupport
    return [UpdatesWindowsSignalTestSupport]::StartInNewProcessGroup(
        (Get-PwshPath),
        $InstallRoot,
        (@('-NoLogo', '-NoProfile', '-File', (Join-Path $InstallRoot 'updates.ps1')) + $ArgumentList)
    )
}

function Set-IgnoreCtrlC {
    param([bool]$Ignore)

    Ensure-ConsoleSignalTestSupport
    [UpdatesWindowsSignalTestSupport]::SetIgnoreCtrlC($Ignore)
}

function Send-CtrlC {
    Ensure-ConsoleSignalTestSupport
    [UpdatesWindowsSignalTestSupport]::SendCtrlC()
}

function Send-CtrlBreak {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessGroupId
    )

    Ensure-ConsoleSignalTestSupport
    [UpdatesWindowsSignalTestSupport]::SendCtrlBreak($ProcessGroupId)
}

function Wait-ForCondition {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Predicate,
        [int]$TimeoutMs = 10000,
        [int]$PollMs = 50,
        [string]$FailureMessage = 'Timed out waiting for condition.'
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMs) {
        if (& $Predicate) {
            return
        }
        Start-Sleep -Milliseconds $PollMs
    }

    throw $FailureMessage
}

function Wait-ForProcessExit {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutMs = 10000,
        [string]$FailureMessage = 'Timed out waiting for process exit.'
    )

    if ($Process.WaitForExit($TimeoutMs)) {
        return
    }

    try {
        if (-not $Process.HasExited) {
            $Process.Kill($true)
        }
    } catch {
        Write-Verbose ("best-effort process kill failed for pid {0}: {1}" -f $Process.Id, $_.Exception.Message)
    }

    throw $FailureMessage
}

function Test-NativeProcessExited {
    param(
        [Parameter(Mandatory = $true)]
        [UpdatesWindowsSpawnedProcess]$Process
    )

    Ensure-ConsoleSignalTestSupport
    return [UpdatesWindowsSignalTestSupport]::WaitForExit($Process, 0)
}

function Wait-ForNativeProcessExit {
    param(
        [Parameter(Mandatory = $true)]
        [UpdatesWindowsSpawnedProcess]$Process,
        [int]$TimeoutMs = 10000,
        [string]$FailureMessage = 'Timed out waiting for native process exit.'
    )

    Ensure-ConsoleSignalTestSupport
    if ([UpdatesWindowsSignalTestSupport]::WaitForExit($Process, $TimeoutMs)) {
        return
    }

    try {
        [UpdatesWindowsSignalTestSupport]::Kill($Process)
    } catch {
        Write-Verbose ("best-effort native process kill failed: {0}" -f $_.Exception.Message)
    }

    throw $FailureMessage
}

function Get-NativeProcessExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [UpdatesWindowsSpawnedProcess]$Process
    )

    Ensure-ConsoleSignalTestSupport
    return [UpdatesWindowsSignalTestSupport]::GetExitCode($Process)
}

function Stop-NativeProcess {
    param(
        [Parameter(Mandatory = $true)]
        [UpdatesWindowsSpawnedProcess]$Process
    )

    Ensure-ConsoleSignalTestSupport
    try {
        [UpdatesWindowsSignalTestSupport]::Kill($Process)
    } catch {
        Write-Verbose ("best-effort native process stop failed: {0}" -f $_.Exception.Message)
    } finally {
        [UpdatesWindowsSignalTestSupport]::Close($Process)
    }
}

function Invoke-WindowsSignalCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [Parameter(Mandatory = $true)]
        [ValidateSet('CtrlC', 'CtrlBreak')]
        [string]$SignalType,
        [Parameter(Mandatory = $true)]
        [string]$ReadyPath,
        [int]$TimeoutMs = 20000
    )

    $helperPath = Join-Path $script:WindowsTestHelpersRoot 'run_windows_signal_case.ps1'
    $resultPath = Join-Path $InstallRoot ("signal-{0}-result.json" -f $SignalType.ToLowerInvariant())
    if (Test-Path -LiteralPath $resultPath) {
        Remove-Item -LiteralPath $resultPath -Force
    }

    $process = Start-Process `
        -FilePath (Get-PwshPath) `
        -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-File', $helperPath,
            '-InstallRoot', $InstallRoot,
            '-SignalType', $SignalType,
            '-ReadyPath', $ReadyPath,
            '-ResultPath', $resultPath
        ) `
        -WorkingDirectory $InstallRoot `
        -WindowStyle Hidden `
        -PassThru

    if (-not $process.WaitForExit($TimeoutMs)) {
        try {
            $process.Kill($true)
        } catch {
            Write-Verbose ("best-effort signal helper kill failed for pid {0}: {1}" -f $process.Id, $_.Exception.Message)
        }
        throw ("signal helper timed out for {0}" -f $SignalType)
    }

    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw ("signal helper did not write a result file for {0} (helper exit {1})" -f $SignalType, $process.ExitCode)
    }

    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -AsHashtable
    $result.helper_exit = $process.ExitCode
    return [pscustomobject]$result
}

function Invoke-TestCase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Body
    )

    $script:TestCount++
    try {
        & $Body
        Write-Host ('ok {0} - {1}' -f $script:TestCount, $Name)
    } catch {
        $script:FailureCount++
        Write-Host ('not ok {0} - {1}' -f $script:TestCount, $Name)
        Write-Host ('  {0}' -f $_.Exception.Message)
    }
}

function Complete-TestRun {
    if ($script:FailureCount -gt 0) {
        throw ('{0} of {1} Windows-native tests failed.' -f $script:FailureCount, $script:TestCount)
    }
}
