param(
    [string]$Filter = '.*',
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'helpers/windows_test_lib.ps1')

if (-not $IsWindows) {
    Write-Host 'SKIP: Windows-native tests require Windows.'
    exit 0
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Should-RunTest {
    param(
        [string]$Name
    )

    return $Name -match $Filter
}

function Invoke-WithTempInstall {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Body
    )

    $installRoot = New-TestRoot -Prefix 'updates-native-install'
    try {
        & $Body $installRoot
    } finally {
        if (-not $KeepTemp) {
            Remove-TestRoot -Path $installRoot
        }
    }
}

function New-SelfUpdateFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [int]$PayloadBootstrapMin = 1
    )

    $fixtureRoot = Join-Path $Root ('release-fixture-' + [guid]::NewGuid().ToString('N'))
    $assetRoot = Join-Path $fixtureRoot 'windows-root'
    $zipPath = Join-Path $fixtureRoot 'updates-windows.zip'
    $releaseManifestPath = Join-Path $fixtureRoot 'updates-release.json'
    $sumsPath = Join-Path $fixtureRoot 'SHA256SUMS'

    Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $assetRoot -Version $Version -WithReceipt
    if ($PayloadBootstrapMin -ne 1) {
        $payloadManifestPath = Join-Path $assetRoot (Join-Path 'versions' (Join-Path $Version 'manifest.json'))
        Write-JsonFile -Path $payloadManifestPath -Data ([ordered]@{
            version       = $Version
            bootstrap_min = $PayloadBootstrapMin
            entry_script  = 'updates-main.ps1'
        })
    }

    Compress-Archive -Path (Join-Path $assetRoot '*') -DestinationPath $zipPath -Force

    Write-JsonFile -Path $releaseManifestPath -Data ([ordered]@{
        version       = $Version
        source_repo   = 'amanthanvi/updates'
        channel       = 'github-release'
        bootstrap_min = 1
        windows_asset = 'updates-windows.zip'
        unix_asset    = 'updates'
        checksum_asset = 'SHA256SUMS'
    })

    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8NoBom -Path $sumsPath -Content ($zipHash + '  updates-windows.zip' + "`n")

    return [pscustomobject]@{
        ZipPath          = $zipPath
        ZipDigest        = 'sha256:' + $zipHash
        ReleaseManifest  = $releaseManifestPath
        ReleaseDigest    = 'sha256:' + ((Get-FileHash -LiteralPath $releaseManifestPath -Algorithm SHA256).Hash.ToLowerInvariant())
        SumsPath         = $sumsPath
        SumsDigest       = 'sha256:' + ((Get-FileHash -LiteralPath $sumsPath -Algorithm SHA256).Hash.ToLowerInvariant())
    }
}

if (Should-RunTest 'updates.cmd invokes sibling bootstrap with pwsh flags and preserves exit code') {
    Invoke-TestCase 'updates.cmd invokes sibling bootstrap with pwsh flags and preserves exit code' {
        Invoke-WithTempInstall {
            param($installRoot)

            Copy-RepoWindowsCmd -RepoRoot $repoRoot -InstallRoot $installRoot
            $wrapperText = Get-Content -LiteralPath (Join-Path $installRoot 'updates.cmd') -Raw
            Assert-Match -Text $wrapperText -Pattern '(?i)\bpwsh(\.exe)?\b' -Message 'updates.cmd should invoke pwsh'
            Assert-Match -Text $wrapperText -Pattern '(?i)-NoLogo' -Message 'updates.cmd should pass -NoLogo'
            Assert-Match -Text $wrapperText -Pattern '(?i)-NoProfile' -Message 'updates.cmd should pass -NoProfile'
            Assert-Match -Text $wrapperText -Pattern '(?i)-ExecutionPolicy\s+Bypass' -Message 'updates.cmd should set ExecutionPolicy Bypass'
            Assert-Match -Text $wrapperText -Pattern '(?i)updates\.ps1' -Message 'updates.cmd should target the sibling updates.ps1 bootstrap'
            Assert-Match -Text $wrapperText -Pattern '(?i)%ERRORLEVEL%' -Message 'updates.cmd should preserve the child exit code'

            $argsLog = Join-Path $installRoot 'pwsh-args.log'
            $quotedArgsLog = Quote-PowerShellLiteral -Value $argsLog
            $bootstrap = @'
[System.IO.File]::WriteAllText(__ARGS_LOG__, ($args -join "`n"))
exit 27
'@ -replace '__ARGS_LOG__', $quotedArgsLog
            Write-Utf8NoBom -Path (Join-Path $installRoot 'updates.ps1') -Content $bootstrap

            $result = Invoke-Launcher -InstallRoot $installRoot -ArgumentList @('--version', '--json')

            Assert-Equal -Expected 27 -Actual $result.ExitCode -Message 'updates.cmd should return the bootstrap exit code unchanged'
            $loggedArgs = Get-Content -LiteralPath $argsLog -Raw
            Assert-Match -Text $loggedArgs -Pattern '(?m)^--version$' -Message 'updates.cmd should forward --version to the bootstrap'
            Assert-Match -Text $loggedArgs -Pattern '(?m)^--json$' -Message 'updates.cmd should forward --json to the bootstrap'
        }
    }
}

