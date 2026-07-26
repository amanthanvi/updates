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

# Production self-update skips under CI; these fixture tests need the non-CI path.
Remove-Item Env:CI -ErrorAction SilentlyContinue

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$currentReleaseVersion = '2.1.1'
$previousReleaseVersion = '2.1.0'

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

function New-MatchedVersionedPayload {
    param([string]$InstallRoot, [string]$Version)
    $payload = Get-Content -LiteralPath (Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot) -Raw
    $payload = [regex]::Replace($payload, '(?m)^\$script:UpdatesVersion\s*=\s*''[^'']+''', ("`$script:UpdatesVersion = '{0}'" -f $Version), 1)
    New-VersionedPayload -InstallRoot $InstallRoot -Version $Version -PayloadContent $payload
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
    Write-Utf8NoBom -Path (Join-Path $assetRoot 'previous.txt') -Content ''
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

if (Should-RunTest 'install-windows.ps1 creates official standalone layout under LOCALAPPDATA') {
    Invoke-TestCase 'install-windows.ps1 creates official standalone layout under LOCALAPPDATA' {
        Invoke-WithTempInstall {
            param($installRoot)

            $localAppData = Join-Path $installRoot 'localappdata'
            $installerPath = Join-Path $repoRoot 'install-windows.ps1'

            $result = Invoke-ProcessCapture `
                -FilePath (Get-PwshPath) `
                -ArgumentList @(
                    '-NoLogo',
                    '-NoProfile',
                    '-ExecutionPolicy', 'Bypass',
                    '-File', $installerPath,
                    '-SourceRoot', $repoRoot
                ) `
                -WorkingDirectory $repoRoot `
                -Environment @{
                    LOCALAPPDATA = $localAppData
                }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "install-windows.ps1 should exit 0`n$result.Output"

            $officialRoot = Join-Path $localAppData 'Programs\updates'
            foreach ($path in @(
                (Join-Path $officialRoot 'updates.cmd'),
                (Join-Path $officialRoot 'updates.ps1'),
                (Join-Path $officialRoot 'current.txt'),
                (Join-Path $officialRoot 'previous.txt'),
                (Join-Path $officialRoot 'install-source.json'),
                (Join-Path $officialRoot ("versions\{0}\manifest.json" -f $currentReleaseVersion)),
                (Join-Path $officialRoot ("versions\{0}\updates-main.ps1" -f $currentReleaseVersion))
            )) {
                Assert-FileExists -Path $path -Message 'installer should create expected Windows layout file'
            }

            Assert-Equal -Expected $currentReleaseVersion -Actual ((Get-Content -LiteralPath (Join-Path $officialRoot 'current.txt') -Raw).Trim()) -Message 'current.txt should point at the installed version'
            Assert-Equal -Expected '' -Actual ([System.IO.File]::ReadAllText((Join-Path $officialRoot 'previous.txt'))) -Message 'previous.txt should be present and empty for a fresh install'

            $receipt = Get-Content -LiteralPath (Join-Path $officialRoot 'install-source.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert-Equal -Expected 'standalone' -Actual $receipt.kind -Message 'install receipt should mark a standalone install'
            Assert-Equal -Expected 'github-release' -Actual $receipt.channel -Message 'install receipt should use the GitHub release channel'
            Assert-Equal -Expected 'amanthanvi/updates' -Actual $receipt.source_repo -Message 'install receipt should use the canonical repo'
            Assert-Equal -Expected 'user' -Actual $receipt.scope -Message 'install receipt should use user scope'
            Assert-Equal -Expected $currentReleaseVersion -Actual $receipt.installed_version -Message 'install receipt should record the installed version'

            $manifest = Get-Content -LiteralPath (Join-Path $officialRoot ("versions\{0}\manifest.json" -f $currentReleaseVersion)) -Raw | ConvertFrom-Json -AsHashtable
            Assert-Equal -Expected $currentReleaseVersion -Actual $manifest.version -Message 'payload manifest should record the installed version'
            Assert-Equal -Expected 1 -Actual ([int]$manifest.bootstrap_min) -Message 'payload manifest should require bootstrap schema 1'
            Assert-Equal -Expected 'updates-main.ps1' -Actual $manifest.entry_script -Message 'payload manifest should target updates-main.ps1'

            $versionResult = Invoke-Launcher -InstallRoot $officialRoot -ArgumentList @('--version') -Environment @{
                LOCALAPPDATA = $localAppData
            }
            Assert-Equal -Expected 0 -Actual $versionResult.ExitCode -Message 'installed updates.cmd --version should exit 0'
            Assert-Equal -Expected $currentReleaseVersion -Actual ($versionResult.Stdout.Trim()) -Message 'installed updates.cmd --version should print the payload version'
        }
    }
}

if (Should-RunTest 'install-windows.ps1 verifies optional local ZIP SHA256') {
    Invoke-TestCase 'install-windows.ps1 verifies optional local ZIP SHA256' {
        Invoke-WithTempInstall {
            param($installRoot)
            $fixture = New-SelfUpdateFixture -Root $installRoot -Version $currentReleaseVersion
            $installerPath = Join-Path $repoRoot 'install-windows.ps1'
            $goodHash = (Get-FileHash -LiteralPath $fixture.ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $goodRoot = Join-Path $installRoot 'good'
            $good = Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', $goodRoot, '-SourceZip', $fixture.ZipPath, '-SourceZipSha256', $goodHash) -WorkingDirectory $repoRoot
            Assert-Equal -Expected 0 -Actual $good.ExitCode -Message "matching local ZIP hash should install`n$($good.Output)"

            $bad = Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', (Join-Path $installRoot 'bad'), '-SourceZip', $fixture.ZipPath, '-SourceZipSha256', ('0' * 64)) -WorkingDirectory $repoRoot
            Assert-Equal -Expected 2 -Actual $bad.ExitCode -Message 'mismatched local ZIP hash should be a usage/integrity error'
            Assert-Match -Text $bad.Output -Pattern '(?i)does not match' -Message 'hash mismatch should be explicit'

            $warning = Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', (Join-Path $installRoot 'warning'), '-SourceZip', $fixture.ZipPath) -WorkingDirectory $repoRoot
            Assert-Equal -Expected 0 -Actual $warning.ExitCode -Message 'unhashed local ZIP remains supported in v2.1'
            Assert-Match -Text $warning.Output -Pattern '(?i)unauthenticated.*SourceZipSha256' -Message 'unhashed local ZIP should emit a trust warning'
        }
    }
}

if (Should-RunTest 'install-windows.ps1 commit failures preserve prior runnable install') {
    Invoke-TestCase 'install-windows.ps1 commit failures preserve prior runnable install' {
        Invoke-WithTempInstall {
            param($testRoot)
            $installerPath = Join-Path $repoRoot 'install-windows.ps1'
            $oldSource = Join-Path $testRoot 'old-source'
            $null = New-Item -ItemType Directory -Path $oldSource
            foreach ($name in @('updates.cmd', 'updates.ps1')) { Copy-Item -LiteralPath (Join-Path $repoRoot $name) -Destination (Join-Path $oldSource $name) }
            $oldPayload = Get-Content -LiteralPath (Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot) -Raw
            $oldPayload = [regex]::Replace($oldPayload, '(?m)^\$script:UpdatesVersion\s*=\s*''[^'']+''', ("`$script:UpdatesVersion = '{0}'" -f $previousReleaseVersion), 1)
            Write-Utf8NoBom -Path (Join-Path $oldSource 'updates-main.ps1') -Content $oldPayload

            foreach ($step in @('payload-staged', 'payload-validated', 'updates.cmd-temp', 'updates.cmd', 'updates.ps1-temp', 'updates.ps1', 'receipt-temp', 'receipt', 'previous-temp', 'previous', 'current-temp', 'current')) {
                $installRoot = Join-Path $testRoot ("install-{0}" -f ($step -replace '\.', '-'))
                $initial = Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', $installRoot, '-SourceRoot', $oldSource, '-Version', $previousReleaseVersion) -WorkingDirectory $repoRoot
                Assert-Equal -Expected 0 -Actual $initial.ExitCode -Message ("prior install setup failed for {0}`n{1}" -f $step, $initial.Output)

                $upgrade = Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', $installRoot, '-SourceRoot', $repoRoot, '-Version', $currentReleaseVersion) -WorkingDirectory $repoRoot -Environment @{ UPDATES_INSTALL_TESTING = '1'; UPDATES_INSTALL_FAIL_AFTER = $step }
                Assert-True -Condition ($upgrade.ExitCode -ne 0) -Message ("injected {0} failure should fail installer" -f $step)
                Assert-Match -Text $upgrade.Output -Pattern ('injected installer failure after {0}' -f [regex]::Escape($step)) -Message ("failure hook should identify {0}" -f $step)
                $stagingLeftovers = @(Get-ChildItem -LiteralPath (Join-Path $installRoot 'versions') -Directory -Filter '.install-*.staging' -ErrorAction SilentlyContinue)
                Assert-Equal -Expected 0 -Actual $stagingLeftovers.Count -Message ("installer must clean GUID staging roots after {0} failure" -f $step)
                $tempLeftovers = @(Get-ChildItem -LiteralPath $installRoot -File -Filter '.*.tmp' -ErrorAction SilentlyContinue)
                Assert-Equal -Expected 0 -Actual $tempLeftovers.Count -Message ("installer must clean GUID temp files after {0} failure" -f $step)

                $launch = Invoke-Launcher -InstallRoot $installRoot -ArgumentList @('--version')
                Assert-Equal -Expected 0 -Actual $launch.ExitCode -Message ("install must remain runnable after {0} failure`n{1}" -f $step, $launch.Output)
                Assert-True -Condition ($launch.Stdout.Trim() -in @($previousReleaseVersion, $currentReleaseVersion)) -Message ("launcher version must be old or new after {0}" -f $step)
                $receipt = Get-Content -LiteralPath (Join-Path $installRoot 'install-source.json') -Raw | ConvertFrom-Json -AsHashtable
                $receiptVersion = [string]$receipt.installed_version
                $receiptPayload = Join-Path $installRoot (Join-Path 'versions' (Join-Path $receiptVersion 'updates-main.ps1'))
                Assert-FileExists -Path $receiptPayload -Message ("receipt payload missing after {0}" -f $step)
                $embedded = [regex]::Match((Get-Content -LiteralPath $receiptPayload -Raw), '(?m)^\$script:UpdatesVersion\s*=\s*''([^'']+)''').Groups[1].Value
                Assert-Equal -Expected $receiptVersion -Actual $embedded -Message ("receipt payload version mismatch after {0}" -f $step)
            }
        }
    }
}

if (Should-RunTest 'install-windows.ps1 same-version reinstall preserves valid rollback pointer') {
    Invoke-TestCase 'install-windows.ps1 same-version reinstall preserves valid rollback pointer' {
        Invoke-WithTempInstall {
            param($testRoot)
            $installerPath = Join-Path $repoRoot 'install-windows.ps1'
            $installRoot = Join-Path $testRoot 'install'
            $oldSource = Join-Path $testRoot 'old-source'
            $null = New-Item -ItemType Directory -Path $oldSource
            foreach ($name in @('updates.cmd', 'updates.ps1')) { Copy-Item -LiteralPath (Join-Path $repoRoot $name) -Destination (Join-Path $oldSource $name) }
            $oldPayload = Get-Content -LiteralPath (Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot) -Raw
            $oldPayload = [regex]::Replace($oldPayload, '(?m)^\$script:UpdatesVersion\s*=\s*''[^'']+''', ("`$script:UpdatesVersion = '{0}'" -f $previousReleaseVersion), 1)
            Write-Utf8NoBom -Path (Join-Path $oldSource 'updates-main.ps1') -Content $oldPayload

            $oldInstall = Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', $installRoot, '-SourceRoot', $oldSource, '-Version', $previousReleaseVersion) -WorkingDirectory $repoRoot
            Assert-Equal -Expected 0 -Actual $oldInstall.ExitCode -Message "old install setup should succeed`n$($oldInstall.Output)"
            $upgrade = Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', $installRoot, '-SourceRoot', $repoRoot, '-Version', $currentReleaseVersion) -WorkingDirectory $repoRoot
            Assert-Equal -Expected 0 -Actual $upgrade.ExitCode -Message "upgrade should succeed`n$($upgrade.Output)"
            $reinstall = Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', $installRoot, '-SourceRoot', $repoRoot, '-Version', $currentReleaseVersion) -WorkingDirectory $repoRoot
            Assert-Equal -Expected 0 -Actual $reinstall.ExitCode -Message "same-version reinstall should succeed`n$($reinstall.Output)"
            Assert-Equal -Expected $previousReleaseVersion -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'previous.txt') -Raw).Trim()) -Message 'same-version reinstall must preserve the valid rollback pointer'
        }
    }
}

