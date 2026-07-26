#requires -Version 7.0
[CmdletBinding(PositionalBinding = $false)]
param(
    [string[]]$CliArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:EffectiveCliArgs = @()
if ($CliArgs -and $CliArgs.Count -gt 0) {
    $script:EffectiveCliArgs = @($CliArgs | Where-Object { -not [string]::IsNullOrEmpty($_) })
} elseif ($MyInvocation.UnboundArguments -and $MyInvocation.UnboundArguments.Count -gt 0) {
    $script:EffectiveCliArgs = @($MyInvocation.UnboundArguments | Where-Object { -not [string]::IsNullOrEmpty($_) })
} else {
    $fallbackArgs = Get-Variable -Name args -Scope Local -ErrorAction SilentlyContinue
    if ($fallbackArgs -and $fallbackArgs.Value -and $fallbackArgs.Value.Count -gt 0) {
        $script:EffectiveCliArgs = @($fallbackArgs.Value | Where-Object { -not [string]::IsNullOrEmpty($_) })
    }
}

$script:UpdatesVersion = '2.1.0'
$script:CanonicalRepo = 'amanthanvi/updates'
$script:ReleaseChannel = 'github-release'
$script:ReleaseManifestName = 'updates-release.json'
$script:WindowsAssetName = 'updates-windows.zip'
$script:ChecksumAssetName = 'SHA256SUMS'
$script:SelfUpdateCacheTtl = 86400
$script:SelfUpdateCacheFileName = 'self-update-amanthanvi_updates.cache'
$script:InstallRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:CurrentModule = 'main'
$script:OnlyModules = New-Object System.Collections.Generic.List[string]
$script:SkipModules = New-Object System.Collections.Generic.List[string]
$script:ConfigSkipModules = New-Object System.Collections.Generic.List[string]
$script:Successes = New-Object System.Collections.Generic.List[string]
$script:Skipped = New-Object System.Collections.Generic.List[string]
$script:Failures = New-Object System.Collections.Generic.List[string]
$script:LogLevelMap = @{
    error = 0
    warn  = 1
    info  = 2
    debug = 3
}
$script:LogLevel = 'info'
$script:LogLevelNum = 2
$script:DryRun = $false
$script:Strict = $false
$script:JsonMode = $false
$script:NoEmoji = $false
$script:NoColor = $false
$script:NonInteractive = $false
$script:NoConfig = $false
$script:SelfUpdate = $true
$script:ForceSelfUpdate = $false
$script:DoctorMode = $false
$script:PipForce = $false
$script:Parallel = $null
$script:FullMode = $false
$script:LogFile = $null
$script:GoBinaries = ''
$script:ReposDir = ''
$script:NodeNpmInstallFlags = ''
$script:NcuResolutionReason = ''
$script:MasUpgrade = $false
$script:MacosUpdates = $false

$script:ModuleRegistry = @(
    [ordered]@{ Name = 'brew';   Platforms = @('macos', 'linux'); Default = $true;  Description = 'Update Homebrew formulae (+ optional casks)' },
    [ordered]@{ Name = 'shell';  Platforms = @('macos', 'linux'); Default = $true;  Description = 'Update Oh My Zsh and custom git plugins/themes' },
    [ordered]@{ Name = 'repos';  Platforms = @('macos', 'linux'); Default = $true;  Description = 'Update aman dev repos under ~/GitRepos' },
    [ordered]@{ Name = 'linux';  Platforms = @('linux');          Default = $true;  Description = 'Upgrade Linux system packages' },
    [ordered]@{ Name = 'winget'; Platforms = @('windows'); Default = $true; Handler = 'Invoke-ModuleWinget'; Description = 'Upgrade Windows packages via winget' },
    [ordered]@{ Name = 'node'; Platforms = @('macos', 'linux', 'windows'); Default = $true; Handler = 'Invoke-ModuleNode'; Description = 'Upgrade global npm packages via npm-check-updates' },
    [ordered]@{ Name = 'bun'; Platforms = @('macos', 'linux', 'windows'); Default = $true; Handler = 'Invoke-ModuleBun'; Description = 'Update Bun globals (and Bun itself when standalone-installed)' },
    [ordered]@{ Name = 'python'; Platforms = @('macos', 'linux', 'windows'); Default = $true; Handler = 'Invoke-ModulePython'; Description = 'Upgrade global Python packages via pip' },
    [ordered]@{ Name = 'uv'; Platforms = @('macos', 'linux', 'windows'); Default = $true; Handler = 'Invoke-ModuleUv'; Description = 'Update uv and uv-managed tools' },
    [ordered]@{ Name = 'mas';    Platforms = @('macos');          Default = $false; Description = 'Upgrade Mac App Store apps via mas (opt-in)' },
    [ordered]@{ Name = 'pipx'; Platforms = @('macos', 'linux', 'windows'); Default = $true; Handler = 'Invoke-ModulePipx'; Description = 'Upgrade pipx-managed apps via pipx' },
    [ordered]@{ Name = 'rustup'; Platforms = @('macos', 'linux', 'windows'); Default = $true; Handler = 'Invoke-ModuleRustup'; Description = 'Update Rust toolchains via rustup' },
    [ordered]@{ Name = 'claude'; Platforms = @('macos', 'linux', 'windows'); Default = $true; Handler = 'Invoke-ModuleClaude'; Description = 'Update Claude Code CLI' },
    [ordered]@{ Name = 'pi'; Platforms = @('macos', 'linux', 'windows'); Default = $true; Handler = 'Invoke-ModulePi'; Description = 'Update pi AI CLI extensions via pi update' },
    [ordered]@{ Name = 'mise';   Platforms = @('macos', 'linux'); Default = $true; Description = 'Update mise and upgrade installed tools' },
    [ordered]@{ Name = 'go'; Platforms = @('macos', 'linux', 'windows'); Default = $true; Handler = 'Invoke-ModuleGo'; Description = 'Update Go binaries from GO_BINARIES config' },
    [ordered]@{ Name = 'macos';  Platforms = @('macos');          Default = $false; Description = 'List available macOS software updates (opt-in)' }
)

function Get-Timestamp {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Write-HumanLine {
    param([string]$Message)

    if ($script:JsonMode) {
        [Console]::Error.WriteLine($Message)
    } else {
        [Console]::Out.WriteLine($Message)
    }

    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $Message -Encoding utf8NoBOM
    }
}

function Write-JsonEvent {
    param([hashtable]$Data)

    if (-not $script:JsonMode) {
        return
    }

    if (-not $Data.ContainsKey('timestamp')) {
        $Data.timestamp = Get-Timestamp
    }

    [Console]::Out.WriteLine(($Data | ConvertTo-Json -Compress))
}

function Write-ProgressLine {
    param([string]$Message)

    if ($script:LogLevelNum -ge 1) {
        Write-HumanLine $Message
    }
}

function Write-LogLine {
    param([string]$Message)

    Write-JsonEvent @{
        event   = 'log'
        module  = $script:CurrentModule
        message = $Message
    }

    if ($script:LogLevelNum -ge 2) {
        Write-HumanLine $Message
    }
}

function Write-DebugLine {
    param([string]$Message)

    Write-JsonEvent @{
        event   = 'log'
        module  = $script:CurrentModule
        message = $Message
    }

    if ($script:LogLevelNum -ge 3) {
        Write-HumanLine $Message
    }
}

function Write-WarnLine {
    param([string]$Message)

    Write-JsonEvent @{
        event   = 'warn'
        module  = $script:CurrentModule
        message = $Message
    }

    if ($script:LogLevelNum -ge 1) {
        Write-HumanLine ("WARN: {0}" -f $Message)
    }
}

function Write-ErrorLine {
    param([string]$Message)

    Write-JsonEvent @{
        event   = 'error'
        module  = $script:CurrentModule
        message = $Message
    }

    Write-HumanLine ("ERROR: {0}" -f $Message)
}

function Fail-Usage {
    param([string]$Message)

    Write-ErrorLine $Message
    exit 2
}

function Set-LogLevel {
    param([string]$Value)

    if (-not $script:LogLevelMap.ContainsKey($Value)) {
        Fail-Usage '--log-level must be one of: error, warn, info, debug'
    }

    $script:LogLevel = $Value
    $script:LogLevelNum = [int]$script:LogLevelMap[$Value]
}

function Get-HomeDir {
    if ($env:HOME) {
        return $env:HOME
    }
    if ($env:USERPROFILE) {
        return $env:USERPROFILE
    }
    return $null
}

function Get-ConfigPath {
    $homeDir = Get-HomeDir
    if (-not $homeDir) {
        return $null
    }
    return (Join-Path $homeDir '.updatesrc')
}

function Split-ModuleList {
    param([string]$Value)

    $normalized = ($Value -replace ',', ' ')
    return @(
        [regex]::Split($normalized, '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-ModuleInfo {
    param([string]$Name)

    foreach ($module in $script:ModuleRegistry) {
        if ($module.Name -eq $Name) {
            return $module
        }
    }
    return $null
}

function Test-ModuleKnown {
    param([string]$Name)

    return $null -ne (Get-ModuleInfo -Name $Name)
}

function Test-ModuleSupported {
    param([string]$Name)

    $module = Get-ModuleInfo -Name $Name
    if ($null -eq $module) {
        return $false
    }
    return $module.Platforms -contains 'windows'
}

function Validate-OnlyModulesSupported {
    foreach ($moduleName in $script:OnlyModules) {
        if (-not (Test-ModuleSupported -Name $moduleName)) {
            Fail-Usage ("{0}: module is not supported on this platform" -f $moduleName)
        }
    }
}

function List-Modules {
    foreach ($module in $script:ModuleRegistry) {
        '{0,-8} {1}' -f $module.Name, $module.Description
    }
}

function Show-Usage {
    @"
updates v$($script:UpdatesVersion)

Updates common tooling on native Windows using PowerShell 7.

Usage:
  updates [options]

Options:
  -h, --help               Show this help
      --version            Print version
      --list-modules       List available modules
      --doctor             Check local install integrity; make no changes or network requests
      --dry-run            Print what would run; make no changes
      --only <list>        Run only these modules (CSV; or quote a space-separated list)
      --skip <list>        Skip these modules (CSV; or quote a space-separated list)
      --strict             Stop on first failure
      --log-level <level>  Output level: error, warn, info, debug (default: info)
      --json               Emit JSONL events to stdout (human output to stderr)
      --[no-]self-update   Check GitHub for a newer version and update this install (default: enabled)
  -n, --non-interactive    Avoid interactive prompts when possible
      --no-config          Ignore ~/.updatesrc
      --no-emoji           Disable emoji in output
      --no-color           Disable ANSI colors in output
      --log-file <path>    Append human output to a log file
      --parallel <N>       Reserved for Bash pip upgrades; unsupported on native Windows
      --pip-force          Pass --break-system-packages to pip when supported
      --full               Enable all supported Windows modules
"@
}

function PreScan-NoConfig {
    param([string[]]$CliInput)

    $CliInput = @($CliInput | Where-Object { -not [string]::IsNullOrEmpty($_) })
    foreach ($arg in $CliInput) {
        switch ($arg) {
            '--no-config' { $script:NoConfig = $true }
            '--json' { $script:JsonMode = $true }
            '-h' { $script:NoConfig = $true }
            '--help' { $script:NoConfig = $true }
            '--version' { $script:NoConfig = $true }
            '--list-modules' { $script:NoConfig = $true }
            '--doctor' { $script:NoConfig = $true; $script:DoctorMode = $true }
        }
    }
}

function Add-ConfigSkipModules {
    param([string]$Value)

    foreach ($name in (Split-ModuleList -Value $Value)) {
        if (-not (Test-ModuleKnown -Name $name)) {
            Write-WarnLine ("config: unknown module in SKIP_MODULES: {0}" -f $name)
            continue
        }
        $script:ConfigSkipModules.Add($name)
    }
}

function Set-ConfigBool {
    param(
        [string]$Name,
        [string]$Value,
        [scriptblock]$Apply
    )

    switch ($Value) {
        '0' { & $Apply $false }
        '1' { & $Apply $true }
        default { Write-WarnLine ("config: {0} must be 0 or 1 (got: {1})" -f $Name, $Value) }
    }
}

function Try-ParsePositiveInt32 {
    param(
        [string]$Value,
        [ref]$Parsed
    )

    $parsedValue = 0
    if (-not [int]::TryParse($Value, [ref]$parsedValue)) {
        return $false
    }
    if ($parsedValue -lt 1) {
        return $false
    }

    $Parsed.Value = $parsedValue
    return $true
}

function Read-Config {
    if ($script:NoConfig) {
        return
    }

    $configPath = Get-ConfigPath
    if (-not $configPath -or -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return
    }

    $lines = [System.IO.File]::ReadAllLines($configPath)
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($i -eq 0) {
            $line = $line.TrimStart([char]0xFEFF)
        }
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            continue
        }

        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        switch ($key) {
            'SKIP_MODULES' { $script:ConfigSkipModules.Clear(); Add-ConfigSkipModules -Value $value }
            'LOG_LEVEL' {
                if ($script:LogLevelMap.ContainsKey($value)) {
                    Set-LogLevel $value
                } else {
                    Write-WarnLine ("config: LOG_LEVEL must be error, warn, info, or debug (got: {0})" -f $value)
                }
            }
            'PARALLEL' {
                $parallelValue = 0
                if (Try-ParsePositiveInt32 -Value $value -Parsed ([ref]$parallelValue)) {
                    Write-WarnLine 'config: PARALLEL is ignored on native Windows.'
                } else {
                    Write-WarnLine ("config: PARALLEL must be >= 1 (got: {0})" -f $value)
                }
            }
            'PIP_FORCE' { Set-ConfigBool -Name $key -Value $value -Apply { param($v) $script:PipForce = $v } }
            'SELF_UPDATE' { Set-ConfigBool -Name $key -Value $value -Apply { param($v) $script:SelfUpdate = $v } }
            'NO_EMOJI' { Set-ConfigBool -Name $key -Value $value -Apply { param($v) $script:NoEmoji = $v } }
            'NO_COLOR' { Set-ConfigBool -Name $key -Value $value -Apply { param($v) $script:NoColor = $v } }
            'GO_BINARIES' { $script:GoBinaries = $value }
            'REPOS_DIR' { $script:ReposDir = $value }
            'NODE_NPM_INSTALL_FLAGS' { $script:NodeNpmInstallFlags = $value }
            'MAS_UPGRADE' { Set-ConfigBool -Name $key -Value $value -Apply { param($v) $script:MasUpgrade = $v } }
            'MACOS_UPDATES' { Set-ConfigBool -Name $key -Value $value -Apply { param($v) $script:MacosUpdates = $v } }
            default { }
        }
    }
}

function Parse-Args {
    param([string[]]$CliInput)

    $CliInput = @($CliInput | Where-Object { -not [string]::IsNullOrEmpty($_) })
    $i = 0
    while ($i -lt $CliInput.Length) {
        $arg = $CliInput[$i]
        switch ($arg) {
            '-h' { Show-Usage; exit 0 }
            '--help' { Show-Usage; exit 0 }
            '--version' { [Console]::Out.WriteLine($script:UpdatesVersion); exit 0 }
            '--list-modules' { List-Modules | ForEach-Object { [Console]::Out.WriteLine($_) }; exit 0 }
            '--doctor' { $script:DoctorMode = $true; $script:SelfUpdate = $false }
            '--dry-run' { $script:DryRun = $true }
            '--strict' { $script:Strict = $true }
            '--json' { $script:JsonMode = $true }
            '--self-update' { $script:SelfUpdate = $true; $script:ForceSelfUpdate = $true }
            '--no-self-update' { $script:SelfUpdate = $false }
            '--no-emoji' { $script:NoEmoji = $true }
            '--no-color' { $script:NoColor = $true }
            '--no-config' { $script:NoConfig = $true }
            '-n' { $script:NonInteractive = $true }
            '--non-interactive' { $script:NonInteractive = $true }
            '--pip-force' { $script:PipForce = $true }
            '--full' {
                $script:MasUpgrade = $true
                $script:MacosUpdates = $true
                $script:FullMode = $true
            }
            '--log-level' {
                $i++
                if ($i -ge $CliInput.Length) { Fail-Usage '--log-level requires a value' }
                Set-LogLevel $CliInput[$i]
            }
            '--log-file' {
                $i++
                if ($i -ge $CliInput.Length) { Fail-Usage '--log-file requires a path' }
                $script:LogFile = $CliInput[$i]
            }
            '--parallel' {
                $i++
                if ($i -ge $CliInput.Length) { Fail-Usage '--parallel requires a number' }
                $parallelValue = 0
                if (-not (Try-ParsePositiveInt32 -Value $CliInput[$i] -Parsed ([ref]$parallelValue))) {
                    Fail-Usage '--parallel must be >= 1'
                }
                Fail-Usage '--parallel is not supported on native Windows.'
            }
            '--only' {
                $i++
                if ($i -ge $CliInput.Length) { Fail-Usage '--only requires a module list' }
                foreach ($moduleName in (Split-ModuleList -Value $CliInput[$i])) {
                    if (-not (Test-ModuleKnown -Name $moduleName)) {
                        Fail-Usage ("Unknown module in --only: {0}" -f $moduleName)
                    }
                    $script:OnlyModules.Add($moduleName)
                }
            }
            '--skip' {
                $i++
                if ($i -ge $CliInput.Length) { Fail-Usage '--skip requires a module list' }
                foreach ($moduleName in (Split-ModuleList -Value $CliInput[$i])) {
                    if (-not (Test-ModuleKnown -Name $moduleName)) {
                        Fail-Usage ("Unknown module in --skip: {0}" -f $moduleName)
                    }
                    $script:SkipModules.Add($moduleName)
                }
            }
            '--' {
                if ($i -ne $CliInput.Length - 1) {
                    Fail-Usage ("Unexpected argument: {0}" -f $CliInput[$i + 1])
                }
            }
            default {
                if ($arg.StartsWith('-')) {
                    Fail-Usage ("Unknown option: {0}" -f $arg)
                }
                Fail-Usage ("Unexpected argument: {0}" -f $arg)
            }
        }
        $i++
    }
}

function Ensure-LogFileReady {
    if (-not $script:LogFile) {
        return
    }
    $parent = Split-Path -Parent $script:LogFile
    if ($parent) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    if (-not (Test-Path -LiteralPath $script:LogFile)) {
        New-Item -ItemType File -Path $script:LogFile -Force | Out-Null
    }
}

function Format-BoundaryStart {
    param([string]$ModuleName)

    return "==> $ModuleName START"
}

function Format-BoundaryEnd {
    param(
        [string]$ModuleName,
        [string]$Status,
        [int]$Seconds
    )

    return "==> $ModuleName END ($Status) (${Seconds}s)"
}

function Format-Summary {
    param(
        [int]$Ok,
        [int]$Skip,
        [int]$Fail,
        [int]$TotalSeconds
    )

    $line = "==> SUMMARY ok=$Ok skip=$Skip fail=$Fail total=${TotalSeconds}s"
    if ($script:Failures.Count -gt 0) {
        $line += (' failures=' + (($script:Failures | ForEach-Object { $_ }) -join ','))
    }
    return $line
}

function Write-ModuleStartEvent {
    param([string]$ModuleName)

    Write-JsonEvent @{
        event  = 'module_start'
        module = $ModuleName
    }
}

function Write-ModuleEndEvent {
    param(
        [string]$ModuleName,
        [string]$Status,
        [int]$Seconds
    )

    Write-JsonEvent @{
        event   = 'module_end'
        module  = $ModuleName
        status  = $Status
        seconds = $Seconds
    }
}

function Write-SummaryEvent {
    param([int]$TotalSeconds)

    Write-JsonEvent @{
        event         = 'summary'
        ok            = $script:Successes.Count
        skip          = $script:Skipped.Count
        fail          = $script:Failures.Count
        total_seconds = $TotalSeconds
        failures      = @($script:Failures)
    }
}

function Resolve-ApplicationCommand {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandType -in @('Application', 'ExternalScript')
        } | Select-Object -First 1
        if ($command) {
            if ($command.Source) {
                return $command.Source
            }
            if ($command.Path) {
                return $command.Path
            }
        }
    }
    return $null
}