if (Should-RunTest 'updates.ps1 launches the current payload from current.txt') {
    Invoke-TestCase 'updates.ps1 launches the current payload from current.txt' {
        Invoke-WithTempInstall {
            param($installRoot)

            Copy-RepoWindowsBootstrap -RepoRoot $repoRoot -InstallRoot $installRoot

            $marker = Join-Path $installRoot 'current-marker.txt'
            $quotedMarker = Quote-PowerShellLiteral -Value $marker
            $payload = @"
Set-StrictMode -Version Latest
[System.IO.File]::WriteAllText($quotedMarker, 'current')
Write-Output 'current-payload'
exit 0
"@

            New-VersionedPayload -InstallRoot $installRoot -Version '2.0.0' -PayloadContent $payload
            Set-VersionPointers -InstallRoot $installRoot -CurrentVersion '2.0.0'

            $result = Invoke-Bootstrap -InstallRoot $installRoot

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'bootstrap should launch the current payload'
            Assert-FileExists -Path $marker -Message 'current payload should run'
            Assert-Equal -Expected 'current' -Actual ((Get-Content -LiteralPath $marker -Raw).Trim()) -Message 'current payload marker mismatch'
            Assert-Match -Text $result.Stdout -Pattern 'current-payload' -Message 'bootstrap should surface payload stdout'
        }
    }
}

if (Should-RunTest 'updates.cmd forwards --version through bootstrap to the real payload') {
    Invoke-TestCase 'updates.cmd forwards --version through bootstrap to the real payload' {
        Invoke-WithTempInstall {
            param($installRoot)

            Copy-RepoWindowsCmd -RepoRoot $repoRoot -InstallRoot $installRoot
            Copy-RepoWindowsBootstrap -RepoRoot $repoRoot -InstallRoot $installRoot
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            New-VersionedPayload -InstallRoot $installRoot -Version '2.0.0' -PayloadPath $payloadSource
            Set-VersionPointers -InstallRoot $installRoot -CurrentVersion '2.0.0'
            $pwshOnlyPath = @(
                (Split-Path -Parent (Get-PwshPath)),
                (Join-Path $env:SystemRoot 'System32')
            ) -join ';'

            $result = Invoke-Launcher -InstallRoot $installRoot -ArgumentList @('--version') -Environment @{
                PATH = $pwshOnlyPath
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'updates.cmd --version should exit 0'
            Assert-Equal -Expected '2.0.0' -Actual ($result.Stdout.Trim()) -Message 'updates.cmd --version should print the payload version'
        }
    }
}

if (Should-RunTest 'updates.ps1 exits 130 on Ctrl+C') {
    Invoke-TestCase 'updates.ps1 exits 130 on Ctrl+C' {
        Invoke-WithTempInstall {
            param($installRoot)

            Copy-RepoWindowsBootstrap -RepoRoot $repoRoot -InstallRoot $installRoot

            $readyPath = Join-Path $installRoot 'ctrl-c-ready.txt'
            $quotedReadyPath = Quote-PowerShellLiteral -Value $readyPath
            $payload = @"
Set-StrictMode -Version Latest
[System.IO.File]::WriteAllText($quotedReadyPath, 'ready')
while (`$true) {
    Start-Sleep -Milliseconds 200
}
"@

            New-VersionedPayload -InstallRoot $installRoot -Version '2.0.0' -PayloadContent $payload
            Set-VersionPointers -InstallRoot $installRoot -CurrentVersion '2.0.0'
            $result = Invoke-WindowsSignalCase -InstallRoot $installRoot -SignalType CtrlC -ReadyPath $readyPath

            Assert-Equal -Expected 0 -Actual $result.helper_exit -Message 'signal helper should succeed for Ctrl+C'
            Assert-Equal -Expected 'ok' -Actual $result.status -Message 'Ctrl+C signal helper status mismatch'
            Assert-Equal -Expected 130 -Actual $result.child_exit -Message 'bootstrap should exit 130 on Ctrl+C'
        }
    }
}

if (Should-RunTest 'updates.ps1 exits 130 on Ctrl+Break') {
    Invoke-TestCase 'updates.ps1 exits 130 on Ctrl+Break' {
        Invoke-WithTempInstall {
            param($installRoot)

            Copy-RepoWindowsBootstrap -RepoRoot $repoRoot -InstallRoot $installRoot

            $readyPath = Join-Path $installRoot 'ctrl-break-ready.txt'
            $quotedReadyPath = Quote-PowerShellLiteral -Value $readyPath
            $payload = @"
Set-StrictMode -Version Latest
[System.IO.File]::WriteAllText($quotedReadyPath, 'ready')
while (`$true) {
    Start-Sleep -Milliseconds 200
}
"@

            New-VersionedPayload -InstallRoot $installRoot -Version '2.0.0' -PayloadContent $payload
            Set-VersionPointers -InstallRoot $installRoot -CurrentVersion '2.0.0'
            $result = Invoke-WindowsSignalCase -InstallRoot $installRoot -SignalType CtrlBreak -ReadyPath $readyPath

            Assert-Equal -Expected 0 -Actual $result.helper_exit -Message 'signal helper should succeed for Ctrl+Break'
            Assert-Equal -Expected 'ok' -Actual $result.status -Message 'Ctrl+Break signal helper status mismatch'
            Assert-Equal -Expected 130 -Actual $result.child_exit -Message 'bootstrap should exit 130 on Ctrl+Break'
        }
    }
}

if (Should-RunTest 'native payload errors when --only selects an unsupported Windows module') {
    Invoke-TestCase 'native payload errors when --only selects an unsupported Windows module' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--no-self-update', '--only', 'brew', '--no-color', '--no-emoji')

            Assert-Equal -Expected 2 -Actual $result.ExitCode -Message '--only brew should be rejected on native Windows'
            Assert-Match -Text $result.Output -Pattern '(?i)brew: module is not supported on this platform' -Message 'unsupported module error should be explicit'
        }
    }
}