if (Should-RunTest 'install-windows.ps1 replaces a corrupt existing payload') {
    Invoke-TestCase 'install-windows.ps1 replaces a corrupt existing payload' {
        Invoke-WithTempInstall {
            param($installRoot)
            $installerPath = Join-Path $repoRoot 'install-windows.ps1'
            $initial = Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', $installRoot, '-SourceRoot', $repoRoot, '-Version', $currentReleaseVersion) -WorkingDirectory $repoRoot
            Assert-Equal -Expected 0 -Actual $initial.ExitCode -Message "initial install should succeed`n$($initial.Output)"

            $payloadPath = Join-Path $installRoot (Join-Path 'versions' (Join-Path $currentReleaseVersion 'updates-main.ps1'))
            Add-Content -LiteralPath $payloadPath -Value ("`n`$script:UpdatesVersion = '{0}'" -f $currentReleaseVersion)

            $reinstall = Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', $installRoot, '-SourceRoot', $repoRoot, '-Version', $currentReleaseVersion) -WorkingDirectory $repoRoot
            Assert-Equal -Expected 0 -Actual $reinstall.ExitCode -Message "reinstall should replace a malformed existing payload`n$($reinstall.Output)"
            $assignments = [regex]::Matches((Get-Content -LiteralPath $payloadPath -Raw), '(?m)^\s*\$script:UpdatesVersion\s*=.*$')
            Assert-Equal -Expected 1 -Actual $assignments.Count -Message 'replacement payload should restore one canonical version assignment'
        }
    }
}

if (Should-RunTest 'install-windows.ps1 replaces a file at the version path') {
    Invoke-TestCase 'install-windows.ps1 replaces a file at the version path' {
        Invoke-WithTempInstall {
            param($installRoot)
            $installerPath = Join-Path $repoRoot 'install-windows.ps1'
            $versionRoot = Join-Path $installRoot (Join-Path 'versions' $currentReleaseVersion)
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $versionRoot) -Force
            Set-Content -LiteralPath $versionRoot -Value 'corrupt'

            $install = Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', $installRoot, '-SourceRoot', $repoRoot, '-Version', $currentReleaseVersion) -WorkingDirectory $repoRoot
            Assert-Equal -Expected 0 -Actual $install.ExitCode -Message "install should replace a file at the version path`n$($install.Output)"
            Assert-FileExists -Path (Join-Path $versionRoot 'updates-main.ps1') -Message 'replacement should install the version payload'
        }
    }
}

if (Should-RunTest 'install-windows.ps1 rejects target reparse roots before mutation') {
    Invoke-TestCase 'install-windows.ps1 rejects target reparse roots before mutation' {
        Invoke-WithTempInstall {
            param($testRoot)
            $installerPath = Join-Path $repoRoot 'install-windows.ps1'
            foreach ($seam in @('target-root', 'versions-root', 'target-version')) {
                $caseRoot = Join-Path $testRoot $seam
                $installRoot = Join-Path $caseRoot 'install'
                $outside = Join-Path $caseRoot 'outside'
                $null = New-Item -ItemType Directory -Path $installRoot -Force
                $null = New-Item -ItemType Directory -Path $outside -Force
                $sentinel = Join-Path $outside 'sentinel.txt'
                Write-Utf8NoBom -Path $sentinel -Content 'must-remain-unchanged'

                switch ($seam) {
                    'target-root' {
                        Remove-Item -LiteralPath $installRoot -Recurse -Force
                        $null = New-Item -ItemType Junction -Path $installRoot -Target $outside
                    }
                    'versions-root' {
                        $null = New-Item -ItemType Junction -Path (Join-Path $installRoot 'versions') -Target $outside
                    }
                    'target-version' {
                        $versions = Join-Path $installRoot 'versions'
                        $null = New-Item -ItemType Directory -Path $versions -Force
                        $null = New-Item -ItemType Junction -Path (Join-Path $versions $currentReleaseVersion) -Target $outside
                    }
                }

                $result = Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', $installRoot, '-SourceRoot', $repoRoot, '-Version', $currentReleaseVersion) -WorkingDirectory $repoRoot
                Assert-True -Condition ($result.ExitCode -ne 0) -Message ("installer must reject {0} reparse seam" -f $seam)
                Assert-Match -Text $result.Output -Pattern '(?i)reparse-point' -Message ("installer should identify {0} as a reparse point" -f $seam)
                Assert-Equal -Expected 'must-remain-unchanged' -Actual ([System.IO.File]::ReadAllText($sentinel)) -Message ("outside sentinel must remain unchanged for {0}" -f $seam)
                Assert-Equal -Expected 1 -Actual (@(Get-ChildItem -LiteralPath $outside -Force).Count) -Message ("installer must not create files through {0}" -f $seam)
            }
        }
    }
}

if (Should-RunTest 'install-windows.ps1 includes token auth and strict checksum parsing guards') {
    Invoke-TestCase 'install-windows.ps1 includes token auth and strict checksum parsing guards' {
        $source = Get-Content -LiteralPath (Join-Path $repoRoot 'install-windows.ps1') -Raw
        Assert-Match -Text $source -Pattern '\$headers\.Authorization\s*=\s*"Bearer \$\(\$env:GITHUB_TOKEN\)"' -Message 'release metadata and asset requests should use GITHUB_TOKEN bearer auth when configured'
        Assert-Match -Text $source -Pattern "\^\(\[0-9a-fA-F\]\{\{64\}\}\)\\s\+" -Message 'SHA256SUMS parser should require an anchored 64-hex digest before the literal asset name'
        Assert-True -Condition ($source -notmatch '(?i)Write-(?:Host|Output|Verbose|Debug|Information|Warning).*GITHUB_TOKEN') -Message 'installer must not log GITHUB_TOKEN'
    }
}