function Format-Command {
    param([string[]]$Command)

    return (($Command | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' ')
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = $script:InstallRoot
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
        $null = $psi.ArgumentList.Add([string]$arg)
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

function Write-ProcessResultOutput {
    param($Result)

    if ($Result.Stdout) {
        if ($script:JsonMode) {
            [Console]::Error.Write($Result.Stdout)
        } else {
            [Console]::Out.Write($Result.Stdout)
        }
        if ($script:LogFile) {
            [System.IO.File]::AppendAllText($script:LogFile, $Result.Stdout, [System.Text.UTF8Encoding]::new($false))
        }
    }
    if ($Result.Stderr) {
        [Console]::Error.Write($Result.Stderr)
        if ($script:LogFile) {
            [System.IO.File]::AppendAllText($script:LogFile, $Result.Stderr, [System.Text.UTF8Encoding]::new($false))
        }
    }
}

function Invoke-LoggedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = $script:InstallRoot,
        [switch]$Capture
    )

    $commandText = Format-Command (@($FilePath) + $ArgumentList)
    Write-DebugLine ("+ {0}" -f $commandText)
    if ($script:DryRun) {
        Write-LogLine ("DRY RUN: {0}" -f $commandText)
        return [pscustomobject]@{ ExitCode = 0; Stdout = ''; Stderr = ''; Output = '' }
    }

    $result = Invoke-CapturedProcess -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
    if (-not $Capture) {
        Write-ProcessResultOutput -Result $result
    }
    return $result
}