if (Should-RunTest 'native payload errors when --only selects a missing Windows dependency') {
    Invoke-TestCase 'native payload errors when --only selects a missing Windows dependency' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot
            $emptyPath = Join-Path $installRoot 'empty-path'
            $null = New-Item -ItemType Directory -Path $emptyPath -Force

            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--no-self-update', '--only', 'winget', '--no-color', '--no-emoji') -Environment @{
                PATH        = $emptyPath
                HOME        = $installRoot
                USERPROFILE = $installRoot
            }

            Assert-Equal -Expected 1 -Actual $result.ExitCode -Message '--only winget should fail when winget is missing'
            Assert-Match -Text $result.Output -Pattern '(?i)winget: winget not found' -Message 'missing winget dependency should be explicit in --only mode'
        }
    }
}

if (Should-RunTest 'native payload --full overrides config skips for supported Windows modules') {
    Invoke-TestCase 'native payload --full overrides config skips for supported Windows modules' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'winget.cmd') -Lines @()
            Write-Utf8NoBom -Path (Join-Path $installRoot '.updatesrc') -Content "SKIP_MODULES=winget`n"

            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--dry-run',
                '--full',
                '--skip', 'node,bun,python,uv,pipx,rustup,go',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message '--full should still succeed on native Windows'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*winget(\.cmd)? upgrade --all --silent --accept-source-agreements --accept-package-agreements' -Message '--full should override config SKIP_MODULES for supported Windows modules'
        }
    }
}

if (Should-RunTest 'native payload dry-run covers winget, node fallback, bun, python, uv, pipx, rustup, and go') {
    Invoke-TestCase 'native payload dry-run covers winget, node fallback, bun, python, uv, pipx, rustup, and go' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'winget.cmd') -Lines @()
            Write-CmdStub -Path (Join-Path $stubDir 'npx.cmd') -Lines @()
            Write-CmdStub -Path (Join-Path $stubDir 'npm.cmd') -Lines @()
            Write-CmdStub -Path (Join-Path $stubDir 'bun.cmd') -Lines @()
            Write-CmdStub -Path (Join-Path $stubDir 'py.cmd') -Lines @(
                'if "%~1"=="-3" shift',
                'if "%~1"=="-c" exit /b 0',
                'if "%~1"=="-m" if "%~2"=="pip" if "%~3"=="--version" echo pip 25.0 from py-stub'
            )
            Write-CmdStub -Path (Join-Path $stubDir 'uv.cmd') -Lines @()
            Write-CmdStub -Path (Join-Path $stubDir 'pipx.cmd') -Lines @()
            Write-CmdStub -Path (Join-Path $stubDir 'rustup.cmd') -Lines @()
            Write-CmdStub -Path (Join-Path $stubDir 'go.cmd') -Lines @()
            Write-Utf8NoBom -Path (Join-Path $installRoot '.updatesrc') -Content "GO_BINARIES=example.com/cmd/foo example.com/cmd/bar@v1.2.3`n"

            $envMap = @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
            }

            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--dry-run',
                '--only', 'winget,node,bun,python,uv,pipx,rustup,go',
                '--no-color',
                '--no-emoji'
            ) -Environment $envMap

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'dry-run module coverage should succeed'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*winget(\.cmd)? upgrade --all --silent --accept-source-agreements --accept-package-agreements' -Message 'winget dry-run command mismatch'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: npx --yes npm-check-updates -g --jsonUpgraded' -Message 'node should fall back to npx when ncu is absent'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*npm(\.cmd)? install -g -- <packages\.\.\.>' -Message 'node dry-run install command mismatch'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*bun(\.cmd)? update -g' -Message 'bun dry-run command mismatch'
            Assert-Match -Text $result.Output -Pattern '(?i)bun: skipping bun upgrade because Bun does not appear to be standalone-installed\.' -Message 'bun standalone skip should be explicit'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*py(\.cmd)? -3 -m pip --disable-pip-version-check list --outdated --format=json' -Message 'python should resolve py -3 first on Windows'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*py(\.cmd)? -3 -m pip --disable-pip-version-check install -U <package>' -Message 'python dry-run install command mismatch'
            Assert-Match -Text $result.Output -Pattern '(?i)uv: skipping uv self update because uv does not appear to be standalone-installed\.' -Message 'uv standalone skip should be explicit'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*uv(\.cmd)? tool upgrade --all' -Message 'uv tool upgrade dry-run command mismatch'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*pipx(\.cmd)? upgrade-all' -Message 'pipx dry-run command mismatch'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*rustup(\.cmd)? update' -Message 'rustup dry-run command mismatch'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*go(\.cmd)? install example\.com/cmd/foo@latest' -Message 'go should default missing versions to @latest'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*go(\.cmd)? install example\.com/cmd/bar@v1\.2\.3' -Message 'go should preserve explicit versions'
        }
    }
}

if (Should-RunTest 'native payload strict mode stops after the first module failure') {
    Invoke-TestCase 'native payload strict mode stops after the first module failure' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'winget.cmd') -Lines @(
                'echo winget-failed 1>&2',
                'exit /b 1'
            )
            Write-CmdStub -Path (Join-Path $stubDir 'npx.cmd') -Lines @(
                'echo npx-ran>>"%STRICT_MARKER%"',
                'echo {}'
            )
            Write-CmdStub -Path (Join-Path $stubDir 'npm.cmd') -Lines @(
                'echo npm-ran>>"%STRICT_MARKER%"'
            )

            $markerPath = Join-Path $installRoot 'strict-marker.txt'
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--strict',
                '--only', 'winget,node',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH          = $stubDir
                HOME          = $installRoot
                USERPROFILE   = $installRoot
                STRICT_MARKER = $markerPath
            }

            Assert-Equal -Expected 1 -Actual $result.ExitCode -Message '--strict should return a failing exit code after the first module failure'
            if (Test-Path -LiteralPath $markerPath) {
                throw "--strict should stop before the next module runs.`nMarker contents:`n$(Get-Content -LiteralPath $markerPath -Raw)"
            }
            Assert-Match -Text $result.Output -Pattern '(?i)winget: upgrade failed' -Message 'strict-mode failure should surface the failing module'
        }
    }
}