if (Should-RunTest 'install-windows.ps1 mocked official network validates release trust chain') {
    Invoke-TestCase 'install-windows.ps1 mocked official network validates release trust chain' {
        Invoke-WithTempInstall {
            param($testRoot)
            $installerPath = Join-Path $repoRoot 'install-windows.ps1'

            function New-NetworkFixture {
                param([string]$Name)
                $root = Join-Path $testRoot $Name
                $fixture = New-SelfUpdateFixture -Root $root -Version $currentReleaseVersion
                $null = New-Item -ItemType Directory -Path $root -Force
                Copy-Item -LiteralPath $fixture.ZipPath -Destination (Join-Path $root 'updates-windows.zip') -Force
                Copy-Item -LiteralPath $fixture.ReleaseManifest -Destination (Join-Path $root 'updates-release.json') -Force
                Copy-Item -LiteralPath $fixture.SumsPath -Destination (Join-Path $root 'SHA256SUMS') -Force
                Write-JsonFile -Path (Join-Path $root 'release-metadata.json') -Data ([ordered]@{
                    tag_name = "v$currentReleaseVersion"
                    draft = $false
                    prerelease = $false
                    immutable = $true
                    assets = @(
                        [ordered]@{ name = 'updates-windows.zip'; digest = $fixture.ZipDigest; browser_download_url = 'https://example.invalid/updates-windows.zip' },
                        [ordered]@{ name = 'updates-release.json'; digest = $fixture.ReleaseDigest; browser_download_url = 'https://example.invalid/updates-release.json' },
                        [ordered]@{ name = 'SHA256SUMS'; digest = $fixture.SumsDigest; browser_download_url = 'https://example.invalid/SHA256SUMS' }
                    )
                })
                return $root
            }

            function Invoke-NetworkFixtureInstall {
                param([string]$FixtureRoot, [string]$Name)
                return Invoke-ProcessCapture -FilePath (Get-PwshPath) -ArgumentList @('-NoLogo', '-NoProfile', '-File', $installerPath, '-InstallRoot', (Join-Path $testRoot ('install-' + $Name)), '-Version', $currentReleaseVersion) -WorkingDirectory $repoRoot -Environment @{
                    UPDATES_INSTALL_TESTING = '1'
                    UPDATES_INSTALL_RELEASE_FIXTURE_ROOT = $FixtureRoot
                    GITHUB_TOKEN = 'test-token-must-not-appear'
                }
            }

            $validRoot = New-NetworkFixture -Name 'valid'
            $valid = Invoke-NetworkFixtureInstall -FixtureRoot $validRoot -Name 'valid'
            Assert-Equal -Expected 0 -Actual $valid.ExitCode -Message "valid mocked official release should install`n$($valid.Output)"
            Assert-Match -Text $valid.Stderr -Pattern '^WARNING: updates installer test fixture mode bypasses the live canonical GitHub release fetch; verification uses local fixture files\.\r?\n' -Message 'fixture mode must prominently disclose that live canonical release fetch is bypassed'
            Assert-Equal -Expected 'bearer' -Actual ([System.IO.File]::ReadAllText((Join-Path $validRoot 'authorization-kind.txt'))) -Message 'mocked request should receive bearer authorization'
            Assert-True -Condition ($valid.Output -notmatch 'test-token-must-not-appear') -Message 'installer output must not reveal GITHUB_TOKEN'

            $digestRoot = New-NetworkFixture -Name 'digest'
            $digestMetadata = Get-Content -LiteralPath (Join-Path $digestRoot 'release-metadata.json') -Raw | ConvertFrom-Json -AsHashtable
            $digestMetadata.assets[0].digest = 'sha256:' + ('0' * 64)
            Write-JsonFile -Path (Join-Path $digestRoot 'release-metadata.json') -Data $digestMetadata
            Assert-True -Condition ((Invoke-NetworkFixtureInstall -FixtureRoot $digestRoot -Name 'digest').ExitCode -ne 0) -Message 'release asset digest mismatch must fail'

            $sumRoot = New-NetworkFixture -Name 'checksum'
            Write-Utf8NoBom -Path (Join-Path $sumRoot 'SHA256SUMS') -Content (('0' * 64) + '  updates-windows.zip' + "`n")
            $sumMetadata = Get-Content -LiteralPath (Join-Path $sumRoot 'release-metadata.json') -Raw | ConvertFrom-Json -AsHashtable
            $sumMetadata.assets[2].digest = 'sha256:' + ((Get-FileHash -LiteralPath (Join-Path $sumRoot 'SHA256SUMS') -Algorithm SHA256).Hash.ToLowerInvariant())
            Write-JsonFile -Path (Join-Path $sumRoot 'release-metadata.json') -Data $sumMetadata
            Assert-True -Condition ((Invoke-NetworkFixtureInstall -FixtureRoot $sumRoot -Name 'checksum').ExitCode -ne 0) -Message 'SHA256SUMS payload mismatch must fail'

            foreach ($field in @('draft', 'prerelease', 'immutable')) {
                $trustRoot = New-NetworkFixture -Name ('trust-' + $field)
                $metadata = Get-Content -LiteralPath (Join-Path $trustRoot 'release-metadata.json') -Raw | ConvertFrom-Json -AsHashtable
                $metadata[$field] = $field -ne 'immutable'
                Write-JsonFile -Path (Join-Path $trustRoot 'release-metadata.json') -Data $metadata
                Assert-True -Condition ((Invoke-NetworkFixtureInstall -FixtureRoot $trustRoot -Name ('trust-' + $field)).ExitCode -ne 0) -Message ("untrusted {0} release metadata must fail" -f $field)
            }

            $malformedRoot = New-NetworkFixture -Name 'malformed-sums'
            $zipHash = (Get-FileHash -LiteralPath (Join-Path $malformedRoot 'updates-windows.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-Utf8NoBom -Path (Join-Path $malformedRoot 'SHA256SUMS') -Content ('prefix' + $zipHash + '  updates-windows.zip' + "`n")
            $malformedMetadata = Get-Content -LiteralPath (Join-Path $malformedRoot 'release-metadata.json') -Raw | ConvertFrom-Json -AsHashtable
            $malformedMetadata.assets[2].digest = 'sha256:' + ((Get-FileHash -LiteralPath (Join-Path $malformedRoot 'SHA256SUMS') -Algorithm SHA256).Hash.ToLowerInvariant())
            Write-JsonFile -Path (Join-Path $malformedRoot 'release-metadata.json') -Data $malformedMetadata
            Assert-True -Condition ((Invoke-NetworkFixtureInstall -FixtureRoot $malformedRoot -Name 'malformed-sums').ExitCode -ne 0) -Message 'malformed unanchored SHA256SUMS line must fail'
        }
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
            New-VersionedPayload -InstallRoot $installRoot -Version $currentReleaseVersion -PayloadPath $payloadSource
            Set-VersionPointers -InstallRoot $installRoot -CurrentVersion $currentReleaseVersion
            $pwshOnlyPath = @(
                (Split-Path -Parent (Get-PwshPath)),
                (Join-Path $env:SystemRoot 'System32')
            ) -join ';'

            $result = Invoke-Launcher -InstallRoot $installRoot -ArgumentList @('--version') -Environment @{
                PATH = $pwshOnlyPath
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'updates.cmd --version should exit 0'
            Assert-Equal -Expected $currentReleaseVersion -Actual ($result.Stdout.Trim()) -Message 'updates.cmd --version should print the payload version'
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

if (Should-RunTest 'Install-RepoWindowsRuntime removes stale receipt when omitted') {
    Invoke-TestCase 'Install-RepoWindowsRuntime removes stale receipt when omitted' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -WithReceipt
            $receiptPath = Join-Path $installRoot 'install-source.json'
            Assert-FileExists -Path $receiptPath -Message 'helper should write a receipt when requested'

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot
            if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
                throw "expected Install-RepoWindowsRuntime without -WithReceipt to remove stale install-source.json at $receiptPath"
            }
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
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: npx --yes npm-check-updates -g --enginesNode --jsonUpgraded' -Message 'node should fall back to engine-aware npx when ncu is absent'
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

if (Should-RunTest 'native payload falls back from incapable ncu to engine-aware npx') {
    Invoke-TestCase 'native payload falls back from incapable ncu to engine-aware npx' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'ncu.cmd') -Lines @(
                'echo ncu %*>>"%NODE_MARKER%"',
                'if "%~1"=="--help" (echo legacy ncu help & exit /b 0)',
                'echo incapable ncu query should not run 1>&2',
                'exit /b 1'
            )
            Write-CmdStub -Path (Join-Path $stubDir 'npx.cmd') -Lines @(
                'echo npx %*>>"%NODE_MARKER%"',
                'echo {"example-cli":"2.0.0"}'
            )
            Write-CmdStub -Path (Join-Path $stubDir 'npm.cmd') -Lines @(
                'echo npm %*>>"%NODE_MARKER%"'
            )

            $markerPath = Join-Path $installRoot 'node-marker.txt'
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--only', 'node',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
                NODE_MARKER = $markerPath
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'node should fall back from incapable ncu to npx'
            $marker = Get-Content -LiteralPath $markerPath -Raw
            Assert-Match -Text $marker -Pattern '(?im)^ncu --help enginesNode\r?$' -Message 'node should probe direct ncu capability'
            Assert-NotMatch -Text $marker -Pattern '(?im)^ncu -g ' -Message 'incapable direct ncu should not query upgrades'
            Assert-Match -Text $marker -Pattern '(?im)^npx --yes npm-check-updates -g --enginesNode --jsonUpgraded\r?$' -Message 'npx fallback should filter by active Node engine'
        }
    }
}

if (Should-RunTest 'native payload isolates npm packages and does not retry EBADENGINE') {
    Invoke-TestCase 'native payload isolates npm packages and does not retry EBADENGINE' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'npx.cmd') -Lines @(
                'echo {"npm":"12.0.1","example-cli":"2.0.0"}'
            )
            Write-CmdStub -Path (Join-Path $stubDir 'npm.cmd') -Lines @(
                'echo npm %*>>"%NODE_MARKER%"',
                'echo %* | "%SystemRoot%\System32\findstr.exe" /C:"--dry-run" >nul',
                'if not errorlevel 1 exit /b 0',
                'echo %* | "%SystemRoot%\System32\findstr.exe" /C:"npm@12.0.1" >nul',
                'if not errorlevel 1 (',
                '  echo npm error code EBADENGINE 1>&2',
                '  exit /b 0',
                ')',
                'echo %* | "%SystemRoot%\System32\findstr.exe" /C:"example-cli@2.0.0" >nul',
                'if not errorlevel 1 exit /b 0',
                'exit /b 1'
            )

            $markerPath = Join-Path $installRoot 'node-marker.txt'
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--only', 'node',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
                NODE_MARKER = $markerPath
            }

            Assert-Equal -Expected 1 -Actual $result.ExitCode -Message 'one incompatible package should fail the node module'
            $marker = Get-Content -LiteralPath $markerPath -Raw
            Assert-Match -Text $marker -Pattern '(?im)^npm install -g -- npm@12\.0\.1\r?$' -Message 'incompatible package should be attempted once'
            Assert-Match -Text $marker -Pattern '(?im)^npm install -g -- example-cli@2\.0\.0\r?$' -Message 'later compatible package should still be attempted'
            Assert-Equal -Expected 1 -Actual ([regex]::Matches($marker, '(?im)^npm install -g -- npm@12\.0\.1\r?$').Count) -Message 'EBADENGINE must not retry'
            Assert-Match -Text $result.Output -Pattern 'npm@12\.0\.1 is incompatible with the active Node runtime' -Message 'engine failure should be actionable'
        }
    }
}

if (Should-RunTest 'native payload rejects an engine-incompatible candidate returned by ncu') {
    Invoke-TestCase 'native payload rejects an engine-incompatible candidate returned by ncu' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'npx.cmd') -Lines @(
                'echo {"npm":"12.0.1","example-cli":"2.0.0"}'
            )
            Write-CmdStub -Path (Join-Path $stubDir 'npm.cmd') -Lines @(
                'echo npm %*>>"%NODE_MARKER%"',
                'echo %* | "%SystemRoot%\System32\findstr.exe" /C:"--dry-run" >nul',
                'if not errorlevel 1 if not "%NPM_CONFIG_FORCE%"=="false" exit /b 1',
                'if not errorlevel 1 if not "%NPM_CONFIG_ENGINE_STRICT%"=="true" exit /b 1',
                'if errorlevel 1 if defined NPM_CONFIG_FORCE exit /b 1',
                'if errorlevel 1 if defined NPM_CONFIG_ENGINE_STRICT exit /b 1',
                'echo %* | "%SystemRoot%\System32\findstr.exe" /C:"--dry-run --ignore-scripts --engine-strict -- npm@12.0.1" >nul',
                'if not errorlevel 1 (',
                '  echo npm error code EBADENGINE 1>&2',
                '  exit /b 1',
                ')',
                'echo %* | "%SystemRoot%\System32\findstr.exe" /X /C:"install -g -- npm@12.0.1" >nul',
                'if not errorlevel 1 (',
                '  echo Engine-incompatible npm candidate must be rejected before install 1>&2',
                '  exit /b 1',
                ')',
                'exit /b 0'
            )
            Write-Utf8NoBom -Path (Join-Path $installRoot '.updatesrc') -Content "NODE_NPM_INSTALL_FLAGS=--registry=https://registry.example.invalid --force`n"

            $markerPath = Join-Path $installRoot 'node-marker.txt'
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--only', 'node',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
                NODE_MARKER = $markerPath
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'engine-incompatible ncu candidate should warn and skip'
            $marker = Get-Content -LiteralPath $markerPath -Raw
            Assert-Match -Text $marker -Pattern '(?im)^npm install -g --registry=https://registry\.example\.invalid --dry-run --ignore-scripts --engine-strict -- npm@12\.0\.1\r?$' -Message 'candidate should receive an engine-strict preflight without force'
            Assert-Equal -Expected 1 -Actual ([regex]::Matches($marker, '(?im)^npm .*npm@12\.0\.1\r?$').Count) -Message 'engine-incompatible candidate should only receive the preflight'
            Assert-Match -Text $marker -Pattern '(?im)^npm install -g --registry=https://registry\.example\.invalid --force -- example-cli@2\.0\.0\r?$' -Message 'later compatible package should retain configured install flags'
            Assert-Match -Text $result.Output -Pattern 'skipping npm@12\.0\.1 because it is incompatible with the active Node runtime' -Message 'engine skip should be actionable'
        }
    }
}

