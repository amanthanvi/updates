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

$script:UpdatesVersion = '2.0.0'
$script:CanonicalRepo = 'amanthanvi/updates'
$script:ReleaseChannel = 'github-release'
$script:ReleaseManifestName = 'updates-release.json'
$script:WindowsAssetName = 'updates-windows.zip'
$script:ChecksumAssetName = 'SHA256SUMS'
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
$script:PipForce = $false
$script:Parallel = $null
$script:LogFile = $null
$script:GoBinaries = ''
$script:ReposDir = ''
$script:MasUpgrade = $false
$script:MacosUpdates = $false

$script:ModuleRegistry = @(
    [ordered]@{ Name = 'brew';   Platforms = @('macos', 'linux'); Default = $true;  Description = 'Update Homebrew formulae (+ optional casks)' },
    [ordered]@{ Name = 'shell';  Platforms = @('macos', 'linux'); Default = $true;  Description = 'Update Oh My Zsh and custom git plugins/themes' },
    [ordered]@{ Name = 'repos';  Platforms = @('macos', 'linux'); Default = $true;  Description = 'Update aman dev repos under ~/GitRepos' },
    [ordered]@{ Name = 'linux';  Platforms = @('linux');          Default = $true;  Description = 'Upgrade Linux system packages' },
    [ordered]@{ Name = 'winget'; Platforms = @('windows');        Default = $true;  Description = 'Upgrade Windows packages via winget' },
    [ordered]@{ Name = 'node';   Platforms = @('macos', 'linux', 'windows'); Default = $true; Description = 'Upgrade global npm packages via npm-check-updates' },
    [ordered]@{ Name = 'bun';    Platforms = @('macos', 'linux', 'windows'); Default = $true; Description = 'Update Bun globals (and Bun itself when standalone-installed)' },
    [ordered]@{ Name = 'python'; Platforms = @('macos', 'linux', 'windows'); Default = $true; Description = 'Upgrade global Python packages via pip' },
    [ordered]@{ Name = 'uv';     Platforms = @('macos', 'linux', 'windows'); Default = $true; Description = 'Update uv and uv-managed tools' },
    [ordered]@{ Name = 'mas';    Platforms = @('macos');          Default = $false; Description = 'Upgrade Mac App Store apps via mas (opt-in)' },
    [ordered]@{ Name = 'pipx';   Platforms = @('macos', 'linux', 'windows'); Default = $true; Description = 'Upgrade pipx-managed apps via pipx' },
    [ordered]@{ Name = 'rustup'; Platforms = @('macos', 'linux', 'windows'); Default = $true; Description = 'Update Rust toolchains via rustup' },
    [ordered]@{ Name = 'claude'; Platforms = @('macos', 'linux'); Default = $true; Description = 'Update Claude Code CLI' },
    [ordered]@{ Name = 'pi';     Platforms = @('macos', 'linux'); Default = $true; Description = 'Update pi AI CLI extensions via pi update' },
    [ordered]@{ Name = 'mise';   Platforms = @('macos', 'linux'); Default = $true; Description = 'Update mise and upgrade installed tools' },
    [ordered]@{ Name = 'go';     Platforms = @('macos', 'linux', 'windows'); Default = $true; Description = 'Update Go binaries from GO_BINARIES config' },
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
                if ($value -match '^\d+$' -and [int]$value -ge 1) {
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
            '--full' { $script:MasUpgrade = $true; $script:MacosUpdates = $true }
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
                if ($CliInput[$i] -notmatch '^\d+$' -or [int]$CliInput[$i] -lt 1) {
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
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
        Output   = $stdout + $stderr
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
        if ($result.Stdout) {
            if ($script:JsonMode) {
                [Console]::Error.Write($result.Stdout)
            } else {
                [Console]::Out.Write($result.Stdout)
            }
        }
        if ($result.Stderr) {
            [Console]::Error.Write($result.Stderr)
        }
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

function Resolve-NcuRunner {
    $path = Resolve-ApplicationCommand @('ncu.cmd', 'ncu')
    if ($path) {
        return [pscustomobject]@{
            FilePath = $path
            Prefix   = @('-g', '--jsonUpgraded')
            Label    = ((Split-Path -Leaf $path) + ' -g --jsonUpgraded')
        }
    }

    $npx = Resolve-ApplicationCommand @('npx.cmd', 'npx')
    if ($npx) {
        return [pscustomobject]@{
            FilePath = $npx
            Prefix   = @('--yes', 'npm-check-updates', '-g', '--jsonUpgraded')
            Label    = 'npx --yes npm-check-updates -g --jsonUpgraded'
        }
    }

    return $null
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
        Write-LogLine 'Skipping winget: winget not found.'
        return 2
    }

    $args = @('upgrade', '--all', '--silent', '--accept-source-agreements', '--accept-package-agreements')
    if ($script:DryRun) {
        Write-LogLine ("DRY RUN: {0}" -f (Format-Command (@($winget) + $args)))
        return 0
    }

    $result = Invoke-LoggedProcess -FilePath $winget -ArgumentList $args
    if ($result.ExitCode -ne 0) {
        Write-ErrorLine 'winget: upgrade failed'
        return 1
    }
    return 0
}

function Invoke-ModuleNode {
    $runner = Resolve-NcuRunner
    if (-not $runner) {
        Write-LogLine 'Skipping node: npm-check-updates not available (need ncu or npx).'
        return 2
    }

    $npm = Resolve-ApplicationCommand @('npm.cmd', 'npm')
    if (-not $npm) {
        Write-LogLine 'Skipping node: npm not found.'
        return 2
    }

    if ($script:DryRun) {
        Write-LogLine ("DRY RUN: {0}" -f $runner.Label)
        Write-LogLine ("DRY RUN: {0}" -f (Format-Command @($npm, 'install', '-g', '--', '<packages...>')))
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
        Write-LogLine 'All global npm packages are up-to-date.'
        return 0
    }

    $installArgs = @('install', '-g', '--') + @($packages)
    $installResult = Invoke-LoggedProcess -FilePath $npm -ArgumentList $installArgs
    if ($installResult.ExitCode -ne 0) {
        Write-ErrorLine 'node: npm install failed'
        return 1
    }
    return 0
}

function Invoke-ModuleBun {
    $bun = Resolve-ApplicationCommand @('bun.exe', 'bun')
    if (-not $bun) {
        Write-LogLine 'Skipping bun: bun not found.'
        return 2
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
        Write-LogLine 'Skipping python: no supported Python launcher found.'
        return 2
    }

    $pipVersion = Invoke-CapturedProcess -FilePath $python.FilePath -ArgumentList ($python.Prefix + @('-m', 'pip', '--version'))
    if ($pipVersion.ExitCode -ne 0) {
        Write-LogLine ("Skipping python: pip not available ({0} -m pip)." -f $python.Label)
        return 2
    }

    $listArgs = $python.Prefix + @('-m', 'pip', '--disable-pip-version-check', 'list', '--outdated', '--format=json')
    $installPrefix = $python.Prefix + @('-m', 'pip', '--disable-pip-version-check', 'install', '-U')
    if ($script:NonInteractive) {
        $installPrefix += '--no-input'
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
        Write-LogLine 'Skipping uv: uv not found.'
        return 2
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
        Write-LogLine 'Skipping pipx: pipx not found.'
        return 2
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
        Write-LogLine 'Skipping rustup: rustup not found.'
        return 2
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
        Write-LogLine 'Skipping go: go not found.'
        return 2
    }
    if ([string]::IsNullOrWhiteSpace($script:GoBinaries)) {
        Write-LogLine 'Skipping go: GO_BINARIES not configured.'
        return 2
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
        Write-LogLine 'Skipping go: GO_BINARIES is empty.'
        return 2
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

function Invoke-Module {
    param([string]$ModuleName)

    switch ($ModuleName) {
        'winget' { return Invoke-ModuleWinget }
        'node' { return Invoke-ModuleNode }
        'bun' { return Invoke-ModuleBun }
        'python' { return Invoke-ModulePython }
        'uv' { return Invoke-ModuleUv }
        'pipx' { return Invoke-ModulePipx }
        'rustup' { return Invoke-ModuleRustup }
        'go' { return Invoke-ModuleGo }
        default {
            Write-LogLine ("Skipping {0}: module is not implemented on native Windows." -f $ModuleName)
            return 2
        }
    }
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
        if ($script:ConfigSkipModules.Contains($module.Name)) {
            continue
        }
        if (-not $module.Default) {
            continue
        }
        if (-not (Test-ModuleSupported -Name $module.Name)) {
            continue
        }
        $selected.Add($module.Name)
    }
    return $selected
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
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }

    try {
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

    return (Test-Path -LiteralPath (Join-Path $VersionRoot 'updates-main.ps1') -PathType Leaf)
}

function Update-InstallReceiptVersion {
    param([string]$Version)

    $receiptPath = Join-Path $script:InstallRoot 'install-source.json'
    $receipt = (Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable)
    $receipt.installed_version = $Version
    ($receipt | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
}

function Write-VersionPointer {
    param(
        [string]$Name,
        [string]$Value
    )

    $target = Join-Path $script:InstallRoot $Name
    $temp = Join-Path $script:InstallRoot ('.{0}.{1}.tmp' -f $Name, [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($temp, ($Value + "`n"), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $target -Force
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
    if ([version]$latestVersion -le [version]$script:UpdatesVersion) {
        return
    }
    if ($release.draft -or $release.prerelease -or (-not $release.immutable)) {
        Write-WarnLine 'updates: self-update release metadata did not satisfy trust requirements; continuing.'
        return
    }

    $assets = Get-ReleaseAssetMap -Release $release
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
    try {
        $zipPath = Join-Path $tempRoot $script:WindowsAssetName
        $manifestPath = Join-Path $tempRoot $script:ReleaseManifestName
        $sumsPath = Join-Path $tempRoot $script:ChecksumAssetName
        $headers = @{ 'User-Agent' = 'updates' }

        Invoke-WebRequest -Uri $assets[$script:WindowsAssetName].browser_download_url -Headers $headers -OutFile $zipPath
        Invoke-WebRequest -Uri $assets[$script:ReleaseManifestName].browser_download_url -Headers $headers -OutFile $manifestPath
        Invoke-WebRequest -Uri $assets[$script:ChecksumAssetName].browser_download_url -Headers $headers -OutFile $sumsPath

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

        $sumEntry = Select-String -LiteralPath $sumsPath -Pattern ('\s{0}$' -f [regex]::Escape($script:WindowsAssetName)) | Select-Object -First 1
        if (-not $sumEntry) {
            Write-WarnLine 'updates: self-update checksum entry missing; continuing.'
            return
        }
        $expectedZipHash = ($sumEntry.Line -split '\s+')[0].ToLowerInvariant()
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
        $stagingRoot = Join-Path $versionsRoot ("{0}.staging" -f $latestVersion)
        $targetRoot = Join-Path $versionsRoot $latestVersion
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        }
        Copy-Item -LiteralPath $newVersionRoot -Destination $stagingRoot -Recurse -Force
        if (Test-Path -LiteralPath $targetRoot) {
            Remove-Item -LiteralPath $targetRoot -Recurse -Force
        }
        Move-Item -LiteralPath $stagingRoot -Destination $targetRoot

        $currentVersion = (Get-Content -LiteralPath (Join-Path $script:InstallRoot 'current.txt') -Raw).Trim()
        Write-VersionPointer -Name 'previous.txt' -Value $currentVersion
        Write-VersionPointer -Name 'current.txt' -Value $latestVersion
        Update-InstallReceiptVersion -Version $latestVersion

        Write-WarnLine ("updates: updated to {0}; restarting" -f $latestVersion)
        return [pscustomobject]@{
            Relaunched = $true
            ExitCode   = (Invoke-SelfUpdatedRelaunch -OriginalArgs $OriginalArgs)
        }
    }
    finally {
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
                    break
                }
            }
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

function Invoke-UpdatesMain {
    PreScan-NoConfig -CliInput $script:EffectiveCliArgs
    Read-Config
    Parse-Args -CliInput $script:EffectiveCliArgs

    if (-not [string]::IsNullOrWhiteSpace($env:UPDATES_SELF_UPDATE_REPO)) {
        Fail-Usage ("UPDATES_SELF_UPDATE_REPO is no longer supported in v2.0.0; self-update is fixed to {0}" -f $script:CanonicalRepo)
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