if (Should-RunTest 'native payload keeps stdout JSON-only when child tools emit output') {
    Invoke-TestCase 'native payload keeps stdout JSON-only when child tools emit output' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot
            $logPath = Join-Path $installRoot 'winget-json.log'

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'winget.cmd') -Lines @(
                'echo winget-stdout',
                'echo winget-stderr 1>&2'
            )

            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--json',
                '--no-self-update',
                '--only', 'winget',
                '--log-file', $logPath,
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'JSON-mode winget run should succeed'
            Assert-Match -Text $result.Stderr -Pattern 'winget-stdout' -Message 'child stdout should be redirected to stderr in JSON mode'
            Assert-Match -Text $result.Stderr -Pattern 'winget-stderr' -Message 'child stderr should remain on stderr in JSON mode'
            if ($result.Stdout -match 'winget-stdout|winget-stderr') {
                throw "child process output leaked into stdout JSON stream:`n$($result.Stdout)"
            }
            foreach ($line in @($result.Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                try {
                    $jsonEvent = $line | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    throw "stdout line was not valid JSON:`n$line"
                }
                Assert-True -Condition ($null -ne $jsonEvent.event) -Message 'each stdout line should be a JSON event object'
            }
            Assert-Match -Text (Get-Content -LiteralPath $logPath -Raw) -Pattern 'winget-stdout' -Message 'child stdout should be mirrored to the log file'
            Assert-Match -Text (Get-Content -LiteralPath $logPath -Raw) -Pattern 'winget-stderr' -Message 'child stderr should be mirrored to the log file'
        }
    }
}

if (Should-RunTest 'native payload rejects --parallel on Windows') {
    Invoke-TestCase 'native payload rejects --parallel on Windows' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--parallel', '2',
                '--only', 'python',
                '--no-color',
                '--no-emoji'
            )

            Assert-Equal -Expected 2 -Actual $result.ExitCode -Message '--parallel should be rejected on native Windows'
            Assert-Match -Text $result.Output -Pattern '(?i)--parallel.*not supported.*native Windows' -Message 'unsupported parallel error should be explicit'
        }
    }
}

if (Should-RunTest 'native payload rejects oversized --parallel values on Windows') {
    Invoke-TestCase 'native payload rejects oversized --parallel values on Windows' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--parallel', '999999999999',
                '--only', 'python',
                '--no-color',
                '--no-emoji'
            )

            Assert-Equal -Expected 2 -Actual $result.ExitCode -Message 'oversized --parallel should stay on the controlled usage path'
            Assert-Match -Text $result.Output -Pattern '(?i)--parallel must be >= 1' -Message 'oversized --parallel should report the normal validation error'
        }
    }
}

if (Should-RunTest 'native payload warns and ignores PARALLEL from config on Windows') {
    Invoke-TestCase 'native payload warns and ignores PARALLEL from config on Windows' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'winget.cmd') -Lines @()
            Write-Utf8NoBom -Path (Join-Path $installRoot '.updatesrc') -Content "PARALLEL=8`n"

            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--dry-run',
                '--only', 'winget',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'config PARALLEL should warn and continue on native Windows'
            Assert-Match -Text $result.Output -Pattern '(?i)config: PARALLEL is ignored on native Windows' -Message 'config PARALLEL warning should be explicit'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*winget(\.cmd)? upgrade --all --silent --accept-source-agreements --accept-package-agreements' -Message 'warning should not block the requested module run'
        }
    }
}

if (Should-RunTest 'native payload warns on oversized PARALLEL config values on Windows') {
    Invoke-TestCase 'native payload warns on oversized PARALLEL config values on Windows' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'winget.cmd') -Lines @()
            Write-Utf8NoBom -Path (Join-Path $installRoot '.updatesrc') -Content "PARALLEL=999999999999`n"

            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--dry-run',
                '--only', 'winget',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'oversized config PARALLEL should warn and continue'
            Assert-Match -Text $result.Output -Pattern '(?i)config: PARALLEL must be >= 1' -Message 'oversized config PARALLEL should stay on the normal warning path'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*winget(\.cmd)? upgrade --all --silent --accept-source-agreements --accept-package-agreements' -Message 'oversized config PARALLEL should not block the requested module run'
        }
    }
}

if (Should-RunTest 'updates.ps1 falls back to previous.txt when current payload is invalid') {
    Invoke-TestCase 'updates.ps1 falls back to previous.txt when current payload is invalid' {
        Invoke-WithTempInstall {
            param($installRoot)

            Copy-RepoWindowsBootstrap -RepoRoot $repoRoot -InstallRoot $installRoot

            $currentRoot = Join-Path $installRoot 'versions\2.0.0'
            $null = New-Item -ItemType Directory -Path $currentRoot -Force
            Write-JsonFile -Path (Join-Path $currentRoot 'manifest.json') -Data ([ordered]@{
                version       = '2.0.0'
                bootstrap_min = 1
                entry_script  = 'updates-main.ps1'
            })

            $marker = Join-Path $installRoot 'previous-marker.txt'
            $quotedMarker = Quote-PowerShellLiteral -Value $marker
            $previousPayload = @"
Set-StrictMode -Version Latest
[System.IO.File]::WriteAllText($quotedMarker, 'previous')
Write-Output 'previous-payload'
exit 0
"@
            New-VersionedPayload -InstallRoot $installRoot -Version '1.9.9' -PayloadContent $previousPayload
            Set-VersionPointers -InstallRoot $installRoot -CurrentVersion '2.0.0' -PreviousVersion '1.9.9'

            $result = Invoke-Bootstrap -InstallRoot $installRoot

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'bootstrap should fall back to previous payload when current is invalid'
            Assert-FileExists -Path $marker -Message 'previous payload should run when fallback is needed'
            Assert-Equal -Expected 'previous' -Actual ((Get-Content -LiteralPath $marker -Raw).Trim()) -Message 'previous payload marker mismatch'
            Assert-Match -Text $result.Stdout -Pattern 'previous-payload' -Message 'bootstrap should surface previous payload stdout after fallback'
        }
    }
}