if (Should-RunTest 'NODE_NPM_INSTALL_FLAGS appears in node dry-run output') {
    Invoke-TestCase 'NODE_NPM_INSTALL_FLAGS appears in node dry-run output' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'npx.cmd') -Lines @()
            Write-CmdStub -Path (Join-Path $stubDir 'npm.cmd') -Lines @()
            Write-Utf8NoBom -Path (Join-Path $installRoot '.updatesrc') -Content "NODE_NPM_INSTALL_FLAGS=--legacy-peer-deps`n"

            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--dry-run',
                '--only', 'node',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'NODE_NPM_INSTALL_FLAGS dry-run should succeed'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*npm(\.cmd)? install -g --legacy-peer-deps -- <packages\.\.\.>' -Message 'node dry-run should include NODE_NPM_INSTALL_FLAGS'
        }
    }
}

if (Should-RunTest 'native payload node retries npm ERESOLVE with legacy peer deps') {
    Invoke-TestCase 'native payload node retries npm ERESOLVE with legacy peer deps' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'npx.cmd') -Lines @(
                'echo {"@tarquinen/opencode-dcp":"3.1.13"}'
            )
            Write-CmdStub -Path (Join-Path $stubDir 'npm.cmd') -Lines @(
                'echo npm %*>>"%NODE_MARKER%"',
                'echo %* | "%SystemRoot%\System32\findstr.exe" /C:"--legacy-peer-deps" >nul',
                'if not errorlevel 1 exit /b 0',
                'echo %* | "%SystemRoot%\System32\findstr.exe" /C:"@tarquinen/opencode-dcp@3.1.13" >nul',
                'if not errorlevel 1 (',
                '  echo npm error code ERESOLVE 1>&2',
                '  exit /b 1',
                ')'
            )

            $markerPath = Join-Path $installRoot 'node-marker.txt'
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--only', 'node',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
                NODE_MARKER = $markerPath
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'node ERESOLVE retry should succeed'
            $marker = Get-Content -LiteralPath $markerPath -Raw
            Assert-Match -Text $marker -Pattern '(?im)^npm install -g -- @tarquinen/opencode-dcp@3\.1\.13\r?$' -Message 'node should first try strict npm install'
            Assert-Match -Text $marker -Pattern '(?im)^npm install -g --legacy-peer-deps -- @tarquinen/opencode-dcp@3\.1\.13\r?$' -Message 'node should retry with legacy peer deps'
            Assert-NotMatch -Text $result.Output -Pattern 'npm error code ERESOLVE' -Message 'successful ERESOLVE retry should suppress first-pass npm error details'
            Assert-Match -Text $result.Output -Pattern 'retrying with --legacy-peer-deps' -Message 'retry warning should be visible'
        }
    }
}

if (Should-RunTest 'native payload node retry dedupes NODE_NPM_INSTALL_FLAGS legacy peer deps') {
    Invoke-TestCase 'native payload node retry dedupes NODE_NPM_INSTALL_FLAGS legacy peer deps' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'npx.cmd') -Lines @(
                'echo {"@tarquinen/opencode-dcp":"3.1.13"}'
            )
            Write-CmdStub -Path (Join-Path $stubDir 'npm.cmd') -Lines @(
                'echo npm %*>>"%NODE_MARKER%"',
                'echo %* | "%SystemRoot%\System32\findstr.exe" /C:"--strict-peer-deps --legacy-peer-deps -- @tarquinen/opencode-dcp@3.1.13" >nul',
                'if not errorlevel 1 exit /b 0',
                'echo %* | "%SystemRoot%\System32\findstr.exe" /C:"@tarquinen/opencode-dcp@3.1.13" >nul',
                'if not errorlevel 1 (',
                '  echo npm error code ERESOLVE 1>&2',
                '  exit /b 1',
                ')'
            )
            Write-Utf8NoBom -Path (Join-Path $installRoot '.updatesrc') -Content "NODE_NPM_INSTALL_FLAGS=--legacy-peer-deps --strict-peer-deps`n"

            $markerPath = Join-Path $installRoot 'node-marker.txt'
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--only', 'node',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
                NODE_MARKER = $markerPath
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'node ERESOLVE retry should succeed'
            $marker = Get-Content -LiteralPath $markerPath -Raw
            Assert-Match -Text $marker -Pattern '(?im)^npm install -g --legacy-peer-deps --strict-peer-deps -- @tarquinen/opencode-dcp@3\.1\.13\r?$' -Message 'node should first include configured npm flags'
            Assert-Match -Text $marker -Pattern '(?im)^npm install -g --strict-peer-deps --legacy-peer-deps -- @tarquinen/opencode-dcp@3\.1\.13\r?$' -Message 'node retry should dedupe and force legacy peer deps last'
            $retryLine = [regex]::Match($marker, '(?im)^npm install -g --strict-peer-deps --legacy-peer-deps -- @tarquinen/opencode-dcp@3\.1\.13\r?$').Value
            Assert-Equal -Expected 1 -Actual ([regex]::Matches($retryLine, '--legacy-peer-deps').Count) -Message 'retry should include --legacy-peer-deps exactly once'
        }
    }
}

if (Should-RunTest 'native payload node reruns npm with allow-scripts when npm requests approval') {
    Invoke-TestCase 'native payload node reruns npm with allow-scripts when npm requests approval' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'npx.cmd') -Lines @(
                'echo {"opencode-ai":"1.17.8"}'
            )
            Write-CmdStub -Path (Join-Path $stubDir 'npm.cmd') -Lines @(
                'echo npm %*>>"%NODE_MARKER%"',
                'echo %* | "%SystemRoot%\System32\findstr.exe" /C:"--allow-scripts=opencode-ai,koffi" >nul',
                'if not errorlevel 1 exit /b 0',
                'echo npm warn allow-scripts approve with --allow-scripts=opencode-ai,koffi 1>&2'
            )

            $markerPath = Join-Path $installRoot 'node-marker.txt'
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--only', 'node',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
                NODE_MARKER = $markerPath
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'node allow-scripts retry should succeed'
            $marker = Get-Content -LiteralPath $markerPath -Raw
            Assert-Match -Text $marker -Pattern '(?im)^npm install -g -- opencode-ai@1\.17\.8\r?$' -Message 'node should first try strict npm install'
            Assert-Match -Text $marker -Pattern '(?im)^npm install -g --allow-scripts=opencode-ai,koffi -- opencode-ai@1\.17\.8\r?$' -Message 'node should retry with npm-provided allow-scripts list'
            Assert-NotMatch -Text $result.Output -Pattern 'npm warn allow-scripts approve' -Message 'successful allow-scripts retry should suppress first-pass npm warning details'
            Assert-Match -Text $result.Output -Pattern 'retrying once with npm-provided allow-scripts list' -Message 'allow-scripts retry warning should be visible'
        }
    }
}

if (Should-RunTest 'native payload node keeps a successful install after allow-scripts retry exhaustion') {
    Invoke-TestCase 'native payload node keeps a successful install after allow-scripts retry exhaustion' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'npx.cmd') -Lines @(
                'echo {"opencode-ai":"1.17.8"}'
            )
            Write-CmdStub -Path (Join-Path $stubDir 'npm.cmd') -Lines @(
                'echo npm %*>>"%NODE_MARKER%"',
                'echo npm warn allow-scripts approve with --allow-scripts=opencode-ai,koffi 1>&2'
            )

            $markerPath = Join-Path $installRoot 'node-marker.txt'
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--only', 'node',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
                NODE_MARKER = $markerPath
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'successful npm install should remain successful after the bounded allow-scripts retry'
            $marker = Get-Content -LiteralPath $markerPath -Raw
            Assert-Equal -Expected 2 -Actual ([regex]::Matches($marker, '(?im)^npm install -g (?!.*--dry-run).*$').Count) -Message 'node should attempt one allow-scripts retry and stop'
            Assert-Match -Text $marker -Pattern '(?im)^npm install -g --allow-scripts=opencode-ai,koffi -- opencode-ai@1\.17\.8\r?$' -Message 'node should preserve the npm-provided allow-scripts argument'
            Assert-Match -Text $result.Output -Pattern 'npm install completed for opencode-ai@1\.17\.8, but npm still reports install scripts needing approval after retry' -Message 'retry exhaustion should remain visible as a warning'
            Assert-Match -Text $result.Output -Pattern 'npm warn allow-scripts approve with --allow-scripts=opencode-ai,koffi' -Message 'final npm diagnostics should remain visible'
        }
    }
}

if (Should-RunTest 'native payload node surfaces unparseable allow-scripts warnings without retrying') {
    Invoke-TestCase 'native payload node surfaces unparseable allow-scripts warnings without retrying' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'npx.cmd') -Lines @(
                'echo {"opencode-ai":"1.17.8"}'
            )
            Write-CmdStub -Path (Join-Path $stubDir 'npm.cmd') -Lines @(
                'echo npm %*>>"%NODE_MARKER%"',
                'echo npm warn allow-scripts install scripts need approval 1>&2'
            )

            $markerPath = Join-Path $installRoot 'node-marker.txt'
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--only', 'node',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
                NODE_MARKER = $markerPath
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'node should not fail on unparseable allow-scripts warning'
            $marker = Get-Content -LiteralPath $markerPath -Raw
            Assert-Match -Text $marker -Pattern '(?im)^npm install -g -- opencode-ai@1\.17\.8\r?$' -Message 'node should run the strict npm install'
            Assert-NotMatch -Text $marker -Pattern '(?im)^npm install -g --allow-scripts=' -Message 'node should not guess an allow-scripts retry'
            Assert-Match -Text $result.Output -Pattern 'no allow-scripts list could be parsed' -Message 'unparseable warning should produce a fallback warning'
            Assert-Match -Text $result.Output -Pattern 'npm warn allow-scripts install scripts need approval' -Message 'unparseable npm warning should remain visible'
        }
    }
}