function Resolve-PythonLauncher {
    $py = Resolve-ApplicationCommand @('py.exe', 'py')
    if ($py) {
        $probe = Invoke-CapturedProcess -FilePath $py -ArgumentList @('-3', '-c', 'import sys')
        if ($probe.ExitCode -eq 0) {
            return [pscustomobject]@{ FilePath = $py; Prefix = @('-3'); Label = 'py -3' }
        }
    }

    foreach ($candidate in @('python.exe', 'python', 'python3.exe', 'python3')) {
        $path = Resolve-ApplicationCommand @($candidate)
        if ($path) {
            return [pscustomobject]@{ FilePath = $path; Prefix = @(); Label = (Split-Path -Leaf $path) }
        }
    }

    return $null
}

function Test-ExternallyManagedPython {
    param($Python)

    if (-not $Python) {
        return $false
    }

    $probe = Invoke-CapturedProcess -FilePath $Python.FilePath -ArgumentList (
        $Python.Prefix + @(
            '-c',
            'import sysconfig, pathlib; paths=sysconfig.get_paths(); c=[pathlib.Path(paths[k])/"EXTERNALLY-MANAGED" for k in ("stdlib","platstdlib","purelib","platlib") if paths.get(k)]; print("1" if any(p.exists() for p in c) else "0")'
        )
    )
    return ($probe.ExitCode -eq 0 -and $probe.Stdout.Trim() -eq '1')
}

function Resolve-MissingDependency {
    param(
        [string]$ModuleName,
        [string]$Detail
    )

    if ($script:OnlyModules.Count -gt 0 -and $script:OnlyModules.Contains($ModuleName)) {
        Write-ErrorLine ("{0}: {1}" -f $ModuleName, $Detail)
        return 1
    }

    Write-LogLine ("Skipping {0}: {1}" -f $ModuleName, $Detail)
    return 2
}

function Resolve-NcuRunner {
    $script:NcuResolutionReason = 'missing'
    foreach ($candidate in @('ncu.cmd', 'ncu')) {
        $path = Resolve-ApplicationCommand @($candidate)
        if (-not $path) {
            continue
        }

        $probe = Invoke-CapturedProcess -FilePath $path -ArgumentList @('--help', 'enginesNode')
        if ($probe.ExitCode -eq 0 -and $probe.Output -match '--enginesNode') {
            return [pscustomobject]@{
                FilePath = $path
                Prefix   = @('-g', '--enginesNode', '--jsonUpgraded')
                Label    = ((Split-Path -Leaf $path) + ' -g --enginesNode --jsonUpgraded')
            }
        }
        $script:NcuResolutionReason = 'incompatible'
        Write-DebugLine ("node: {0} lacks --enginesNode; trying the next adapter" -f (Split-Path -Leaf $path))
    }

    $npx = Resolve-ApplicationCommand @('npx.cmd', 'npx')
    if ($npx) {
        return [pscustomobject]@{
            FilePath = $npx
            Prefix   = @('--yes', 'npm-check-updates', '-g', '--enginesNode', '--jsonUpgraded')
            Label    = 'npx --yes npm-check-updates -g --enginesNode --jsonUpgraded'
        }
    }

    return $null
}

function New-NpmInstallArguments {
    param(
        [AllowEmptyCollection()]
        [string[]]$Options = @(),
        [Parameter(Mandatory = $true)]
        [string[]]$Packages
    )

    return (@('install', '-g') + @($Options) + @('--') + @($Packages))
}

function Get-NpmInstallExtraFlags {
    if ([string]::IsNullOrWhiteSpace($script:NodeNpmInstallFlags)) {
        return
    }

    return (($script:NodeNpmInstallFlags -split '\s+') | Where-Object { $_ -ne '' })
}

function Get-NpmInstallRetryOptions {
    param(
        [AllowEmptyCollection()]
        [string[]]$Options = @()
    )

    return (@($Options | Where-Object { $_ -ne '--legacy-peer-deps' }) + @('--legacy-peer-deps'))
}

function Get-NpmAllowScriptsArgument {
    param(
        [AllowEmptyString()]
        [string]$Output
    )

    $match = [regex]::Match($Output, '--allow-scripts=[^`\s]+')
    if ($match.Success) {
        return $match.Value
    }
    return ''
}

function Test-NpmAllowScriptsWarning {
    param(
        [AllowEmptyString()]
        [string]$Output
    )

    return ($Output -match 'npm warn allow-scripts')
}

function ConvertTo-CommandOutcome {
    param(
        [ValidateSet('ok', 'skip', 'retry', 'fail')]
        [string]$Status,
        [string]$Reason,
        [string]$Message,
        [string]$RetryArgument = ''
    )

    return [pscustomobject]@{
        Status        = $Status
        Reason        = $Reason
        Message       = $Message
        RetryArgument = $RetryArgument
    }
}

function Resolve-NpmInstallOutcome {
    param(
        [Parameter(Mandatory = $true)]
        $Result
    )

    if ($Result.Output -match 'EBADENGINE') {
        return (ConvertTo-CommandOutcome -Status fail -Reason incompatible-engine -Message 'package is incompatible with the active Node runtime')
    }

    if ($Result.ExitCode -eq 0) {
        $allowScriptsArg = Get-NpmAllowScriptsArgument -Output $Result.Output
        if ($allowScriptsArg) {
            return (ConvertTo-CommandOutcome -Status retry -Reason install-scripts -Message 'npm install scripts need approval' -RetryArgument $allowScriptsArg)
        }
        return (ConvertTo-CommandOutcome -Status ok -Reason command-succeeded -Message '')
    }

    if ($Result.Output -match 'ERESOLVE') {
        return (ConvertTo-CommandOutcome -Status retry -Reason peer-resolution -Message 'npm peer dependency resolution failed' -RetryArgument '--legacy-peer-deps')
    }
    return (ConvertTo-CommandOutcome -Status fail -Reason command-failed -Message 'npm install failed')
}