if (Should-RunTest 'Set-VersionPointers removes stale previous.txt when previous version is omitted') {
    Invoke-TestCase 'Set-VersionPointers removes stale previous.txt when previous version is omitted' {
        Invoke-WithTempInstall {
            param($installRoot)

            Set-VersionPointers -InstallRoot $installRoot -CurrentVersion '2.0.0' -PreviousVersion '1.9.9'
            Assert-FileExists -Path (Join-Path $installRoot 'previous.txt') -Message 'fixture should create previous.txt before removal coverage'

            Set-VersionPointers -InstallRoot $installRoot -CurrentVersion '2.0.1'

            Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $installRoot 'previous.txt') -PathType Leaf)) -Message 'Set-VersionPointers should remove stale previous.txt when no previous version is supplied'
        }
    }
}

if (Should-RunTest 'native payload self-update applies a verified Windows release and updates pointers') {
    Invoke-TestCase 'native payload self-update applies a verified Windows release and updates pointers' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -WithReceipt
            $fixture = New-SelfUpdateFixture -Root $installRoot -Version '2.0.1'
            $logPath = Join-Path $installRoot 'self-update.log'
            $relaunchArgsPath = Join-Path $installRoot 'relaunch-args.txt'
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot

            & {
                . $payloadSource
                $script:InstallRoot = $installRoot
                $script:LogFile = $logPath
                $script:JsonMode = $false
                $script:LogLevel = 'info'
                $script:LogLevelNum = 2
                $script:DryRun = $false
                $script:SelfUpdate = $true

                function Test-InstallRootWritable { return $true }
                function Test-GitCheckout { return $false }
                function Test-SymlinkedInstall { return $false }
                function Get-LatestReleaseMetadata {
                    return [pscustomobject]@{
                        tag_name   = 'v2.0.1'
                        draft      = $false
                        prerelease = $false
                        immutable  = $true
                        assets     = @(
                            [pscustomobject]@{ name = 'updates-windows.zip'; digest = $fixture.ZipDigest; browser_download_url = 'https://example.invalid/updates-windows.zip' },
                            [pscustomobject]@{ name = 'updates-release.json'; digest = $fixture.ReleaseDigest; browser_download_url = 'https://example.invalid/updates-release.json' },
                            [pscustomobject]@{ name = 'SHA256SUMS'; digest = $fixture.SumsDigest; browser_download_url = 'https://example.invalid/SHA256SUMS' }
                        )
                    }
                }
                function Invoke-WebRequest {
                    param([string]$Uri, $Headers, [string]$OutFile, [int]$TimeoutSec)
                    switch ($Uri) {
                        'https://example.invalid/updates-windows.zip' { Copy-Item -LiteralPath $fixture.ZipPath -Destination $OutFile -Force }
                        'https://example.invalid/updates-release.json' { Copy-Item -LiteralPath $fixture.ReleaseManifest -Destination $OutFile -Force }
                        'https://example.invalid/SHA256SUMS' { Copy-Item -LiteralPath $fixture.SumsPath -Destination $OutFile -Force }
                        default { throw "Unexpected download URI: $Uri" }
                    }
                }
                function Invoke-SelfUpdatedRelaunch {
                    param([string[]]$OriginalArgs)
                    [System.IO.File]::WriteAllText($relaunchArgsPath, ($OriginalArgs -join "`n"))
                    return 17
                }

                Ensure-LogFileReady
                $script:SelfUpdateResult = Invoke-WindowsSelfUpdate -OriginalArgs @('--self-update', '--no-color')
            }

            Assert-Equal -Expected '2.0.1' -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()) -Message 'current.txt should advance after a verified self-update'
            Assert-Equal -Expected '2.0.0' -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'previous.txt') -Raw).Trim()) -Message 'previous.txt should preserve the prior version after self-update'
            Assert-Match -Text (Get-Content -LiteralPath (Join-Path $installRoot 'install-source.json') -Raw) -Pattern '"installed_version"\s*:\s*"2\.0\.1"' -Message 'install receipt should be rewritten to the new version'
            Assert-FileExists -Path (Join-Path $installRoot 'versions\2.0.1\updates-main.ps1') -Message 'new version payload should be staged into the install root'
            Assert-Match -Text (Get-Content -LiteralPath $logPath -Raw) -Pattern 'updated to 2\.0\.1; restarting' -Message 'successful self-update should be logged'
            Assert-Equal -Expected 17 -Actual $script:SelfUpdateResult.ExitCode -Message 'self-update should propagate the relaunch exit code'
            Assert-Match -Text (Get-Content -LiteralPath $relaunchArgsPath -Raw) -Pattern '(?m)^--self-update$' -Message 'self-update relaunch should preserve original args'
        }
    }
}