if (Should-RunTest 'native payload uses --user for externally managed Python environments') {
    Invoke-TestCase 'native payload uses --user for externally managed Python environments' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot

            $stubDir = Join-Path $installRoot 'stub-bin'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'py.cmd') -Lines @(
                'if "%~1"=="-3" shift',
                'if "%~1"=="-c" (echo 1 & exit /b 0)',
                'if "%~1"=="-m" if "%~2"=="pip" if "%~3"=="--version" echo pip 25.0 from py-stub'
            )

            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @(
                '--no-self-update',
                '--dry-run',
                '--only', 'python',
                '--no-color',
                '--no-emoji'
            ) -Environment @{
                PATH        = $stubDir
                HOME        = $installRoot
                USERPROFILE = $installRoot
            }

            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message 'externally managed Python dry-run should still succeed'
            Assert-Match -Text $result.Output -Pattern '(?i)externally-managed environment detected; upgrading user-site packages\.' -Message 'PEP 668 detection should be explicit'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*py(\.cmd)? -3 -m pip --disable-pip-version-check list --outdated --format=json --user' -Message 'externally managed Python should query user-site packages'
            Assert-Match -Text $result.Output -Pattern '(?i)DRY RUN: .*py(\.cmd)? -3 -m pip --disable-pip-version-check install -U --user <package>' -Message 'externally managed Python should install into the user site'
            if ($result.Output -match '--break-system-packages') {
                throw 'externally managed Python dry-run should not add --break-system-packages without --pip-force'
            }
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

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
            $fixture = New-SelfUpdateFixture -Root $installRoot -Version $currentReleaseVersion
            $logPath = Join-Path $installRoot 'self-update.log'
            $relaunchArgsPath = Join-Path $installRoot 'relaunch-args.txt'
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            $localAppData = Join-Path $installRoot 'localappdata'
            $null = New-Item -ItemType Directory -Path $localAppData -Force

            & {
                . $payloadSource
                $script:UpdatesVersion = $previousReleaseVersion
                $script:InstallRoot = $installRoot
                $script:LogFile = $logPath
                $script:JsonMode = $false
                $script:LogLevel = 'info'
                $script:LogLevelNum = 2
                $script:DryRun = $false
                $script:SelfUpdate = $true
                $env:LOCALAPPDATA = $localAppData

                function Test-InstallRootWritable { return $true }
                function Test-GitCheckout { return $false }
                function Test-SymlinkedInstall { return $false }
                function Get-LatestReleaseMetadata {
                    return [pscustomobject]@{
                        tag_name   = "v$currentReleaseVersion"
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

            Assert-Equal -Expected $currentReleaseVersion -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()) -Message 'current.txt should advance after a verified self-update'
            Assert-Equal -Expected $previousReleaseVersion -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'previous.txt') -Raw).Trim()) -Message 'previous.txt should preserve the prior version after self-update'
            Assert-Match -Text (Get-Content -LiteralPath (Join-Path $installRoot 'install-source.json') -Raw) -Pattern ('"installed_version"\s*:\s*"{0}"' -f [regex]::Escape($currentReleaseVersion)) -Message 'install receipt should be rewritten to the new version'
            Assert-FileExists -Path (Join-Path $installRoot ("versions\{0}\updates-main.ps1" -f $currentReleaseVersion)) -Message 'new version payload should be staged into the install root'
            Assert-Match -Text (Get-Content -LiteralPath $logPath -Raw) -Pattern ('updated to {0}; restarting' -f [regex]::Escape($currentReleaseVersion)) -Message 'successful self-update should be logged'
            Assert-Equal -Expected 17 -Actual $script:SelfUpdateResult.ExitCode -Message 'self-update should propagate the relaunch exit code'
            Assert-Match -Text (Get-Content -LiteralPath $relaunchArgsPath -Raw) -Pattern '(?m)^--self-update$' -Message 'self-update relaunch should preserve original args'
        }
    }
}

if (Should-RunTest 'native payload self-update preserves rollback pointer during previous.txt recovery') {
    Invoke-TestCase 'native payload self-update preserves rollback pointer during previous.txt recovery' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
            $fixture = New-SelfUpdateFixture -Root $installRoot -Version $currentReleaseVersion
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            $localAppData = Join-Path $installRoot 'localappdata'
            $null = New-Item -ItemType Directory -Path $localAppData -Force

            Set-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Value 'broken-version' -NoNewline
            Set-Content -LiteralPath (Join-Path $installRoot 'previous.txt') -Value $previousReleaseVersion -NoNewline

            & {
                . $payloadSource
                $script:UpdatesVersion = $previousReleaseVersion
                $script:InstallRoot = $installRoot
                $script:JsonMode = $false
                $script:LogLevel = 'info'
                $script:LogLevelNum = 2
                $script:DryRun = $false
                $script:SelfUpdate = $true
                $env:LOCALAPPDATA = $localAppData

                function Test-InstallRootWritable { return $true }
                function Test-GitCheckout { return $false }
                function Test-SymlinkedInstall { return $false }
                function Get-LatestReleaseMetadata {
                    return [pscustomobject]@{
                        tag_name   = "v$currentReleaseVersion"
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

            Assert-Equal -Expected $currentReleaseVersion -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()) -Message 'current.txt should advance after a verified self-update'
            Assert-Equal -Expected $previousReleaseVersion -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'previous.txt') -Raw).Trim()) -Message 'previous.txt should keep the validated running payload version during recovery'
        }
    }
}

if (Should-RunTest 'native payload self-update payload commit failures preserve old current') {
    Invoke-TestCase 'native payload self-update payload commit failures preserve old current' {
        foreach ($failureStep in @('payload-staged', 'payload-validated', 'target-committed')) {
            Invoke-WithTempInstall {
                param($installRoot)

                Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
                New-MatchedVersionedPayload -InstallRoot $installRoot -Version $previousReleaseVersion
                $fixture = New-SelfUpdateFixture -Root $installRoot -Version $currentReleaseVersion
                $foreignStagingRoot = Join-Path $installRoot (Join-Path 'versions' ("{0}.{1}.staging" -f $currentReleaseVersion, ('a' * 32)))
                $null = New-Item -ItemType Directory -Path $foreignStagingRoot -Force
                $foreignSentinel = Join-Path $foreignStagingRoot 'foreign-sentinel.txt'
                Write-Utf8NoBom -Path $foreignSentinel -Content 'foreign-staging-must-survive'
                $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
                $localAppData = Join-Path $installRoot 'localappdata'
                $null = New-Item -ItemType Directory -Path $localAppData -Force

                & {
                    . $payloadSource
                    $script:UpdatesVersion = $previousReleaseVersion
                    $script:InstallRoot = $installRoot
                    $script:JsonMode = $false
                    $script:LogLevel = 'debug'
                    $script:LogLevelNum = 3
                    $script:DryRun = $false
                    $script:SelfUpdate = $true
                    $env:LOCALAPPDATA = $localAppData
                    $env:UPDATES_SELF_UPDATE_TESTING = '1'
                    $env:UPDATES_SELF_UPDATE_FAIL_AFTER = $failureStep

                    function Test-InstallRootWritable { return $true }
                    function Test-GitCheckout { return $false }
                    function Test-SymlinkedInstall { return $false }
                    function Get-LatestReleaseMetadata {
                        return [pscustomobject]@{
                            tag_name   = "v$currentReleaseVersion"
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
                    function Invoke-SelfUpdatedRelaunch { throw 'failure-injected self-update must not relaunch' }

                    try {
                        $result = Invoke-WindowsSelfUpdate -OriginalArgs @()
                        Assert-True -Condition ($null -eq $result) -Message ("{0} failure should be non-fatal and must not relaunch" -f $failureStep)
                    } finally {
                        Remove-Item Env:UPDATES_SELF_UPDATE_TESTING -ErrorAction SilentlyContinue
                        Remove-Item Env:UPDATES_SELF_UPDATE_FAIL_AFTER -ErrorAction SilentlyContinue
                    }
                }

                Assert-Equal -Expected $previousReleaseVersion -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()) -Message ("current pointer must remain old after {0} failure" -f $failureStep)
                $receipt = Get-Content -LiteralPath (Join-Path $installRoot 'install-source.json') -Raw | ConvertFrom-Json -AsHashtable
                Assert-Equal -Expected $previousReleaseVersion -Actual ([string]$receipt.installed_version) -Message ("receipt must remain old after {0} failure" -f $failureStep)
                Assert-Equal -Expected 'foreign-staging-must-survive' -Actual ([System.IO.File]::ReadAllText($foreignSentinel)) -Message ("self-update must preserve foreign staging after {0} failure" -f $failureStep)
                $ownedLeftovers = @(Get-ChildItem -LiteralPath (Join-Path $installRoot 'versions') -Directory -Filter ("{0}.*.staging" -f $currentReleaseVersion) -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $foreignStagingRoot })
                Assert-Equal -Expected 0 -Actual $ownedLeftovers.Count -Message ("self-update must clean only its owned staging root after {0} failure" -f $failureStep)
                $launch = Invoke-Launcher -InstallRoot $installRoot -ArgumentList @('--version')
                Assert-Equal -Expected 0 -Actual $launch.ExitCode -Message ("old current must remain runnable after {0} failure`n{1}" -f $failureStep, $launch.Output)
                Assert-Equal -Expected $previousReleaseVersion -Actual $launch.Stdout.Trim() -Message ("launcher must still execute old current after {0} failure" -f $failureStep)
            }
        }
    }
}

if (Should-RunTest 'native payload self-update rejects redirected mutation roots') {
    Invoke-TestCase 'native payload self-update rejects redirected mutation roots' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
            New-MatchedVersionedPayload -InstallRoot $installRoot -Version $previousReleaseVersion
            $fixture = New-SelfUpdateFixture -Root $installRoot -Version $currentReleaseVersion
            $outside = Join-Path $installRoot 'outside-target'
            $null = New-Item -ItemType Directory -Path $outside -Force
            $sentinel = Join-Path $outside 'sentinel.txt'
            Write-Utf8NoBom -Path $sentinel -Content 'must-remain-unchanged'
            $targetRoot = Join-Path $installRoot (Join-Path 'versions' $currentReleaseVersion)
            $null = New-Item -ItemType Junction -Path $targetRoot -Target $outside
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            $localAppData = Join-Path $installRoot 'localappdata'
            $null = New-Item -ItemType Directory -Path $localAppData -Force

            & {
                . $payloadSource
                $script:UpdatesVersion = $previousReleaseVersion
                $script:InstallRoot = $installRoot
                $script:JsonMode = $false
                $script:LogLevel = 'debug'
                $script:LogLevelNum = 3
                $script:DryRun = $false
                $script:SelfUpdate = $true
                $env:LOCALAPPDATA = $localAppData

                function Test-InstallRootWritable { return $true }
                function Test-GitCheckout { return $false }
                function Test-SymlinkedInstall { return $false }
                function Get-LatestReleaseMetadata {
                    return [pscustomobject]@{
                        tag_name   = "v$currentReleaseVersion"
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
                function Invoke-SelfUpdatedRelaunch { throw 'unsafe-path self-update must not relaunch' }

                $result = Invoke-WindowsSelfUpdate -OriginalArgs @()
                Assert-True -Condition ($null -eq $result) -Message 'unsafe mutation root should skip self-update without relaunch'
            }

            Assert-Equal -Expected 'must-remain-unchanged' -Actual ([System.IO.File]::ReadAllText($sentinel)) -Message 'outside sentinel must remain unchanged'
            Assert-Equal -Expected 1 -Actual (@(Get-ChildItem -LiteralPath $outside -Force).Count) -Message 'self-update must not create or delete through target junction'
            Assert-Equal -Expected $previousReleaseVersion -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()) -Message 'unsafe target must leave old current unchanged'
            $receipt = Get-Content -LiteralPath (Join-Path $installRoot 'install-source.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert-Equal -Expected $previousReleaseVersion -Actual ([string]$receipt.installed_version) -Message 'unsafe target must leave receipt unchanged'
            $launch = Invoke-Launcher -InstallRoot $installRoot -ArgumentList @('--version')
            Assert-Equal -Expected 0 -Actual $launch.ExitCode -Message "old payload must remain runnable`n$($launch.Output)"
            Assert-Equal -Expected $previousReleaseVersion -Actual $launch.Stdout.Trim() -Message 'launcher must still execute old current'
        }
    }
}