function Invoke-NpmGlobalInstallOne {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Npm,
        [Parameter(Mandatory = $true)]
        [string]$Package,
        [AllowEmptyCollection()]
        [string[]]$InitialOptions = @()
    )

    $options = @($InitialOptions)
    $peerRetried = $false
    $scriptsRetried = $false
    while ($true) {
        $installArgs = New-NpmInstallArguments -Options $options -Packages @($Package)
        $result = Invoke-LoggedProcess -FilePath $Npm -ArgumentList $installArgs -Capture
        $outcome = Resolve-NpmInstallOutcome -Result $result

        if ($outcome.Status -eq 'ok') {
            if (Test-NpmAllowScriptsWarning -Output $result.Output) {
                Write-WarnLine ("node: npm reported install scripts needing approval for {0}, but no allow-scripts list could be parsed" -f $Package)
            }
            Write-ProcessResultOutput -Result $result
            return 0
        }

        if ($outcome.Status -eq 'retry' -and $outcome.Reason -eq 'peer-resolution') {
            if ($peerRetried) {
                Write-ErrorLine ("node: npm install failed for {0} after peer dependency retry" -f $Package)
                Write-ProcessResultOutput -Result $result
                return 1
            }
            Write-WarnLine ("node: npm peer dependency resolution failed for {0}; retrying with --legacy-peer-deps" -f $Package)
            $options = @(Get-NpmInstallRetryOptions -Options $options)
            $peerRetried = $true
            continue
        }

        if ($outcome.Status -eq 'retry' -and $outcome.Reason -eq 'install-scripts') {
            if ($scriptsRetried) {
                Write-WarnLine ("node: npm install completed for {0}, but npm still reports install scripts needing approval after retry" -f $Package)
                Write-ProcessResultOutput -Result $result
                return 0
            }
            Write-WarnLine ("node: npm install scripts need approval for {0}; retrying once with npm-provided allow-scripts list" -f $Package)
            $options = @($outcome.RetryArgument) + @($options)
            $scriptsRetried = $true
            continue
        }

        if ($outcome.Reason -eq 'incompatible-engine') {
            Write-ErrorLine ("node: {0} is incompatible with the active Node runtime" -f $Package)
        } else {
            Write-ErrorLine ("node: npm install failed for {0}" -f $Package)
        }
        Write-ProcessResultOutput -Result $result
        return 1
    }
}

function Invoke-NpmGlobalInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Npm,
        [Parameter(Mandatory = $true)]
        [string[]]$Packages
    )

    $extraFlags = @(Get-NpmInstallExtraFlags)
    $failed = $false
    foreach ($package in $Packages) {
        if ((Invoke-NpmGlobalInstallOne -Npm $Npm -Package $package -InitialOptions $extraFlags) -ne 0) {
            $failed = $true
        }
    }
    if ($failed) {
        return 1
    }
    return 0
}