if (Should-RunTest 'native payload self-update preserves rollback pointer during previous.txt recovery') {
    Invoke-TestCase 'native payload self-update preserves rollback pointer during previous.txt recovery' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -WithReceipt
            $fixture = New-SelfUpdateFixture -Root $installRoot -Version '2.0.1'
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot

            Set-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Value 'broken-version' -NoNewline
            Set-Content -LiteralPath (Join-Path $installRoot 'previous.txt') -Value '2.0.0' -NoNewline

            & {
                . $payloadSource
                $script:InstallRoot = $installRoot
                $script:JsonMode = $false
                $script:LogLevel = 'info'
                $script:LogLevelNum = 2
                $script:DryRun = $false
                $script:SelfUpdate = $true

                function Test-InstallRootWritable { return $true }
                function Test-GitCheckout { return $false }
                function Test-SymlinkedInstall { return $false }
                function Get-LatestReleaseMetadata {
                    return [pscustomobject]@{
                        tag_name   = 'v2.0.1'
                        draft      = $false
                        prerelease = $false
                        immutable  = $true
                        assets     = @(
                            [pscustomobject]@{ name = 'updates-windows.zip'; digest = $fixture.ZipDigest; browser_download_url = 'https://example.invalid/updates-windows.zip' },
                            [pscustomobject]@{ name = 'updates-release.json'; digest = $fixture.ReleaseDigest; browser_download_url = 'https://example.invalid/updates-release.json' },
                            [pscustomobject]@{ name = 'SHA256SUMS'; digest = $fixture.SumsDigest; browser_download_url = 'https://example.invalid/SHA256SUMS' }
                        )
                    }
                }
                function Invoke-WebRequest {
                    param([string]$Uri, $Headers, [string]$OutFile, [int]$TimeoutSec)
                    switch ($Uri) {
                        'https://example.invalid/updates-windows.zip' { Copy-Item -LiteralPath $fixture.ZipPath -Destination $OutFile -Force }
                        'https://example.invalid/updates-release.json' { Copy-Item -LiteralPath $fixture.ReleaseManifest -Destination $OutFile -Force }
                        'https://example.invalid/SHA256SUMS' { Copy-Item -LiteralPath $fixture.SumsPath -Destination $OutFile -Force }
                        default { throw "Unexpected download URI: $Uri" }
                    }
                }
                function Invoke-SelfUpdatedRelaunch { return 0 }

                $result = Invoke-WindowsSelfUpdate -OriginalArgs @()
                Assert-True -Condition $result.Relaunched -Message 'verified recovery self-update should still relaunch'
            }

            Assert-Equal -Expected '2.0.1' -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()) -Message 'current.txt should advance after a verified self-update'
            Assert-Equal -Expected '2.0.0' -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'previous.txt') -Raw).Trim()) -Message 'previous.txt should keep the validated running payload version during recovery'
        }
    }
}

if (Should-RunTest 'native payload self-update skips live metadata fetch when cache is fresh') {
    Invoke-TestCase 'native payload self-update skips live metadata fetch when cache is fresh' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -WithReceipt
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            $localAppData = Join-Path $installRoot 'localappdata'
            $null = New-Item -ItemType Directory -Path $localAppData -Force

            & {
                . $payloadSource
                $script:InstallRoot = $installRoot
                $script:JsonMode = $false
                $script:LogLevel = 'debug'
                $script:LogLevelNum = 3
                $script:DryRun = $false
                $script:SelfUpdate = $true
                $script:ForceSelfUpdate = $false
                $env:LOCALAPPDATA = $localAppData

                function Test-InstallRootWritable { return $true }
                function Test-GitCheckout { return $false }
                function Test-SymlinkedInstall { return $false }
                function Get-LatestReleaseMetadata { throw 'Get-LatestReleaseMetadata should not run with a fresh cache' }

                $cachePath = Get-SelfUpdateCachePath
                $null = Write-SelfUpdateCache -Path $cachePath -CheckedAt (Get-SelfUpdateEpoch) -LatestTag 'v2.0.0'
                $result = Invoke-WindowsSelfUpdate -OriginalArgs @()
                Assert-True -Condition ($null -eq $result) -Message 'fresh current-version cache should skip self-update work'
            }
        }
    }
}

if (Should-RunTest 'native payload force self-update bypasses fresh cache') {
    Invoke-TestCase 'native payload force self-update bypasses fresh cache' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -WithReceipt
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            $localAppData = Join-Path $installRoot 'localappdata'
            $markerPath = Join-Path $installRoot 'force-self-update-marker.txt'
            $null = New-Item -ItemType Directory -Path $localAppData -Force

            & {
                . $payloadSource
                $script:InstallRoot = $installRoot
                $script:JsonMode = $false
                $script:LogLevel = 'debug'
                $script:LogLevelNum = 3
                $script:DryRun = $false
                $script:SelfUpdate = $true
                $script:ForceSelfUpdate = $true
                $env:LOCALAPPDATA = $localAppData

                function Test-InstallRootWritable { return $true }
                function Test-GitCheckout { return $false }
                function Test-SymlinkedInstall { return $false }
                function Get-LatestReleaseMetadata {
                    [System.IO.File]::WriteAllText($markerPath, 'fetched')
                    return [pscustomobject]@{
                        tag_name   = 'v2.0.0'
                        draft      = $false
                        prerelease = $false
                        immutable  = $true
                        assets     = @()
                    }
                }

                $cachePath = Get-SelfUpdateCachePath
                $null = Write-SelfUpdateCache -Path $cachePath -CheckedAt (Get-SelfUpdateEpoch) -LatestTag 'v2.0.0'
                $result = Invoke-WindowsSelfUpdate -OriginalArgs @('--self-update')
                Assert-True -Condition ($null -eq $result) -Message 'force-refresh current-version check should still exit cleanly'
            }

            Assert-FileExists -Path $markerPath -Message '--self-update should bypass a fresh cache and fetch live metadata'
            Assert-Equal -Expected 'fetched' -Actual ((Get-Content -LiteralPath $markerPath -Raw).Trim()) -Message 'live metadata marker mismatch'
        }
    }
}