if (Should-RunTest 'native payload self-update skips live metadata fetch when cache is fresh') {
    Invoke-TestCase 'native payload self-update skips live metadata fetch when cache is fresh' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            $localAppData = Join-Path $installRoot 'localappdata'
            $null = New-Item -ItemType Directory -Path $localAppData -Force

            & {
                . $payloadSource
                $script:UpdatesVersion = $previousReleaseVersion
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

if (Should-RunTest 'native payload never trusts forged newer cached release metadata') {
    Invoke-TestCase 'native payload never trusts forged newer cached release metadata' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            $localAppData = Join-Path $installRoot 'localappdata'
            $markerPath = Join-Path $installRoot 'live-metadata-marker.txt'
            $null = New-Item -ItemType Directory -Path $localAppData -Force

            & {
                . $payloadSource
                $script:UpdatesVersion = $previousReleaseVersion
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
                function Get-LatestReleaseMetadata {
                    [System.IO.File]::WriteAllText($markerPath, 'fetched')
                    return [pscustomobject]@{ tag_name = "v$previousReleaseVersion"; draft = $false; prerelease = $false; immutable = $true; assets = @() }
                }
                function Invoke-WebRequest { throw 'forged cached URL must never be contacted' }

                $cachePath = Get-SelfUpdateCachePath
                $legacyCache = @(
                    ('checked_at={0}' -f (Get-SelfUpdateEpoch))
                    "latest_tag=v$currentReleaseVersion"
                    'draft=0'
                    'prerelease=0'
                    'immutable=1'
                    'windows_url=https://attacker.invalid/updates-windows.zip'
                    ('windows_digest=sha256:{0}' -f ('0' * 64))
                    'manifest_url=https://attacker.invalid/updates-release.json'
                    ('manifest_digest=sha256:{0}' -f ('0' * 64))
                    'sums_url=https://attacker.invalid/SHA256SUMS'
                    ('sums_digest=sha256:{0}' -f ('0' * 64))
                    ''
                ) -join "`n"
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $cachePath) -Force
                [System.IO.File]::WriteAllText($cachePath, $legacyCache, [System.Text.UTF8Encoding]::new($false))
                $result = Invoke-WindowsSelfUpdate -OriginalArgs @()
                Assert-True -Condition ($null -eq $result) -Message 'live current-version metadata should end self-update cleanly'
            }

            Assert-FileExists -Path $markerPath -Message 'newer cached tags must force canonical live metadata fetch'
            Assert-Equal -Expected $previousReleaseVersion -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()) -Message 'forged cache must not activate a payload'
        }
    }
}

if (Should-RunTest 'native self-update cache persists only timestamp and latest tag') {
    Invoke-TestCase 'native self-update cache persists only timestamp and latest tag' {
        Invoke-WithTempInstall {
            param($installRoot)
            & {
                . (Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot)
                $cachePath = Join-Path $installRoot 'self-update.cache'
                Assert-True -Condition (Write-SelfUpdateCache -Path $cachePath -CheckedAt 123 -LatestTag 'v2.1.0') -Message 'cache write should succeed'
                Assert-Equal -Expected "checked_at=123`nlatest_tag=v2.1.0`n" -Actual ([System.IO.File]::ReadAllText($cachePath)) -Message 'cache must persist tag freshness only'
                [System.IO.File]::AppendAllText($cachePath, "windows_url=https://attacker.invalid/payload.zip`nimmutable=1`n", [System.Text.UTF8Encoding]::new($false))
                $cache = Read-SelfUpdateCache -Path $cachePath
                Assert-Equal -Expected 123 -Actual ([int64]$cache.CheckedAt) -Message 'cache should read checked_at'
                Assert-Equal -Expected 'v2.1.0' -Actual $cache.LatestTag -Message 'cache should read latest_tag'
                Assert-True -Condition ($cache.PSObject.Properties.Name -notcontains 'WindowsUrl') -Message 'legacy trust fields must not be exposed from cache reads'
                Assert-True -Condition ($cache.PSObject.Properties.Name -notcontains 'Immutable') -Message 'legacy trust fields must be ignored'
            }
        }
    }
}

if (Should-RunTest 'native payload fresh newer-version tag-only cache fetches live metadata') {
    Invoke-TestCase 'native payload fresh newer-version tag-only cache fetches live metadata' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            $localAppData = Join-Path $installRoot 'localappdata'
            $markerPath = Join-Path $installRoot 'live-metadata-marker.txt'
            $null = New-Item -ItemType Directory -Path $localAppData -Force

            & {
                . $payloadSource
                $script:UpdatesVersion = $previousReleaseVersion
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
                $null = Write-SelfUpdateCache -Path $cachePath -CheckedAt (Get-SelfUpdateEpoch) -LatestTag "v$currentReleaseVersion"
                $result = Invoke-WindowsSelfUpdate -OriginalArgs @()
                Assert-True -Condition ($null -eq $result) -Message 'tag-only newer-version cache should still exit cleanly after live metadata fallback'
            }

            Assert-FileExists -Path $markerPath -Message 'tag-only newer-version cache should fetch live metadata'
            Assert-Equal -Expected 'fetched' -Actual ((Get-Content -LiteralPath $markerPath -Raw).Trim()) -Message 'live metadata fallback marker mismatch'
        }
    }
}

if (Should-RunTest 'native payload force self-update bypasses fresh cache') {
    Invoke-TestCase 'native payload force self-update bypasses fresh cache' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            $localAppData = Join-Path $installRoot 'localappdata'
            $markerPath = Join-Path $installRoot 'force-self-update-marker.txt'
            $null = New-Item -ItemType Directory -Path $localAppData -Force

            & {
                . $payloadSource
                $script:UpdatesVersion = $previousReleaseVersion
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

if (Should-RunTest 'native payload self-update continues when asset download retries fail') {
    Invoke-TestCase 'native payload self-update continues when asset download retries fail' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            $logPath = Join-Path $installRoot 'self-update.log'

            & {
                . $payloadSource
                $script:UpdatesVersion = $previousReleaseVersion
                $script:InstallRoot = $installRoot
                $script:LogFile = $logPath
                $script:JsonMode = $false
                $script:LogLevel = 'debug'
                $script:LogLevelNum = 3
                $script:DryRun = $false
                $script:SelfUpdate = $true

                function Test-InstallRootWritable { return $true }
                function Test-GitCheckout { return $false }
                function Test-SymlinkedInstall { return $false }
                function Get-LatestReleaseMetadata {
                    return [pscustomobject]@{
                        tag_name   = "v$currentReleaseVersion"
                        draft      = $false
                        prerelease = $false
                        immutable  = $true
                        assets     = @(
                            [pscustomobject]@{ name = 'updates-windows.zip'; digest = 'sha256:deadbeef'; browser_download_url = 'https://example.invalid/updates-windows.zip' },
                            [pscustomobject]@{ name = 'updates-release.json'; digest = 'sha256:deadbeef'; browser_download_url = 'https://example.invalid/updates-release.json' },
                            [pscustomobject]@{ name = 'SHA256SUMS'; digest = 'sha256:deadbeef'; browser_download_url = 'https://example.invalid/SHA256SUMS' }
                        )
                    }
                }
                function Invoke-WebRequest { throw 'simulated download failure' }

                Ensure-LogFileReady
                $result = Invoke-WindowsSelfUpdate -OriginalArgs @()
                Assert-True -Condition ($null -eq $result) -Message 'download failure should stay non-fatal and skip relaunch'
            }

            Assert-Equal -Expected $previousReleaseVersion -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()) -Message 'download failure should leave current.txt unchanged'
            Assert-Match -Text (Get-Content -LiteralPath $logPath -Raw) -Pattern 'self-update asset download or staging failed; continuing' -Message 'download failure should emit the non-fatal warning'
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

            foreach ($overrideValue in @('other/repo', '')) {
                $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--no-color', '--no-emoji') -Environment @{
                    PATH                     = $emptyPath
                    UPDATES_SELF_UPDATE_REPO = $overrideValue
                }

                Assert-Equal -Expected 2 -Actual $result.ExitCode -Message 'custom self-update repo override should be a usage error on Windows v2'
                Assert-Match -Text $result.Output -Pattern 'UPDATES_SELF_UPDATE_REPO' -Message 'error should reference UPDATES_SELF_UPDATE_REPO explicitly'
                Assert-Match -Text $result.Output -Pattern '(?i)(not supported|no longer supported|unsupported)' -Message 'error should explain that custom self-update repos are not supported'
            }
        }
    }
}