function Test-BunStandaloneInstall {
    param([string]$BunPath)

    $homeDir = Get-HomeDir
    if (-not $homeDir) {
        return $false
    }
    $expected = [System.IO.Path]::GetFullPath((Join-Path $homeDir '.bun\bin\bun.exe'))
    return ([System.IO.Path]::GetFullPath($BunPath)).Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-UvStandaloneInstall {
    param([string]$UvPath)

    $homeDir = Get-HomeDir
    if (-not $homeDir) {
        return $false
    }
    foreach ($candidate in @(
        (Join-Path $homeDir '.local\bin\uv.exe'),
        (Join-Path $homeDir '.cargo\bin\uv.exe')
    )) {
        if ([System.IO.Path]::GetFullPath($UvPath).Equals([System.IO.Path]::GetFullPath($candidate), [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Emit-UpgradeEvent {
    param(
        [string]$ModuleName,
        [string]$Package,
        [string]$From,
        [string]$To
    )

    Write-JsonEvent @{
        event   = 'upgrade'
        module  = $ModuleName
        package = $Package
        from    = $From
        to      = $To
    }
}

function Invoke-ModuleWinget {
    $winget = Resolve-ApplicationCommand @('winget.exe', 'winget')
    if (-not $winget) {
        return (Resolve-MissingDependency -ModuleName 'winget' -Detail 'winget not found.')
    }

    $wingetArgs = @('upgrade', '--all', '--silent', '--accept-source-agreements', '--accept-package-agreements')
    if ($script:DryRun) {
        Write-LogLine ("DRY RUN: {0}" -f (Format-Command (@($winget) + $wingetArgs)))
        return 0
    }

    $result = Invoke-LoggedProcess -FilePath $winget -ArgumentList $wingetArgs
    if ($result.ExitCode -ne 0) {
        Write-ErrorLine 'winget: upgrade failed'
        return 1
    }
    return 0
}

function Invoke-ModuleNode {
    $runner = Resolve-NcuRunner
    if (-not $runner) {
        $detail = 'npm-check-updates not available (need ncu or npx).'
        if ($script:NcuResolutionReason -eq 'incompatible') {
            $detail = 'no npm-check-updates adapter supports --enginesNode; upgrade ncu or install npx.'
        }
        if ($script:OnlyModules.Count -gt 0 -and $script:OnlyModules.Contains('node')) {
            Write-ErrorLine ("node: {0}" -f $detail)
            return 1
        }
        Write-WarnLine ("node: {0} Skipping." -f $detail)
        return 2
    }

    $npm = Resolve-ApplicationCommand @('npm.cmd', 'npm')
    if (-not $npm) {
        return (Resolve-MissingDependency -ModuleName 'node' -Detail 'npm not found.')
    }

    if ($script:DryRun) {
        Write-LogLine ("DRY RUN: {0}" -f $runner.Label)
        $dryRunInstallArgs = New-NpmInstallArguments -Options @(Get-NpmInstallExtraFlags) -Packages @('<packages...>')
        Write-LogLine ("DRY RUN: {0}" -f (Format-Command (@($npm) + $dryRunInstallArgs)))
        return 0
    }

    $result = Invoke-LoggedProcess -FilePath $runner.FilePath -ArgumentList $runner.Prefix -Capture
    if ($result.ExitCode -ne 0) {
        Write-ErrorLine 'node: npm-check-updates failed'
        return 1
    }

    try {
        $data = $result.Stdout | ConvertFrom-Json -AsHashtable
    } catch {
        Write-ErrorLine 'node: failed to parse npm-check-updates output'
        return 1
    }

    $packages = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $data.GetEnumerator()) {
        $packages.Add(('{0}@{1}' -f $entry.Key, $entry.Value))
        Emit-UpgradeEvent -ModuleName 'node' -Package $entry.Key -From '' -To ([string]$entry.Value)
    }

    if ($packages.Count -eq 0) {
        Write-LogLine 'All global npm packages are up-to-date for the active Node runtime.'
        return 0
    }

    $installExitCode = Invoke-NpmGlobalInstall -Npm $npm -Packages @($packages)
    if ($installExitCode -ne 0) {
        Write-ErrorLine 'node: npm install failed'
        return 1
    }
    return 0
}

function Invoke-ModuleBun {
    $bun = Resolve-ApplicationCommand @('bun.exe', 'bun')
    if (-not $bun) {
        return (Resolve-MissingDependency -ModuleName 'bun' -Detail 'bun not found.')
    }

    if ($script:DryRun) {
        Write-LogLine ("DRY RUN: {0}" -f (Format-Command @($bun, 'update', '-g')))
        if (Test-BunStandaloneInstall -BunPath $bun) {
            Write-LogLine ("DRY RUN: {0}" -f (Format-Command @($bun, 'upgrade')))
        } else {
            Write-LogLine 'bun: skipping bun upgrade because Bun does not appear to be standalone-installed.'
        }
        return 0
    }

    $result = Invoke-LoggedProcess -FilePath $bun -ArgumentList @('update', '-g')
    if ($result.ExitCode -ne 0) {
        Write-ErrorLine 'bun: global upgrade failed'
        return 1
    }

    if (Test-BunStandaloneInstall -BunPath $bun) {
        $upgrade = Invoke-LoggedProcess -FilePath $bun -ArgumentList @('upgrade')
        if ($upgrade.ExitCode -ne 0) {
            Write-ErrorLine 'bun: bun upgrade failed'
            return 1
        }
    } else {
        Write-LogLine 'bun: skipping bun upgrade because Bun does not appear to be standalone-installed.'
    }

    return 0
}

function Invoke-ModulePython {
    $python = Resolve-PythonLauncher
    if (-not $python) {
        return (Resolve-MissingDependency -ModuleName 'python' -Detail 'no supported Python launcher found.')
    }

    $pipVersion = Invoke-CapturedProcess -FilePath $python.FilePath -ArgumentList ($python.Prefix + @('-m', 'pip', '--version'))
    if ($pipVersion.ExitCode -ne 0) {
        return (Resolve-MissingDependency -ModuleName 'python' -Detail ("pip not available ({0} -m pip)." -f $python.Label))
    }

    $listArgs = $python.Prefix + @('-m', 'pip', '--disable-pip-version-check', 'list', '--outdated', '--format=json')
    $installPrefix = $python.Prefix + @('-m', 'pip', '--disable-pip-version-check', 'install', '-U')
    $useUser = $false
    if (-not $script:PipForce -and (Test-ExternallyManagedPython -Python $python)) {
        $useUser = $true
        Write-LogLine 'python: externally-managed environment detected; upgrading user-site packages.'
        Write-LogLine 'python: use --pip-force to override (dangerous).'
    }
    if ($script:NonInteractive) {
        $installPrefix += '--no-input'
    }
    if ($useUser) {
        $listArgs += '--user'
        $installPrefix += '--user'
    }
    if ($script:PipForce) {
        $installPrefix += '--break-system-packages'
    }

    if ($script:DryRun) {
        Write-LogLine ("DRY RUN: {0}" -f (Format-Command (@($python.FilePath) + $listArgs)))
        Write-LogLine ("DRY RUN: {0} <package>" -f (Format-Command (@($python.FilePath) + $installPrefix)))
        return 0
    }

    $result = Invoke-LoggedProcess -FilePath $python.FilePath -ArgumentList $listArgs -Capture
    if ($result.ExitCode -ne 0) {
        Write-ErrorLine 'python: failed to query outdated packages'
        return 1
    }

    try {
        $packages = @($result.Stdout | ConvertFrom-Json)
    } catch {
        Write-ErrorLine 'python: failed to parse pip output'
        return 1
    }

    if ($packages.Count -eq 0) {
        Write-LogLine 'All Python packages are up-to-date.'
        return 0
    }

    foreach ($package in $packages) {
        if ($package.name) {
            Emit-UpgradeEvent -ModuleName 'python' -Package ([string]$package.name) -From ([string]$package.version) -To ([string]$package.latest_version)
            $installResult = Invoke-LoggedProcess -FilePath $python.FilePath -ArgumentList ($installPrefix + @([string]$package.name))
            if ($installResult.ExitCode -ne 0) {
                Write-ErrorLine ("python: pip upgrade failed: {0}" -f $package.name)
                return 1
            }
        }
    }
    return 0
}

function Invoke-ModuleUv {
    $uv = Resolve-ApplicationCommand @('uv.exe', 'uv')
    if (-not $uv) {
        return (Resolve-MissingDependency -ModuleName 'uv' -Detail 'uv not found.')
    }

    if ($script:DryRun) {
        if (Test-UvStandaloneInstall -UvPath $uv) {
            Write-LogLine ("DRY RUN: {0}" -f (Format-Command @($uv, 'self', 'update')))
        } else {
            Write-LogLine 'uv: skipping uv self update because uv does not appear to be standalone-installed.'
        }
        Write-LogLine ("DRY RUN: {0}" -f (Format-Command @($uv, 'tool', 'upgrade', '--all')))
        return 0
    }

    if (Test-UvStandaloneInstall -UvPath $uv) {
        $selfUpdate = Invoke-LoggedProcess -FilePath $uv -ArgumentList @('self', 'update')
        if ($selfUpdate.ExitCode -ne 0) {
            Write-ErrorLine 'uv: self update failed'
            return 1
        }
    } else {
        Write-LogLine 'uv: skipping uv self update because uv does not appear to be standalone-installed.'
    }

    $upgrade = Invoke-LoggedProcess -FilePath $uv -ArgumentList @('tool', 'upgrade', '--all')
    if ($upgrade.ExitCode -ne 0) {
        Write-ErrorLine 'uv: tool upgrade failed'
        return 1
    }
    return 0
}

function Invoke-ModulePipx {
    $pipx = Resolve-ApplicationCommand @('pipx.exe', 'pipx')
    if (-not $pipx) {
        return (Resolve-MissingDependency -ModuleName 'pipx' -Detail 'pipx not found.')
    }

    $result = Invoke-LoggedProcess -FilePath $pipx -ArgumentList @('upgrade-all')
    if ($result.ExitCode -ne 0) {
        Write-ErrorLine 'pipx: upgrade-all failed'
        return 1
    }
    return 0
}

function Invoke-ModuleRustup {
    $rustup = Resolve-ApplicationCommand @('rustup.exe', 'rustup')
    if (-not $rustup) {
        return (Resolve-MissingDependency -ModuleName 'rustup' -Detail 'rustup not found.')
    }

    $result = Invoke-LoggedProcess -FilePath $rustup -ArgumentList @('update')
    if ($result.ExitCode -ne 0) {
        Write-ErrorLine 'rustup: update failed'
        return 1
    }
    return 0
}

function Invoke-ModuleGo {
    $go = Resolve-ApplicationCommand @('go.exe', 'go')
    if (-not $go) {
        return (Resolve-MissingDependency -ModuleName 'go' -Detail 'go not found.')
    }
    if ([string]::IsNullOrWhiteSpace($script:GoBinaries)) {
        return (Resolve-MissingDependency -ModuleName 'go' -Detail 'GO_BINARIES not configured.')
    }

    $specs = New-Object System.Collections.Generic.List[string]
    foreach ($entry in (Split-ModuleList -Value $script:GoBinaries)) {
        if ($entry -match '@') {
            $specs.Add($entry)
        } else {
            $specs.Add(('{0}@latest' -f $entry))
        }
    }
    if ($specs.Count -eq 0) {
        return (Resolve-MissingDependency -ModuleName 'go' -Detail 'GO_BINARIES is empty.')
    }

    foreach ($spec in $specs) {
        $result = Invoke-LoggedProcess -FilePath $go -ArgumentList @('install', $spec)
        if ($result.ExitCode -ne 0) {
            Write-ErrorLine ("go: install failed: {0}" -f $spec)
            return 1
        }
    }
    return 0
}

function Invoke-ModuleClaude {
    $claude = Resolve-ApplicationCommand @('claude.exe', 'claude.cmd', 'claude')
    if (-not $claude) {
        return (Resolve-MissingDependency -ModuleName 'claude' -Detail 'claude not found.')
    }
    $result = Invoke-LoggedProcess -FilePath $claude -ArgumentList @('update')
    if ($result.ExitCode -ne 0) {
        Write-ErrorLine 'claude: update failed'
        return 1
    }
    return 0
}

function Invoke-ModulePi {
    $pi = Resolve-ApplicationCommand @('pi.exe', 'pi.cmd', 'pi')
    if (-not $pi) {
        return (Resolve-MissingDependency -ModuleName 'pi' -Detail 'pi not found.')
    }
    $result = Invoke-LoggedProcess -FilePath $pi -ArgumentList @('update')
    if ($result.ExitCode -ne 0) {
        Write-ErrorLine 'pi: update failed'
        return 1
    }
    return 0
}

function Invoke-Module {
    param([string]$ModuleName)

    $module = Get-ModuleInfo -Name $ModuleName
    if ($null -eq $module -or -not ($module.Platforms -contains 'windows') -or -not $module.Handler) {
        Write-LogLine ("Skipping {0}: module is not implemented on native Windows." -f $ModuleName)
        return 2
    }
    return (& $module.Handler)
}

function Get-SelectedModules {
    $selected = New-Object System.Collections.Generic.List[string]
    foreach ($module in $script:ModuleRegistry) {
        if ($script:SkipModules.Contains($module.Name)) {
            continue
        }
        if ($script:OnlyModules.Count -gt 0) {
            if ($script:OnlyModules.Contains($module.Name)) {
                $selected.Add($module.Name)
            }
            continue
        }
        if (-not (Test-ModuleSupported -Name $module.Name)) {
            continue
        }
        if ($script:FullMode) {
            $selected.Add($module.Name)
            continue
        }
        if ($script:ConfigSkipModules.Contains($module.Name)) {
            continue
        }
        if (-not $module.Default) {
            continue
        }
        $selected.Add($module.Name)
    }
    return $selected
}

function Download-ReleaseAsset {
    param(
        [string]$Uri,
        [string]$OutFile
    )

    $headers = @{ 'User-Agent' = 'updates' }
    $attempt = 0
    while ($attempt -lt 3) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $Uri -Headers $headers -OutFile $OutFile -TimeoutSec 15
            return
        } catch {
            if ($attempt -ge 3) {
                throw
            }
            Start-Sleep -Seconds 1
        }
    }
}

function Test-InstallRootWritable {
    $probePath = Join-Path $script:InstallRoot ('.write-test-{0}.tmp' -f ([guid]::NewGuid().ToString('N')))
    try {
        [System.IO.File]::WriteAllText($probePath, 'ok')
        Remove-Item -LiteralPath $probePath -Force
        return $true
    } catch {
        return $false
    }
}

function Get-PathEffectiveWriteAccess {
    param([string]$Path)
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principals = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $null = $principals.Add($identity.User.Value)
        foreach ($group in @($identity.Groups)) { $null = $principals.Add($group.Value) }
        $rules = (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
        $writeMask = [System.Security.AccessControl.FileSystemRights]::Write -bor
            [System.Security.AccessControl.FileSystemRights]::Modify -bor
            [System.Security.AccessControl.FileSystemRights]::FullControl -bor
            [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
            [System.Security.AccessControl.FileSystemRights]::CreateDirectories
        $allowed = $false
        foreach ($rule in $rules) {
            if (-not $principals.Contains($rule.IdentityReference.Value) -or (($rule.FileSystemRights -band $writeMask) -eq 0)) { continue }
            if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) { return $false }
            if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow) { $allowed = $true }
        }
        return $allowed
    } catch {
        return $null
    }
}

function Get-InstallReceipt {
    $receiptPath = Join-Path $script:InstallRoot 'install-source.json'
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        Write-WarnLine 'updates: self-update skipped because the standalone install receipt is missing.'
        return $null
    }

    try {
        $receipt = (Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable)
    } catch {
        Write-WarnLine 'updates: self-update skipped because install-source.json is invalid.'
        return $null
    }

    if ($receipt.kind -ne 'standalone') {
        Write-WarnLine 'updates: self-update skipped because install-source.json kind is not standalone.'
        return $null
    }
    if ($receipt.channel -ne $script:ReleaseChannel) {
        Write-WarnLine 'updates: self-update skipped because install-source.json channel does not match github-release.'
        return $null
    }
    if ($receipt.source_repo -ne $script:CanonicalRepo) {
        Write-WarnLine 'updates: self-update skipped because the install receipt source_repo does not match the official repo.'
        return $null
    }
    if ($receipt.scope -ne 'user') {
        Write-WarnLine 'updates: self-update skipped because install-source.json scope is not user.'
        return $null
    }
    return $receipt
}

function Test-GitCheckout {
    $git = Resolve-ApplicationCommand @('git.exe', 'git')
    if (-not $git) {
        return $false
    }
    $result = Invoke-CapturedProcess -FilePath $git -ArgumentList @('-C', $script:InstallRoot, 'rev-parse', '--is-inside-work-tree')
    return ($result.ExitCode -eq 0)
}

function Test-SymlinkedInstall {
    foreach ($path in @(
        (Join-Path $script:InstallRoot 'updates.cmd'),
        (Join-Path $script:InstallRoot 'updates.ps1')
    )) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $true
            }
        }
    }
    return $false
}