if (Should-RunTest 'native payload hard-errors when UPDATES_SELF_UPDATE_REPO is set') {
    Invoke-TestCase 'native payload hard-errors when UPDATES_SELF_UPDATE_REPO is set' {
        Invoke-WithTempInstall {
            param($installRoot)

            Copy-RepoWindowsBootstrap -RepoRoot $repoRoot -InstallRoot $installRoot
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            New-VersionedPayload -InstallRoot $installRoot -Version '2.0.0' -PayloadPath $payloadSource
            Set-VersionPointers -InstallRoot $installRoot -CurrentVersion '2.0.0'
            Write-InstallReceipt -InstallRoot $installRoot -InstalledVersion '2.0.0'

            $emptyPath = Join-Path $installRoot 'empty-path'
            $null = New-Item -ItemType Directory -Path $emptyPath -Force

            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--no-color', '--no-emoji') -Environment @{
                PATH                     = $emptyPath
                UPDATES_SELF_UPDATE_REPO = 'other/repo'
            }

            Assert-Equal -Expected 2 -Actual $result.ExitCode -Message 'custom self-update repo override should be a usage error on Windows v2'
            Assert-Match -Text $result.Output -Pattern 'UPDATES_SELF_UPDATE_REPO' -Message 'error should reference UPDATES_SELF_UPDATE_REPO explicitly'
            Assert-Match -Text $result.Output -Pattern '(?i)(not supported|no longer supported|unsupported)' -Message 'error should explain that custom self-update repos are not supported'
        }
    }
}

if (Should-RunTest 'native payload self-update skips on release digest mismatch') {
    Invoke-TestCase 'native payload self-update skips on release digest mismatch' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -WithReceipt
            $fixture = New-SelfUpdateFixture -Root $installRoot -Version '2.0.1'
            $logPath = Join-Path $installRoot 'self-update.log'
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot

            & {
                . $payloadSource
                $script:InstallRoot = $installRoot
                $script:LogFile = $logPath
                $script:JsonMode = $false
                $script:LogLevel = 'info'
                $script:LogLevelNum = 2
                $script:DryRun = $false
                $script:SelfUpdate = $true

                function Test-InstallRootWritable { return $true }
                function Test-GitCheckout { return $false }
                function Test-SymlinkedInstall { return $false }
                function Get-LatestReleaseMetadata {
                    return [pscustomobject]@{
                        tag_name   = 'v2.0.1'
                        draft      = $false
                        prerelease = $false
                        immutable  = $true
                        assets     = @(
                            [pscustomobject]@{ name = 'updates-windows.zip'; digest = 'sha256:deadbeef'; browser_download_url = 'https://example.invalid/updates-windows.zip' },
                            [pscustomobject]@{ name = 'updates-release.json'; digest = $fixture.ReleaseDigest; browser_download_url = 'https://example.invalid/updates-release.json' },
                            [pscustomobject]@{ name = 'SHA256SUMS'; digest = $fixture.SumsDigest; browser_download_url = 'https://example.invalid/SHA256SUMS' }
                        )
                    }
                }
                function Invoke-WebRequest {
                    param([string]$Uri, $Headers, [string]$OutFile, [int]$TimeoutSec)
                    switch ($Uri) {
                        'https://example.invalid/updates-windows.zip' { Copy-Item -LiteralPath $fixture.ZipPath -Destination $OutFile -Force }
                        'https://example.invalid/updates-release.json' { Copy-Item -LiteralPath $fixture.ReleaseManifest -Destination $OutFile -Force }
                        'https://example.invalid/SHA256SUMS' { Copy-Item -LiteralPath $fixture.SumsPath -Destination $OutFile -Force }
                        default { throw "Unexpected download URI: $Uri" }
                    }
                }

                Ensure-LogFileReady
                $null = Invoke-WindowsSelfUpdate -OriginalArgs @('--self-update')
            }

            Assert-Equal -Expected '2.0.0' -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()) -Message 'digest mismatch should leave current.txt unchanged'
            Assert-Match -Text (Get-Content -LiteralPath $logPath -Raw) -Pattern 'zip digest mismatch' -Message 'digest mismatch should be logged'
        }
    }
}

if (Should-RunTest 'native payload skips self-update when install receipt is missing') {
    Invoke-TestCase 'native payload skips self-update when install receipt is missing' {
        Invoke-WithTempInstall {
            param($installRoot)

            Copy-RepoWindowsBootstrap -RepoRoot $repoRoot -InstallRoot $installRoot
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            New-VersionedPayload -InstallRoot $installRoot -Version '2.0.0' -PayloadPath $payloadSource
            Set-VersionPointers -InstallRoot $installRoot -CurrentVersion '2.0.0'

            $emptyPath = Join-Path $installRoot 'empty-path'
            $null = New-Item -ItemType Directory -Path $emptyPath -Force

            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--no-color', '--no-emoji') -Environment @{
                PATH = $emptyPath
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'missing install receipt should skip self-update, not fail the run'
            Assert-Match -Text $result.Output -Pattern '(?is)(receipt.*self-update|self-update.*receipt)' -Message 'missing receipt should be called out in output'
        }
    }
}