if (Should-RunTest 'native payload self-update skips on release digest mismatch') {
    Invoke-TestCase 'native payload self-update skips on release digest mismatch' {
        Invoke-WithTempInstall {
            param($installRoot)

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
            $fixture = New-SelfUpdateFixture -Root $installRoot -Version $currentReleaseVersion
            $logPath = Join-Path $installRoot 'self-update.log'
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            $localAppData = Join-Path $installRoot 'localappdata'
            $null = New-Item -ItemType Directory -Path $localAppData -Force

            & {
                . $payloadSource
                $script:UpdatesVersion = $previousReleaseVersion
                $script:InstallRoot = $installRoot
                $script:LogFile = $logPath
                $script:JsonMode = $false
                $script:LogLevel = 'info'
                $script:LogLevelNum = 2
                $script:DryRun = $false
                $script:SelfUpdate = $true
                $env:LOCALAPPDATA = $localAppData

                function Test-InstallRootWritable { return $true }
                function Test-GitCheckout { return $false }
                function Test-SymlinkedInstall { return $false }
                function Get-LatestReleaseMetadata {
                    return [pscustomobject]@{
                        tag_name   = "v$currentReleaseVersion"
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

            Assert-Equal -Expected $previousReleaseVersion -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()) -Message 'digest mismatch should leave current.txt unchanged'
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

            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
            $fixture = New-SelfUpdateFixture -Root $installRoot -Version $currentReleaseVersion -PayloadBootstrapMin 99
            $logPath = Join-Path $installRoot 'self-update.log'
            $payloadSource = Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot
            $localAppData = Join-Path $installRoot 'localappdata'
            $null = New-Item -ItemType Directory -Path $localAppData -Force

            & {
                . $payloadSource
                $script:UpdatesVersion = $previousReleaseVersion
                $script:InstallRoot = $installRoot
                $script:LogFile = $logPath
                $script:JsonMode = $false
                $script:LogLevel = 'info'
                $script:LogLevelNum = 2
                $script:DryRun = $false
                $script:SelfUpdate = $true
                $env:LOCALAPPDATA = $localAppData

                function Test-InstallRootWritable { return $true }
                function Test-GitCheckout { return $false }
                function Test-SymlinkedInstall { return $false }
                function Get-LatestReleaseMetadata {
                    return [pscustomobject]@{
                        tag_name   = "v$currentReleaseVersion"
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

            Assert-Equal -Expected $previousReleaseVersion -Actual ((Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()) -Message 'invalid extracted manifest should leave current.txt unchanged'
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

if (Should-RunTest 'native registry owns every supported Windows handler') {
    Invoke-TestCase 'native registry owns every supported Windows handler' {
        & {
            . (Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot)
            foreach ($module in @($script:ModuleRegistry | Where-Object { $_.Platforms -contains 'windows' })) {
                Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$module.Handler)) -Message ("Windows module {0} should own a handler" -f $module.Name)
                Assert-True -Condition ($null -ne (Get-Command -Name $module.Handler -CommandType Function -ErrorAction SilentlyContinue)) -Message ("handler {0} should exist" -f $module.Handler)
            }
        }
    }
}

if (Should-RunTest 'native payload runs Claude and Pi update modules') {
    Invoke-TestCase 'native payload runs Claude and Pi update modules' {
        Invoke-WithTempInstall {
            param($installRoot)
            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $currentReleaseVersion
            $stubDir = Join-Path $installRoot 'stubs'
            $log = Join-Path $installRoot 'ai-modules.log'
            $null = New-Item -ItemType Directory -Path $stubDir -Force
            Write-CmdStub -Path (Join-Path $stubDir 'claude.cmd') -Lines @(('echo claude:%*>>"{0}"' -f $log))
            Write-CmdStub -Path (Join-Path $stubDir 'pi.cmd') -Lines @(('echo pi:%*>>"{0}"' -f $log))
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--no-self-update', '--only', 'claude,pi', '--no-emoji', '--no-color') -Environment @{ PATH = $stubDir }
            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "Claude/Pi modules should succeed`n$($result.Output)"
            $calls = Get-Content -LiteralPath $log -Raw
            Assert-Match -Text $calls -Pattern '(?m)^claude:update\s*$' -Message 'Claude module should run claude update'
            Assert-Match -Text $calls -Pattern '(?m)^pi:update\s*$' -Message 'Pi module should run pi update'
        }
    }
}

if (Should-RunTest 'native Claude and Pi modules cover missing dry-run failure strict and JSON') {
    Invoke-TestCase 'native Claude and Pi modules cover missing dry-run failure strict and JSON' {
        Invoke-WithTempInstall {
            param($installRoot)
            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $currentReleaseVersion
            $emptyPath = Join-Path $installRoot 'empty'
            $null = New-Item -ItemType Directory -Path $emptyPath
            $missing = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--no-self-update', '--only', 'claude', '--no-emoji') -Environment @{ PATH = $emptyPath }
            Assert-Equal -Expected 1 -Actual $missing.ExitCode -Message 'explicit missing Claude dependency should fail the run'
            $missingPi = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--no-self-update', '--only', 'pi', '--no-emoji') -Environment @{ PATH = $emptyPath }
            Assert-Equal -Expected 1 -Actual $missingPi.ExitCode -Message 'explicit missing Pi dependency should fail the run'
            Assert-Match -Text $missingPi.Output -Pattern '(?i)pi not found' -Message 'missing Pi dependency should be explicit'

            $stubDir = Join-Path $installRoot 'stubs'
            $log = Join-Path $installRoot 'ai-matrix.log'
            $null = New-Item -ItemType Directory -Path $stubDir
            Write-CmdStub -Path (Join-Path $stubDir 'claude.cmd') -Lines @(('echo claude:%*>>"{0}"' -f $log))
            Write-CmdStub -Path (Join-Path $stubDir 'pi.cmd') -Lines @(('echo pi:%*>>"{0}"' -f $log))
            $dry = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--no-self-update', '--only', 'claude,pi', '--dry-run', '--no-emoji') -Environment @{ PATH = $stubDir }
            Assert-Equal -Expected 0 -Actual $dry.ExitCode -Message 'Claude/Pi dry-run should succeed'
            Assert-True -Condition (-not (Test-Path -LiteralPath $log)) -Message 'Claude/Pi dry-run must not invoke commands'
            Assert-Match -Text $dry.Output -Pattern '(?i)DRY RUN: .*claude(\.cmd)? update' -Message 'Claude dry-run command should be visible'
            Assert-Match -Text $dry.Output -Pattern '(?i)DRY RUN: .*pi(\.cmd)? update' -Message 'Pi dry-run command should be visible'

            Write-Utf8NoBom -Path (Join-Path $stubDir 'claude.cmd') -Content "@echo off`r`necho claude-failed`r`nexit /b 7`r`n"
            Write-CmdStub -Path (Join-Path $stubDir 'pi.cmd') -Lines @(('echo pi:%*>>"{0}"' -f $log))
            $strict = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--no-self-update', '--only', 'claude,pi', '--strict', '--json', '--no-emoji') -Environment @{ PATH = $stubDir }
            Assert-Equal -Expected 1 -Actual $strict.ExitCode -Message 'Claude command failure should fail the run'
            Assert-True -Condition (-not (Test-Path -LiteralPath $log)) -Message 'strict mode must stop before Pi after Claude failure'
            $events = @($strict.Stdout -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-True -Condition ($null -ne ($events | Where-Object { $_.event -eq 'module_start' -and $_.PSObject.Properties['module'] -and $_.module -eq 'claude' } | Select-Object -First 1)) -Message 'JSON should include Claude start event'
            Assert-True -Condition ($null -ne ($events | Where-Object { $_.event -eq 'module_end' -and $_.PSObject.Properties['module'] -and $_.module -eq 'claude' -and $_.status -eq 'fail' } | Select-Object -First 1)) -Message 'JSON should include Claude failure event'
            Assert-True -Condition ($null -eq ($events | Where-Object { $_.PSObject.Properties['module'] -and $_.module -eq 'pi' } | Select-Object -First 1)) -Message 'strict JSON must not include Pi events'

            Write-CmdStub -Path (Join-Path $stubDir 'claude.cmd') -Lines @(('echo claude:%*>>"{0}"' -f $log))
            Write-Utf8NoBom -Path (Join-Path $stubDir 'pi.cmd') -Content "@echo off`r`necho pi-failed`r`nexit /b 9`r`n"
            $piFailure = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--no-self-update', '--only', 'pi', '--json', '--no-emoji') -Environment @{ PATH = $stubDir }
            Assert-Equal -Expected 1 -Actual $piFailure.ExitCode -Message 'Pi command failure should fail non-strict run'
            $piEvents = @($piFailure.Stdout -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-True -Condition ($null -ne ($piEvents | Where-Object { $_.event -eq 'module_end' -and $_.module -eq 'pi' -and $_.status -eq 'fail' } | Select-Object -First 1)) -Message 'JSON should include Pi failure event'
        }
    }
}

if (Should-RunTest 'native payload rejects duplicate or noncanonical version assignments') {
    Invoke-TestCase 'native payload rejects duplicate or noncanonical version assignments' {
        Invoke-WithTempInstall {
            param($installRoot)
            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $currentReleaseVersion -WithReceipt
            $payloadPath = Join-Path $installRoot (Join-Path 'versions' (Join-Path $currentReleaseVersion 'updates-main.ps1'))
            $original = Get-Content -LiteralPath $payloadPath -Raw
            foreach ($mutant in @(
                ($original + "`n`$script:UpdatesVersion = '$currentReleaseVersion'`n"),
                ($original -replace [regex]::Escape("`$script:UpdatesVersion = '$currentReleaseVersion'"), "`$script:UpdatesVersion='$currentReleaseVersion'")
            )) {
                Write-Utf8NoBom -Path $payloadPath -Content $mutant
                & {
                    . (Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot)
                    Assert-True -Condition (-not (Test-VersionedPayloadManifest -VersionRoot (Split-Path -Parent $payloadPath) -ExpectedVersion $currentReleaseVersion)) -Message 'validator must reject duplicate or noncanonical UpdatesVersion assignments'
                }
                $doctor = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--doctor', '--json') -Environment @{ PATH = '' }
                Assert-Equal -Expected 1 -Actual $doctor.ExitCode -Message 'doctor must reject duplicate or noncanonical UpdatesVersion assignments'
            }
        }
    }
}

if (Should-RunTest 'native doctor rejects file-level payload reparse points') {
    Invoke-TestCase 'native doctor rejects file-level payload reparse points' {
        Invoke-WithTempInstall {
            param($installRoot)
            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $currentReleaseVersion -WithReceipt
            $versionRoot = Join-Path $installRoot (Join-Path 'versions' $currentReleaseVersion)
            $payloadPath = Join-Path $versionRoot 'updates-main.ps1'
            $realPayload = Join-Path $installRoot 'redirected-payload.ps1'
            Move-Item -LiteralPath $payloadPath -Destination $realPayload
            try {
                $null = New-Item -ItemType SymbolicLink -Path $payloadPath -Target $realPayload -ErrorAction Stop
            } catch {
                Write-Host 'SKIP: file symbolic links require Windows Developer Mode or elevation.'
                return
            }
            $doctor = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--doctor', '--json') -Environment @{ PATH = '' }
            Assert-Equal -Expected 1 -Actual $doctor.ExitCode -Message 'doctor must reject file-level payload reparse points'
            Assert-Match -Text $doctor.Stdout -Pattern '(?i)(invalid|redirected|reparse)' -Message 'doctor should report redirected payload as invalid'
        }
    }
}

if (Should-RunTest 'native doctor rejects redirected pointer and receipt files') {
    Invoke-TestCase 'native doctor rejects redirected pointer and receipt files' {
        foreach ($fileName in @('current.txt', 'previous.txt', 'install-source.json')) {
            Invoke-WithTempInstall {
                param($installRoot)
                Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $currentReleaseVersion -WithReceipt
                Write-Utf8NoBom -Path (Join-Path $installRoot 'previous.txt') -Content ''
                $trustedPath = Join-Path $installRoot $fileName
                $outsidePath = Join-Path $installRoot ('redirected-' + $fileName)
                Move-Item -LiteralPath $trustedPath -Destination $outsidePath
                try {
                    $null = New-Item -ItemType SymbolicLink -Path $trustedPath -Target $outsidePath -ErrorAction Stop
                } catch {
                    Write-Host 'SKIP: file symbolic links require Windows Developer Mode or elevation.'
                    return
                }

                $doctor = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--doctor', '--json') -Environment @{ PATH = '' }
                $events = @($doctor.Stdout -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
                $checkName = if ($fileName -eq 'install-source.json') { 'install-receipt' } else { $fileName }
                $event = $events | Where-Object { $_.event -eq 'doctor_check' -and $_.check -eq $checkName } | Select-Object -First 1
                Assert-True -Condition ($null -ne $event) -Message ("doctor should emit a check for redirected {0}" -f $fileName)
                Assert-Match -Text ([string]$event.message) -Pattern '(?i)(redirected|outside install root)' -Message ("doctor should reject redirected {0} before reading" -f $fileName)
                $expectedStatus = if ($fileName -eq 'previous.txt') { 'warn' } else { 'fail' }
                Assert-Equal -Expected $expectedStatus -Actual ([string]$event.status) -Message ("redirected {0} should have correct severity" -f $fileName)
            }
        }
    }
}

if (Should-RunTest 'native payload rejects embedded payload version mismatch') {
    Invoke-TestCase 'native payload rejects embedded payload version mismatch' {
        Invoke-WithTempInstall {
            param($installRoot)
            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $currentReleaseVersion -WithReceipt
            Write-Utf8NoBom -Path (Join-Path $installRoot 'previous.txt') -Content ''
            $payloadPath = Join-Path $installRoot (Join-Path 'versions' (Join-Path $currentReleaseVersion 'updates-main.ps1'))
            $payload = Get-Content -LiteralPath $payloadPath -Raw
            $payload = [regex]::Replace($payload, '(?m)^\$script:UpdatesVersion\s*=\s*''[^'']+''', "`$script:UpdatesVersion = '9.9.9'", 1)
            Write-Utf8NoBom -Path $payloadPath -Content $payload
            & {
                . (Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot)
                Assert-True -Condition (-not (Test-VersionedPayloadManifest -VersionRoot (Split-Path -Parent $payloadPath) -ExpectedVersion $currentReleaseVersion)) -Message 'manifest validator must reject embedded version mismatch'
            }
            $doctor = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--doctor', '--json') -Environment @{ PATH = '' }
            Assert-Equal -Expected 1 -Actual $doctor.ExitCode -Message 'doctor should fail embedded payload version mismatch'
            Assert-Match -Text $doctor.Stdout -Pattern '(?i)payload.*invalid' -Message 'doctor should report invalid payload'
        }
    }
}

if (Should-RunTest 'native doctor is local read-only JSONL') {
    Invoke-TestCase 'native doctor is local read-only JSONL' {
        Invoke-WithTempInstall {
            param($installRoot)
            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $currentReleaseVersion -WithReceipt
            Write-Utf8NoBom -Path (Join-Path $installRoot 'previous.txt') -Content ''
            $before = @(Get-ChildItem -LiteralPath $installRoot -Recurse -File | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join "`n"
            $doctorLog = Join-Path $installRoot 'doctor-must-not-create.log'
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--doctor', '--json', '--log-file', $doctorLog) -Environment @{ PATH = '' }
            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "healthy doctor should exit 0`n$($result.Output)"
            foreach ($line in @($result.Stdout -split "`r?`n" | Where-Object { $_ })) { $null = $line | ConvertFrom-Json }
            Assert-Match -Text $result.Stdout -Pattern '"event":"doctor_check"' -Message 'doctor should emit check events'
            Assert-Match -Text $result.Stdout -Pattern '"event":"doctor_summary"' -Message 'doctor should emit summary event'
            $after = @(Get-ChildItem -LiteralPath $installRoot -Recurse -File | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join "`n"
            Assert-Equal -Expected $before -Actual $after -Message 'doctor must not mutate the install'
            Assert-True -Condition (-not (Test-Path -LiteralPath $doctorLog)) -Message 'doctor must not initialize --log-file'

            Write-Utf8NoBom -Path (Join-Path $installRoot 'install-source.json') -Content '{broken'
            $broken = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--doctor', '--json') -Environment @{ PATH = '' }
            Assert-Equal -Expected 1 -Actual $broken.ExitCode -Message 'doctor integrity failures should exit 1'
            $summary = @($broken.Stdout -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'doctor_summary' })[-1]
            Assert-True -Condition ([int]$summary.fail -gt 0) -Message 'doctor failure summary should report failures'
        }
    }
}

if (Should-RunTest 'native doctor human output matches shared format') {
    Invoke-TestCase 'native doctor human output matches shared format' {
        Invoke-WithTempInstall {
            param($installRoot)
            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $currentReleaseVersion -WithReceipt
            Write-Utf8NoBom -Path (Join-Path $installRoot 'previous.txt') -Content ''
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--doctor') -Environment @{ PATH = '' }
            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "doctor warnings should exit 0`n$($result.Output)"
            Assert-Match -Text $result.Stdout -Pattern '(?m)^OK\s{4}bootstrap\s{12}bootstrap entrypoints are present\r?$' -Message 'doctor checks should use padded STATUS/check/message columns'
            Assert-Match -Text $result.Stdout -Pattern '(?m)^(?:OK\s{4}|WARN\s{2})install-root\s{9}(?:paths are accessible|paths are accessible, contained)' -Message 'doctor install-root result should use padded shared format'
            Assert-Match -Text $result.Stdout -Pattern '(?m)^SUMMARY ok=\d+ warn=\d+ fail=0\r?$' -Message 'doctor summary should match Bash exactly'
            Assert-True -Condition ($result.Stdout -notmatch '(?m)^doctor ') -Message 'doctor human output must not use the former Windows-only prefix'
        }
    }
}

if (Should-RunTest 'native doctor writability check uses ACLs without writes') {
    Invoke-TestCase 'native doctor writability check uses ACLs without writes' {
        Invoke-WithTempInstall {
            param($installRoot)
            $null = New-Item -ItemType Directory -Path $installRoot -Force
            $beforeNames = @(Get-ChildItem -LiteralPath $installRoot -Force | ForEach-Object Name)
            & {
                . (Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot)
                Assert-True -Condition (Get-PathEffectiveWriteAccess -Path $installRoot) -Message 'temporary install root should initially be writable'
                $originalAcl = Get-Acl -LiteralPath $installRoot
                try {
                    $acl = Get-Acl -LiteralPath $installRoot
                    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
                    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                        $sid,
                        [System.Security.AccessControl.FileSystemRights]::Write,
                        [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit,
                        [System.Security.AccessControl.PropagationFlags]::None,
                        [System.Security.AccessControl.AccessControlType]::Deny
                    )
                    $null = $acl.AddAccessRule($rule)
                    Set-Acl -LiteralPath $installRoot -AclObject $acl
                    Assert-True -Condition (-not (Get-PathEffectiveWriteAccess -Path $installRoot)) -Message 'explicit deny-write ACL should be reported as non-writable'
                } finally {
                    Set-Acl -LiteralPath $installRoot -AclObject $originalAcl
                }
            }
            $afterNames = @(Get-ChildItem -LiteralPath $installRoot -Force | ForEach-Object Name)
            Assert-Equal -Expected ($beforeNames -join "`n") -Actual ($afterNames -join "`n") -Message 'ACL writability check must not create probe files'
        }
    }
}

if (Should-RunTest 'native doctor accepts receipt for newest valid staged payload') {
    Invoke-TestCase 'native doctor accepts receipt for newest valid staged payload' {
        Invoke-WithTempInstall {
            param($installRoot)
            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
            New-MatchedVersionedPayload -InstallRoot $installRoot -Version $previousReleaseVersion
            New-MatchedVersionedPayload -InstallRoot $installRoot -Version $currentReleaseVersion
            Write-InstallReceipt -InstallRoot $installRoot -InstalledVersion $currentReleaseVersion
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--doctor', '--json') -Environment @{ PATH = '' }
            Assert-Equal -Expected 0 -Actual $result.ExitCode -Message "receipt may reference newest fully installed payload before current activation`n$($result.Output)"
        }
    }
}

if (Should-RunTest 'native self-update metadata commit failures preserve runnable payload') {
    Invoke-TestCase 'native self-update metadata commit failures preserve runnable payload' {
        foreach ($failureStep in @('previous-temp', 'previous', 'receipt-temp', 'receipt', 'current-temp', 'current')) {
            Invoke-WithTempInstall {
                param($installRoot)
                Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $previousReleaseVersion -WithReceipt
                New-MatchedVersionedPayload -InstallRoot $installRoot -Version $currentReleaseVersion
                $failureMessage = & {
                    . (Resolve-RepoWindowsPayloadSource -RepoRoot $repoRoot)
                    $script:InstallRoot = $installRoot
                    function Invoke-SelfUpdateCommitHook { param([string]$Step); if ($Step -eq $failureStep) { throw "injected $Step failure" } }
                    try {
                        Commit-SelfUpdateMetadata -PreviousVersion $previousReleaseVersion -InstalledVersion $currentReleaseVersion
                        return ''
                    } catch {
                        return $_.Exception.Message
                    }
                }
                Assert-Match -Text $failureMessage -Pattern ('injected {0} failure' -f [regex]::Escape($failureStep)) -Message ("failure hook should identify {0}" -f $failureStep)
                $current = (Get-Content -LiteralPath (Join-Path $installRoot 'current.txt') -Raw).Trim()
                $currentRoot = Join-Path $installRoot (Join-Path 'versions' $current)
                Assert-True -Condition (Test-Path -LiteralPath (Join-Path $currentRoot 'updates-main.ps1') -PathType Leaf) -Message ("current payload must remain runnable after {0} failure" -f $failureStep)
                $receipt = Get-Content -LiteralPath (Join-Path $installRoot 'install-source.json') -Raw | ConvertFrom-Json -AsHashtable
                $receiptRoot = Join-Path $installRoot (Join-Path 'versions' ([string]$receipt.installed_version))
                Assert-True -Condition (Test-Path -LiteralPath (Join-Path $receiptRoot 'updates-main.ps1') -PathType Leaf) -Message ("receipt payload must remain valid after {0} failure" -f $failureStep)
                $tempLeftovers = @(Get-ChildItem -LiteralPath $installRoot -File -Filter '.*.tmp' -ErrorAction SilentlyContinue)
                Assert-Equal -Expected 0 -Actual $tempLeftovers.Count -Message ("self-update must clean GUID temp files after {0} failure" -f $failureStep)
            }
        }
    }
}

if (Should-RunTest 'native doctor rejects reparse-point payload root') {
    Invoke-TestCase 'native doctor rejects reparse-point payload root' {
        Invoke-WithTempInstall {
            param($installRoot)
            Install-RepoWindowsRuntime -RepoRoot $repoRoot -InstallRoot $installRoot -Version $currentReleaseVersion -WithReceipt
            Write-Utf8NoBom -Path (Join-Path $installRoot 'previous.txt') -Content ''
            $realRoot = Join-Path $installRoot 'real-payload'
            Move-Item -LiteralPath (Join-Path $installRoot (Join-Path 'versions' $currentReleaseVersion)) -Destination $realRoot
            $null = New-Item -ItemType Junction -Path (Join-Path $installRoot (Join-Path 'versions' $currentReleaseVersion)) -Target $realRoot
            $result = Invoke-Bootstrap -InstallRoot $installRoot -ArgumentList @('--doctor', '--json') -Environment @{ PATH = '' }
            Assert-Equal -Expected 1 -Actual $result.ExitCode -Message 'doctor should fail reparse-point payload roots'
            Assert-Match -Text $result.Stdout -Pattern '(?i)reparse point' -Message 'doctor should identify the reparse-point seam'
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