function Get-Sha256Digest {
    param([string]$Path)
    return ('sha256:' + ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()))
}

function Get-LatestReleaseMetadata {
    $headers = @{ 'User-Agent' = 'updates' }
    return Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/releases/latest" -f $script:CanonicalRepo) -Headers $headers -TimeoutSec 15
}

function Get-ReleaseAssetMap {
    param($Release)

    $map = @{}
    foreach ($asset in @($Release.assets)) {
        $map[[string]$asset.name] = $asset
    }
    return $map
}

function Test-ReleaseManifest {
    param(
        [string]$ManifestPath,
        [string]$ExpectedVersion
    )

    try {
        $manifest = (Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable)
    } catch {
        return $false
    }

    return (
        $manifest.version -eq $ExpectedVersion -and
        $manifest.source_repo -eq $script:CanonicalRepo -and
        $manifest.channel -eq $script:ReleaseChannel -and
        [string]$manifest.bootstrap_min -match '^\d+$' -and
        $manifest.windows_asset -eq $script:WindowsAssetName -and
        $manifest.unix_asset -eq 'updates' -and
        $manifest.checksum_asset -eq $script:ChecksumAssetName
    )
}

function Test-VersionedPayloadManifest {
    param(
        [string]$VersionRoot,
        [string]$ExpectedVersion
    )

    $manifestPath = Join-Path $VersionRoot 'manifest.json'
    $payloadPath = Join-Path $VersionRoot 'updates-main.ps1'

    try {
        $rootFull = [System.IO.Path]::GetFullPath($VersionRoot).TrimEnd('\', '/')
        $rootItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        foreach ($trustedPath in @($manifestPath, $payloadPath)) {
            $full = [System.IO.Path]::GetFullPath($trustedPath)
            if (-not $full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        $manifest = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable)
    } catch {
        return $false
    }

    if ($manifest.version -ne $ExpectedVersion) {
        return $false
    }

    if ([string]$manifest.bootstrap_min -notmatch '^\d+$') {
        return $false
    }

    if ([int]$manifest.bootstrap_min -gt 1) {
        return $false
    }

    if ($manifest.entry_script -ne 'updates-main.ps1') {
        return $false
    }

    try {
        $payloadText = [System.IO.File]::ReadAllText($payloadPath)
        $assignments = [regex]::Matches($payloadText, '(?m)^\s*\$script:UpdatesVersion\s*=.*$')
        $canonical = [regex]::Matches($payloadText, '(?m)^\$script:UpdatesVersion = ''(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)''$')
        return $assignments.Count -eq 1 -and $canonical.Count -eq 1 -and $canonical[0].Groups[1].Value -eq $ExpectedVersion
    } catch {
        return $false
    }
}

function Test-ContainedRegularFile {
    param([string]$RootPath, [string]$Path)
    try {
        $rootFull = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
        $pathFull = [System.IO.Path]::GetFullPath($Path)
        if (-not $pathFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        $item = Get-Item -LiteralPath $pathFull -Force -ErrorAction Stop
        return (-not $item.PSIsContainer -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
    } catch {
        return $false
    }
}

function Test-SelfUpdateMutationRootsSafe {
    param(
        [string]$VersionsRoot,
        [string]$StagingRoot,
        [string]$TargetRoot
    )
    try {
        $installFull = [System.IO.Path]::GetFullPath($script:InstallRoot).TrimEnd('\', '/')
        $versionsFull = [System.IO.Path]::GetFullPath($VersionsRoot).TrimEnd('\', '/')
        if (-not $versionsFull.StartsWith($installFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        foreach ($path in @($installFull, $versionsFull, $StagingRoot, $TargetRoot)) {
            $full = [System.IO.Path]::GetFullPath($path)
            if ($path -ne $installFull -and -not $full.StartsWith($installFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
            if (Test-Path -LiteralPath $full) {
                $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            }
        }
        return $true
    } catch {
        return $false
    }
}

function Update-InstallReceiptVersion {
    param([string]$Version)

    $receiptPath = Join-Path $script:InstallRoot 'install-source.json'
    $receipt = (Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable)
    $receipt.installed_version = $Version
    $temp = Join-Path $script:InstallRoot ('.install-source.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temp, (($receipt | ConvertTo-Json -Depth 5) + "`n"), [System.Text.UTF8Encoding]::new($false))
        Invoke-SelfUpdateCommitHook -Step 'receipt-temp'
        Move-Item -LiteralPath $temp -Destination $receiptPath -Force
    } finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-SelfUpdateCommitHook {
    param([string]$Step)
    if ($env:UPDATES_SELF_UPDATE_TESTING -eq '1' -and $env:UPDATES_SELF_UPDATE_FAIL_AFTER -eq $Step) {
        throw "injected self-update failure after $Step"
    }
}

function Commit-SelfUpdateMetadata {
    param([string]$PreviousVersion, [string]$InstalledVersion)

    Write-VersionPointer -Name 'previous.txt' -Value $PreviousVersion
    Invoke-SelfUpdateCommitHook -Step 'previous'
    # Receipt records the newest fully installed valid payload, which may precede activation.
    Update-InstallReceiptVersion -Version $InstalledVersion
    Invoke-SelfUpdateCommitHook -Step 'receipt'
    # Activate last, after payload, rollback pointer, and receipt are durable.
    Write-VersionPointer -Name 'current.txt' -Value $InstalledVersion
    Invoke-SelfUpdateCommitHook -Step 'current'
}

function Write-VersionPointer {
    param(
        [string]$Name,
        [string]$Value
    )

    $target = Join-Path $script:InstallRoot $Name
    $temp = Join-Path $script:InstallRoot ('.{0}.{1}.tmp' -f $Name, [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temp, ($Value + "`n"), [System.Text.UTF8Encoding]::new($false))
        Invoke-SelfUpdateCommitHook -Step (($Name -replace '\.txt$', '') + '-temp')
        Move-Item -LiteralPath $temp -Destination $target -Force
    } finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-SelfUpdateEpoch {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Get-SelfUpdateCacheRoot {
    if ($env:LOCALAPPDATA) {
        return (Join-Path $env:LOCALAPPDATA 'updates')
    }

    $homeDir = Get-HomeDir
    if (-not $homeDir) {
        return $null
    }

    return (Join-Path $homeDir 'AppData\Local\updates')
}

function Get-SelfUpdateCachePath {
    $root = Get-SelfUpdateCacheRoot
    if (-not $root) {
        return $null
    }

    return (Join-Path $root $script:SelfUpdateCacheFileName)
}

function Read-SelfUpdateCache {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $checkedAt = $null
        $latestTag = $null
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            if ($line -match '^(checked_at|latest_tag)=(.*)$') {
                switch ($Matches[1]) {
                    'checked_at' { $checkedAt = $Matches[2] }
                    'latest_tag' { $latestTag = $Matches[2] }
                }
            }
        }

        if ($checkedAt -notmatch '^\d+$' -or [string]::IsNullOrWhiteSpace($latestTag)) {
            return $null
        }

        return [pscustomobject]@{
            CheckedAt = [int64]$checkedAt
            LatestTag = $latestTag
        }
    } catch {
        return $null
    }
}

function Test-SelfUpdateCacheFresh {
    param(
        [int64]$CurrentEpoch,
        [int64]$CheckedAt
    )

    if ($CheckedAt -lt 0 -or $CheckedAt -gt $CurrentEpoch) {
        return $false
    }

    return (($CurrentEpoch - $CheckedAt) -lt $script:SelfUpdateCacheTtl)
}

function Write-SelfUpdateCache {
    param(
        [string]$Path,
        [int64]$CheckedAt,
        [string]$LatestTag
    )

    if (-not $Path -or [string]::IsNullOrWhiteSpace($LatestTag)) {
        return $false
    }

    try {
        $dir = Split-Path -Parent $Path
        if ($dir) {
            $null = New-Item -ItemType Directory -Path $dir -Force
        }
        $temp = Join-Path $dir ('.cache-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        $content = @(
            ("checked_at={0}" -f $CheckedAt)
            ("latest_tag={0}" -f $LatestTag)
            ''
        ) -join "`n"
        [System.IO.File]::WriteAllText($temp, $content, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $Path -Force
        return $true
    } catch {
        return $false
    }
}

function Invoke-SelfUpdatedRelaunch {
    param([string[]]$OriginalArgs)

    $env:UPDATES_SELF_UPDATED = '1'
    & (Join-Path $script:InstallRoot 'updates.cmd') @OriginalArgs
    return $LASTEXITCODE
}

function Invoke-WindowsSelfUpdate {
    param([string[]]$OriginalArgs)

    if (-not $script:SelfUpdate) { return }
    if ($env:UPDATES_SELF_UPDATE -eq '0') { return }
    if ($env:CI) { return }
    if ($env:UPDATES_SELF_UPDATED -eq '1') { return }
    if ($script:DryRun) { return }
    if (-not (Test-InstallRootWritable)) {
        Write-WarnLine ("updates: self-update skipped because '{0}' is not user-writable." -f $script:InstallRoot)
        return
    }
    if (Test-GitCheckout) {
        Write-DebugLine 'self-update: running from a git checkout; skipping'
        return
    }
    if (Test-SymlinkedInstall) {
        Write-WarnLine 'updates: self-update skipped because the install uses symlinked entrypoints.'
        return
    }

    $receipt = Get-InstallReceipt
    if ($null -eq $receipt) {
        return
    }

    $cachePath = Get-SelfUpdateCachePath
    $currentEpoch = Get-SelfUpdateEpoch
    $latestTag = $null
    $latestVersion = $null
    $releaseDraft = $false
    $releasePrerelease = $false
    $releaseImmutable = $false
    $assets = @{}
    if (-not $script:ForceSelfUpdate) {
        $cache = Read-SelfUpdateCache -Path $cachePath
        if ($cache -and (Test-SelfUpdateCacheFresh -CurrentEpoch $currentEpoch -CheckedAt $cache.CheckedAt)) {
            $cachedTag = [string]$cache.LatestTag
            if ($cachedTag -match '^v?(\d+\.\d+\.\d+)$') {
                $cachedVersion = $Matches[1]
                if ([version]$cachedVersion -le [version]$script:UpdatesVersion) {
                    Write-DebugLine ("self-update: using cached release tag ({0}) from {1}" -f $cachedTag, $cachePath)
                    return
                }
                # A newer cached tag is only a hint. URLs, digests, and trust state must
                # always come from fresh canonical GitHub release metadata.
                Write-DebugLine ("self-update: cached release tag ({0}) is newer; fetching live metadata" -f $cachedTag)
            }
        }
    }

    if (-not $latestVersion) {
        $release = $null
        try {
            $release = Get-LatestReleaseMetadata
        } catch {
            Write-WarnLine 'updates: self-update metadata fetch failed; continuing.'
            return
        }

        $latestTag = [string]$release.tag_name
        if ($latestTag -notmatch '^v?(\d+\.\d+\.\d+)$') {
            Write-WarnLine 'updates: self-update metadata returned an invalid tag; continuing.'
            return
        }
        $latestVersion = $Matches[1]
        $releaseDraft = [bool]$release.draft
        $releasePrerelease = [bool]$release.prerelease
        $releaseImmutable = [bool]$release.immutable
        $assets = Get-ReleaseAssetMap -Release $release

        $windowsAsset = if ($assets.ContainsKey($script:WindowsAssetName)) { $assets[$script:WindowsAssetName] } else { $null }
        $manifestAsset = if ($assets.ContainsKey($script:ReleaseManifestName)) { $assets[$script:ReleaseManifestName] } else { $null }
        $sumsAsset = if ($assets.ContainsKey($script:ChecksumAssetName)) { $assets[$script:ChecksumAssetName] } else { $null }
        $windowsUrl = if ($null -ne $windowsAsset) { [string]$windowsAsset.browser_download_url } else { '' }
        $windowsDigest = if ($null -ne $windowsAsset) { [string]$windowsAsset.digest } else { '' }
        $manifestUrl = if ($null -ne $manifestAsset) { [string]$manifestAsset.browser_download_url } else { '' }
        $manifestDigest = if ($null -ne $manifestAsset) { [string]$manifestAsset.digest } else { '' }
        $sumsUrl = if ($null -ne $sumsAsset) { [string]$sumsAsset.browser_download_url } else { '' }
        $sumsDigest = if ($null -ne $sumsAsset) { [string]$sumsAsset.digest } else { '' }
        $null = Write-SelfUpdateCache `
            -Path $cachePath `
            -CheckedAt $currentEpoch `
            -LatestTag $latestTag

        if ([version]$latestVersion -le [version]$script:UpdatesVersion) {
            return
        }
    }

    if ($releaseDraft -or $releasePrerelease -or (-not $releaseImmutable)) {
        Write-WarnLine 'updates: self-update release metadata did not satisfy trust requirements; continuing.'
        return
    }

    foreach ($name in @($script:WindowsAssetName, $script:ReleaseManifestName, $script:ChecksumAssetName)) {
        if (-not $assets.ContainsKey($name)) {
            Write-WarnLine 'updates: self-update release assets are incomplete; continuing.'
            return
        }
        if (-not $assets[$name].digest) {
            Write-WarnLine 'updates: self-update release asset digests are incomplete; continuing.'
            return
        }
    }

    Write-WarnLine ("updates: self-update available ({0} -> {1})" -f $script:UpdatesVersion, $latestVersion)

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('updates-self-update-{0}' -f ([guid]::NewGuid().ToString('N')))
    $null = New-Item -ItemType Directory -Path $tempRoot -Force
    $ownedStagingRoot = $null
    try {
        $zipPath = Join-Path $tempRoot $script:WindowsAssetName
        $manifestPath = Join-Path $tempRoot $script:ReleaseManifestName
        $sumsPath = Join-Path $tempRoot $script:ChecksumAssetName
        Download-ReleaseAsset -Uri $assets[$script:WindowsAssetName].browser_download_url -OutFile $zipPath
        Download-ReleaseAsset -Uri $assets[$script:ReleaseManifestName].browser_download_url -OutFile $manifestPath
        Download-ReleaseAsset -Uri $assets[$script:ChecksumAssetName].browser_download_url -OutFile $sumsPath

        if ((Get-Sha256Digest -Path $zipPath) -ne [string]$assets[$script:WindowsAssetName].digest) {
            Write-WarnLine 'updates: self-update zip digest mismatch; continuing.'
            return
        }
        if ((Get-Sha256Digest -Path $manifestPath) -ne [string]$assets[$script:ReleaseManifestName].digest) {
            Write-WarnLine 'updates: self-update manifest digest mismatch; continuing.'
            return
        }
        if ((Get-Sha256Digest -Path $sumsPath) -ne [string]$assets[$script:ChecksumAssetName].digest) {
            Write-WarnLine 'updates: self-update checksum digest mismatch; continuing.'
            return
        }
        if (-not (Test-ReleaseManifest -ManifestPath $manifestPath -ExpectedVersion $latestVersion)) {
            Write-WarnLine 'updates: self-update manifest is invalid; continuing.'
            return
        }

        $sumPattern = ('^([0-9a-fA-F]{{64}})\s+{0}$' -f [regex]::Escape($script:WindowsAssetName))
        $sumEntry = Select-String -LiteralPath $sumsPath -Pattern $sumPattern | Select-Object -First 1
        if (-not $sumEntry) {
            Write-WarnLine 'updates: self-update checksum entry missing; continuing.'
            return
        }
        $expectedZipHash = $sumEntry.Matches[0].Groups[1].Value.ToLowerInvariant()
        $actualZipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expectedZipHash -ne $actualZipHash) {
            Write-WarnLine 'updates: self-update checksum mismatch; continuing.'
            return
        }

        $extractRoot = Join-Path $tempRoot 'extract'
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
        $newVersionRoot = Join-Path $extractRoot (Join-Path 'versions' $latestVersion)
        if (-not (Test-VersionedPayloadManifest -VersionRoot $newVersionRoot -ExpectedVersion $latestVersion)) {
            Write-WarnLine 'updates: self-update extracted manifest is invalid; continuing.'
            return
        }

        $versionsRoot = Join-Path $script:InstallRoot 'versions'
        $stagingRoot = Join-Path $versionsRoot ("{0}.{1}.staging" -f $latestVersion, [guid]::NewGuid().ToString('N'))
        $targetRoot = Join-Path $versionsRoot $latestVersion
        if (-not (Test-SelfUpdateMutationRootsSafe -VersionsRoot $versionsRoot -StagingRoot $stagingRoot -TargetRoot $targetRoot)) {
            Write-WarnLine 'updates: self-update install paths are redirected or unsafe; continuing.'
            return
        }
        $ownedStagingRoot = $stagingRoot
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        }
        Copy-Item -LiteralPath $newVersionRoot -Destination $stagingRoot -Recurse -Force
        Invoke-SelfUpdateCommitHook -Step 'payload-staged'
        if (-not (Test-VersionedPayloadManifest -VersionRoot $stagingRoot -ExpectedVersion $latestVersion)) {
            throw 'self-update staged payload failed validation'
        }
        Invoke-SelfUpdateCommitHook -Step 'payload-validated'
        if (Test-Path -LiteralPath $targetRoot) {
            if (Test-VersionedPayloadManifest -VersionRoot $targetRoot -ExpectedVersion $latestVersion) {
                Remove-Item -LiteralPath $stagingRoot -Recurse -Force
            } else {
                Remove-Item -LiteralPath $targetRoot -Recurse -Force
                Move-Item -LiteralPath $stagingRoot -Destination $targetRoot
            }
        } else {
            Move-Item -LiteralPath $stagingRoot -Destination $targetRoot
        }
        Invoke-SelfUpdateCommitHook -Step 'target-committed'

        # Preserve the validated running payload version even if bootstrap recovered via previous.txt.
        Commit-SelfUpdateMetadata -PreviousVersion $script:UpdatesVersion -InstalledVersion $latestVersion

        Write-WarnLine ("updates: updated to {0}; restarting" -f $latestVersion)
        return [pscustomobject]@{
            Relaunched = $true
            ExitCode   = (Invoke-SelfUpdatedRelaunch -OriginalArgs $OriginalArgs)
        }
    }
    catch {
        Write-DebugLine ("self-update: non-fatal failure during asset download or staging: {0}" -f $_.Exception.Message)
        Write-WarnLine 'updates: self-update asset download or staging failed; continuing.'
        return
    }
    finally {
        try {
            if ($ownedStagingRoot -and (Test-Path -LiteralPath $ownedStagingRoot)) {
                $versionsRoot = Join-Path $script:InstallRoot 'versions'
                $targetRoot = Join-Path $versionsRoot $latestVersion
                $stagingItem = Get-Item -LiteralPath $ownedStagingRoot -Force -ErrorAction Stop
                if (
                    [System.IO.Path]::GetFileName($ownedStagingRoot) -match ('^{0}\.[0-9a-f]{{32}}\.staging$' -f [regex]::Escape($latestVersion)) -and
                    ($stagingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and
                    (Test-SelfUpdateMutationRootsSafe -VersionsRoot $versionsRoot -StagingRoot $ownedStagingRoot -TargetRoot $targetRoot)
                ) {
                    Remove-Item -LiteralPath $ownedStagingRoot -Recurse -Force -ErrorAction Stop
                }
            }
        } catch {
            # Preserve the original self-update result; never follow or broaden cleanup past the owned staging root.
        }
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Invoke-SelectedModules {
    $selected = Get-SelectedModules
    $startAt = Get-Date

    foreach ($moduleName in $selected) {
        Write-ModuleStartEvent -ModuleName $moduleName
        Write-ProgressLine (Format-BoundaryStart -ModuleName $moduleName)
        $script:CurrentModule = $moduleName
        $moduleStart = Get-Date
        $rc = Invoke-Module -ModuleName $moduleName
        $script:CurrentModule = 'main'
        $seconds = [int][Math]::Round(((Get-Date) - $moduleStart).TotalSeconds)
        $stopAfterFailure = $false

        switch ($rc) {
            0 {
                $script:Successes.Add($moduleName)
                Write-ModuleEndEvent -ModuleName $moduleName -Status 'ok' -Seconds $seconds
                Write-ProgressLine (Format-BoundaryEnd -ModuleName $moduleName -Status 'OK' -Seconds $seconds)
            }
            2 {
                $script:Skipped.Add($moduleName)
                Write-ModuleEndEvent -ModuleName $moduleName -Status 'skip' -Seconds $seconds
                Write-ProgressLine (Format-BoundaryEnd -ModuleName $moduleName -Status 'SKIP' -Seconds $seconds)
            }
            default {
                $script:Failures.Add($moduleName)
                Write-ModuleEndEvent -ModuleName $moduleName -Status 'fail' -Seconds $seconds
                Write-ProgressLine (Format-BoundaryEnd -ModuleName $moduleName -Status 'FAIL' -Seconds $seconds)
                if ($script:Strict) {
                    $stopAfterFailure = $true
                }
            }
        }

        if ($stopAfterFailure) {
            break
        }
    }

    $totalSeconds = [int][Math]::Round(((Get-Date) - $startAt).TotalSeconds)
    Write-SummaryEvent -TotalSeconds $totalSeconds
    Write-ProgressLine (Format-Summary -Ok $script:Successes.Count -Skip $script:Skipped.Count -Fail $script:Failures.Count -TotalSeconds $totalSeconds)

    if ($script:Failures.Count -gt 0) {
        Write-ErrorLine ("Completed in {0}s with failures: {1}" -f $totalSeconds, (($script:Failures | ForEach-Object { $_ }) -join ' '))
        return 1
    }

    Write-LogLine ("Done in {0}s." -f $totalSeconds)
    return 0
}

function Invoke-WindowsDoctor {
    $counts = @{ ok = 0; warn = 0; fail = 0 }
    function Add-DoctorCheck {
        param([string]$Check, [string]$Status, [string]$Message)
        $counts[$Status]++
        Write-JsonEvent @{ event = 'doctor_check'; check = $Check; status = $Status; message = $Message }
        if (-not $script:JsonMode) {
            [Console]::Out.WriteLine(('{0,-5} {1,-20} {2}' -f $Status.ToUpperInvariant(), $Check, $Message))
        }
    }

    $bootstrapFiles = @('updates.cmd', 'updates.ps1')
    $missingBootstrap = @($bootstrapFiles | Where-Object { -not (Test-ContainedRegularFile -RootPath $script:InstallRoot -Path (Join-Path $script:InstallRoot $_)) })
    if ($missingBootstrap.Count -eq 0) {
        Add-DoctorCheck 'bootstrap' 'ok' 'bootstrap entrypoints are present'
    } else {
        Add-DoctorCheck 'bootstrap' 'fail' ("missing, redirected, or outside install root: {0}" -f ($missingBootstrap -join ', '))
    }

    $pointerResults = @{}
    foreach ($pointer in @('current.txt', 'previous.txt')) {
        $path = Join-Path $script:InstallRoot $pointer
        if (-not (Test-ContainedRegularFile -RootPath $script:InstallRoot -Path $path)) {
            $status = if ($pointer -eq 'current.txt') { 'fail' } else { 'warn' }
            Add-DoctorCheck $pointer $status 'pointer is missing, redirected, or outside install root'
            continue
        }
        try {
            $version = ([System.IO.File]::ReadAllText($path)).Trim()
            if ([string]::IsNullOrWhiteSpace($version) -and $pointer -eq 'previous.txt') {
                Add-DoctorCheck $pointer 'ok' 'rollback pointer is empty (fresh install)'
                continue
            }
            if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') { throw 'pointer is not SemVer' }
            $root = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $script:InstallRoot 'versions') $version))
            $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
            if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'payload root is a reparse point' }
            if (-not (Test-VersionedPayloadManifest -VersionRoot $root -ExpectedVersion $version)) { throw 'payload or manifest is invalid' }
            $pointerResults[$pointer] = $version
            Add-DoctorCheck $pointer 'ok' ("valid payload v{0}" -f $version)
        } catch {
            $status = if ($pointer -eq 'current.txt') { 'fail' } else { 'warn' }
            Add-DoctorCheck $pointer $status $_.Exception.Message
        }
    }

    $receiptPath = Join-Path $script:InstallRoot 'install-source.json'
    try {
        if (-not (Test-ContainedRegularFile -RootPath $script:InstallRoot -Path $receiptPath)) { throw 'receipt is missing, redirected, or outside install root' }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        if ($receipt.kind -ne 'standalone' -or $receipt.channel -ne $script:ReleaseChannel -or $receipt.source_repo -ne $script:CanonicalRepo -or $receipt.scope -ne 'user') {
            throw 'receipt does not match the official standalone contract'
        }
        $receiptVersion = [string]$receipt.installed_version
        if ($receiptVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') { throw 'installed_version is not SemVer' }
        $receiptRoot = Join-Path (Join-Path $script:InstallRoot 'versions') $receiptVersion
        if (-not (Test-VersionedPayloadManifest -VersionRoot $receiptRoot -ExpectedVersion $receiptVersion)) { throw 'receipt-referenced payload is missing or invalid' }
        Add-DoctorCheck 'install-receipt' 'ok' ("official standalone receipt references valid payload v{0}" -f $receiptVersion)
    } catch {
        Add-DoctorCheck 'install-receipt' 'fail' $_.Exception.Message
    }

    $versionsRoot = Join-Path $script:InstallRoot 'versions'
    $staging = @(if (Test-Path -LiteralPath $versionsRoot -PathType Container) { Get-ChildItem -LiteralPath $versionsRoot -Directory -Filter '*.staging' -ErrorAction SilentlyContinue })
    if ($staging.Count -gt 0) {
        Add-DoctorCheck 'staging' 'warn' ("abandoned staging directories: {0}" -f (($staging | ForEach-Object Name) -join ', '))
    } else {
        Add-DoctorCheck 'staging' 'ok' 'no abandoned staging directories'
    }

    try {
        $item = Get-Item -LiteralPath $script:InstallRoot -Force -ErrorAction Stop
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'install root is a reparse point' }
        $versionsItem = Get-Item -LiteralPath $versionsRoot -Force -ErrorAction Stop
        if ($versionsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'versions root is a reparse point' }
        foreach ($version in @($pointerResults.Values)) {
            $versionItem = Get-Item -LiteralPath (Join-Path $versionsRoot $version) -Force -ErrorAction Stop
            if ($versionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw ("payload root v{0} is a reparse point" -f $version) }
        }
        $writeAccess = Get-PathEffectiveWriteAccess -Path $script:InstallRoot
        if ($null -eq $writeAccess) {
            Add-DoctorCheck 'install-root' 'warn' 'paths are accessible and not reparse points; effective write access could not be determined'
        } elseif ($writeAccess) {
            Add-DoctorCheck 'install-root' 'ok' 'paths are accessible, contained, and effectively writable'
        } else {
            Add-DoctorCheck 'install-root' 'fail' 'install root is not effectively writable'
        }
    } catch {
        Add-DoctorCheck 'install-root' 'fail' $_.Exception.Message
    }

    Write-JsonEvent @{ event = 'doctor_summary'; ok = $counts.ok; warn = $counts.warn; fail = $counts.fail }
    if (-not $script:JsonMode) {
        [Console]::Out.WriteLine(('SUMMARY ok={0} warn={1} fail={2}' -f $counts.ok, $counts.warn, $counts.fail))
    }
    if ($counts.fail -gt 0) { return 1 }
    return 0
}

function Invoke-UpdatesMain {
    PreScan-NoConfig -CliInput $script:EffectiveCliArgs
    Read-Config
    Parse-Args -CliInput $script:EffectiveCliArgs

    if (Test-Path Env:UPDATES_SELF_UPDATE_REPO) {
        Fail-Usage ("UPDATES_SELF_UPDATE_REPO is no longer supported in v2.0.0; self-update is fixed to {0}" -f $script:CanonicalRepo)
    }

    if ($script:DoctorMode) {
        return (Invoke-WindowsDoctor)
    }
    Ensure-LogFileReady
    Validate-OnlyModulesSupported
    $selfUpdateResult = Invoke-WindowsSelfUpdate -OriginalArgs $script:EffectiveCliArgs
    if ($selfUpdateResult -and $selfUpdateResult.Relaunched) {
        return [int]$selfUpdateResult.ExitCode
    }

    Write-DebugLine ("log-level: {0}" -f $script:LogLevel)
    Write-LogLine 'Starting updates...'
    return (Invoke-SelectedModules)
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

exit (Invoke-UpdatesMain)