if (Should-RunTest 'native payload self-update skips when extracted payload manifest is invalid') {
    Invoke-TestCase 'native payload self-update skips when extracted payload manifest is invalid' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -WithReceipt
            $fixture = New-SelfUpdateFixture -Root $installRoot -Version '2.0.1' -PayloadBootstrapMin 99
            $logPath = Join-Path $installRoot 'self-update.log'
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot

            & {
                . $payloadSource
                $script:InstallRoot = $installRoot
                $script:LogFile = $logPath
                $script:JsonMode = $false
                $script:LogLevel = 'info'
                $script:LogLevelNum = 2
                $script:DryRun = $false
                $script:SelfUpdate = $true

                function Test-InstallRootWritable { return $true }
                function Test-GitCheckout { return $false }
                function Test-SymlinkedInstall { return $false }
                function Get-LatestReleaseMetadata {
                    return [pscustomobject]@{
                        tag_name   = 'v2.0.1'
                        draft      = $false
                        prerelease = $false
                        immutable  = $true
                        assets     = @(
                            [pscustomobject]@{ name = 'updates-windows.zip'; digest = $fixture.ZipDigest; browser_download_url = 'https://example.invalid/updates-windows.zip' },
                            [pscustomobject]@{ name = 'updates-release.json'; digest = $fixture.ReleaseDigest; browser_download_url = 'https://example.invalid/updates-release.json' },
                            [pscustomobject]@{ name = 'SHA256SUMS'; digest = $fixture.SumsDigest; browser_download_url = 'https://example.invalid/SHA256SUMS' }
                        )
                    }
                }
                function Invoke-WebRequest {
                    param([string]$Uri, $Headers, [string]$OutFile, [int]$TimeoutSec)
                    switch ($Uri) {
                        'https://example.invalid/updates-windows.zip' { Copy-Item -LiteralPath $fixture.ZipPath -Destination $OutFile -Force }
                        'https://example.invalid/updates-release.json' { Copy-Item -LiteralPath $fixture.ReleaseManifest -Destination $OutFile -Force }
                        'https://example.invalid/SHA256SUMS' { Copy-Item -LiteralPath $fixture.SumsPath -Destination $OutFile -Force }
                        default { throw "Unexpected download URI: $Uri" }
                    }
                }

                Ensure-LogFileReady
                $null = Invoke-WindowsSelfUpdate -OriginalArgs @('--self-update')
            }

            Assert-Equal -Expected '2.0.0' -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()) -Message 'invalid extracted manifest should leave current.txt unchanged'
            Assert-Match -Text (Get-Content -LiteralPath $logPath -Raw) -Pattern 'extracted manifest is invalid' -Message 'invalid extracted manifest should be logged'
        }
    }
}

if (Should-RunTest 'native payload skips self-update when install receipt source_repo mismatches') {
    Invoke-TestCase 'native payload skips self-update when install receipt source_repo mismatches' {
        Invoke-WithTempInstall {
            param($installRoot)

            Copy-RepoWindowsBootstrap -RepoRoot $repoRoot -InstallRoot $installRoot
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            New-VersionedPayload -InstallRoot $installRoot -Version '2.0.0' -PayloadPath $payloadSource
            Set-VersionPointers -InstallRoot $installRoot -CurrentVersion '2.0.0'
            Write-InstallReceipt -InstallRoot $installRoot -InstalledVersion '2.0.0' -SourceRepo 'someone/else'

            $emptyPath = Join-Path $installRoot 'empty-path'
            $null = New-Item -ItemType Directory -Path $emptyPath -Force

            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--no-color', '--no-emoji') -Environment @{
                PATH = $emptyPath
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'mismatched install receipt should skip self-update, not fail the run'
            Assert-Match -Text $result.Output -Pattern '(?is)(receipt.*source_repo|source_repo.*receipt|receipt.*mismatch)' -Message 'receipt source_repo mismatch should be visible in output'
        }
    }
}

if (Should-RunTest 'bootstrap relaunch guard allows exactly one self-restart') {
    Invoke-TestCase 'bootstrap relaunch guard allows exactly one self-restart' {
        Invoke-WithTempInstall {
            param($installRoot)

            Copy-RepoWindowsBootstrap -RepoRoot $repoRoot -InstallRoot $installRoot
            Copy-RepoWindowsCmd -RepoRoot $repoRoot -InstallRoot $installRoot

            $logPath = Join-Path $installRoot 'relaunch.log'
            $quotedLogPath = Quote-PowerShellLiteral -Value $logPath
            $payload = @'
Set-StrictMode -Version Latest
$logPath = __LOG_PATH__
Add-Content -LiteralPath $logPath -Value ('run:{0}' -f ($env:UPDATES_SELF_UPDATED ?? ''))
$count = @(Get-Content -LiteralPath $logPath).Count
if ($count -gt 2) {
    Write-Error 'relaunch loop detected'
    exit 99
}
if ($env:UPDATES_SELF_UPDATED -eq '1') {
    Write-Output 'relaunch-complete'
    exit 0
}
$installRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$env:UPDATES_SELF_UPDATED = '1'
& (Join-Path $installRoot 'updates.cmd') '--after-self-update'
exit $LASTEXITCODE
'@ -replace '__LOG_PATH__', $quotedLogPath

            New-VersionedPayload -InstallRoot $installRoot -Version '2.0.0' -PayloadContent $payload
            Set-VersionPointers -InstallRoot $installRoot -CurrentVersion '2.0.0'

            $result = Invoke-Bootstrap -InstallRoot $installRoot

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'one-time relaunch guard should allow exactly one restart'
            Assert-FileExists -Path $logPath -Message 'relaunch payload should write a log'
            $lines = @(Get-Content -LiteralPath $logPath)
            Assert-Equal -Expected 2 -Actual $lines.Count -Message 'relaunch guard should cap execution at two launches'
            Assert-Equal -Expected 'run:' -Actual $lines[0] -Message 'first launch should run before the guard is set'
            Assert-Equal -Expected 'run:1' -Actual $lines[1] -Message 'second launch should observe UPDATES_SELF_UPDATED=1'
            Assert-Match -Text $result.Output -Pattern 'relaunch-complete' -Message 'second launch should complete normally after the guard is set'
        }
    }
}

Complete-TestRun
Write-Host 'All Windows-native tests passed.'
