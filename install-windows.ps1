#requires -Version 7.0
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Version = '2.1.0',
    [string]$InstallRoot,
    [string]$SourceZip,
    [string]$SourceZipSha256,
    [string]$SourceRoot,
    [string]$ReleaseBaseUri = 'https://github.com/amanthanvi/updates/releases/download'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CanonicalRepo = 'amanthanvi/updates'
$script:ReleaseChannel = 'github-release'
$script:BootstrapMin = 1
$script:WindowsAssetName = 'updates-windows.zip'
$script:ReleaseManifestName = 'updates-release.json'
$script:ChecksumAssetName = 'SHA256SUMS'

function Invoke-InstallCommitHook {
    param([string]$Step)
    if ($env:UPDATES_INSTALL_TESTING -eq '1' -and $env:UPDATES_INSTALL_FAIL_AFTER -eq $Step) {
        throw "injected installer failure after $Step"
    }
}

function Fail-Install {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
    exit 2
}

function Test-SemVerString {
    param([string]$Value)

    return $Value -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$'
}

function Get-CanonicalPath {
    param([string]$Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PathWithin {
    param(
        [string]$ParentPath,
        [string]$CandidatePath
    )

    $parentFull = (Get-CanonicalPath $ParentPath).TrimEnd('\', '/')
    $candidateFull = Get-CanonicalPath $CandidatePath
    $comparison = [System.StringComparison]::OrdinalIgnoreCase

    if ($candidateFull.Equals($parentFull, $comparison)) {
        return $true
    }

    $prefix = $parentFull + [System.IO.Path]::DirectorySeparatorChar
    return $candidateFull.StartsWith($prefix, $comparison)
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

    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $Data
    )

    Write-Utf8NoBom -Path $Path -Content (($Data | ConvertTo-Json -Depth 10) + "`n")
}

function Write-AtomicText {
    param([string]$Path, [string]$Content, [string]$Step)
    $dir = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $dir -Force
    $temp = Join-Path $dir ('.{0}.{1}.tmp' -f ([System.IO.Path]::GetFileName($Path)), [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temp, $Content, [System.Text.UTF8Encoding]::new($false))
        Invoke-InstallCommitHook -Step ($Step + '-temp')
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-TrimmedTextFile {
    param([string]$Path)

    return ([System.IO.File]::ReadAllText($Path)).Trim()
}

function Assert-FileExists {
    param(
        [string]$Path,
        [string]$Message
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail-Install $Message
    }
}

function Test-TrustedRegularFile {
    param([string]$ParentPath, [string]$Path)
    try {
        if (-not (Test-PathWithin -ParentPath $ParentPath -CandidatePath $Path)) { return $false }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return (
            -not $item.PSIsContainer -and
            ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0
        )
    } catch {
        return $false
    }
}

function Get-DefaultInstallRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Fail-Install 'updates: LOCALAPPDATA is required for the native Windows install root.'
    }

    return (Join-Path $env:LOCALAPPDATA 'Programs\updates')
}

function Get-WindowsPayloadVersion {
    param([string]$PayloadPath)

    $content = [System.IO.File]::ReadAllText($PayloadPath)
    $assignments = [regex]::Matches($content, '(?m)^\s*\$script:UpdatesVersion\s*=.*$')
    $canonical = [regex]::Matches($content, '(?m)^\$script:UpdatesVersion = ''(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)''$')
    if ($assignments.Count -ne 1 -or $canonical.Count -ne 1) {
        Fail-Install "updates: payload '$PayloadPath' must contain exactly one canonical UpdatesVersion assignment."
    }

    return $canonical[0].Groups[1].Value
}

function New-TempDirectory {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('updates-install-{0}' -f [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $root -Force
    return $root
}

function Remove-TempDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or (-not (Test-Path -LiteralPath $Path))) {
        return
    }

    $tempRoot = [System.IO.Path]::GetTempPath()
    if (-not (Test-PathWithin -ParentPath $tempRoot -CandidatePath $Path)) {
        Fail-Install "updates: refusing to remove unexpected temporary path '$Path'."
    }

    Remove-Item -LiteralPath $Path -Recurse -Force
}

function New-LayoutFromSourceRoot {
    param(
        [string]$Root,
        [string]$ExpectedVersion,
        [string]$OutputRoot
    )

    $sourceRootFull = Get-CanonicalPath $Root
    $cmdSource = Join-Path $sourceRootFull 'updates.cmd'
    $bootstrapSource = Join-Path $sourceRootFull 'updates.ps1'
    $payloadSource = Join-Path $sourceRootFull 'updates-main.ps1'

    Assert-FileExists -Path $cmdSource -Message "updates: missing source file '$cmdSource'."
    Assert-FileExists -Path $bootstrapSource -Message "updates: missing source file '$bootstrapSource'."
    Assert-FileExists -Path $payloadSource -Message "updates: missing source file '$payloadSource'."

    $payloadVersion = Get-WindowsPayloadVersion -PayloadPath $payloadSource
    if ($payloadVersion -ne $ExpectedVersion) {
        Fail-Install "updates: source payload version '$payloadVersion' does not match requested version '$ExpectedVersion'."
    }

    $versionRoot = Join-Path $OutputRoot (Join-Path 'versions' $ExpectedVersion)
    $null = New-Item -ItemType Directory -Path $versionRoot -Force

    Copy-Item -LiteralPath $cmdSource -Destination (Join-Path $OutputRoot 'updates.cmd') -Force
    Copy-Item -LiteralPath $bootstrapSource -Destination (Join-Path $OutputRoot 'updates.ps1') -Force
    Copy-Item -LiteralPath $payloadSource -Destination (Join-Path $versionRoot 'updates-main.ps1') -Force

    Write-Utf8NoBom -Path (Join-Path $OutputRoot 'current.txt') -Content ($ExpectedVersion + "`n")
    Write-Utf8NoBom -Path (Join-Path $OutputRoot 'previous.txt') -Content ''
    Write-JsonFile -Path (Join-Path $OutputRoot 'install-source.json') -Data ([ordered]@{
        kind              = 'standalone'
        channel           = $script:ReleaseChannel
        source_repo       = $script:CanonicalRepo
        scope             = 'user'
        installed_version = $ExpectedVersion
    })
    Write-JsonFile -Path (Join-Path $versionRoot 'manifest.json') -Data ([ordered]@{
        version       = $ExpectedVersion
        bootstrap_min = $script:BootstrapMin
        entry_script  = 'updates-main.ps1'
    })
}

function Expand-SourceZip {
    param(
        [string]$ZipPath,
        [string]$OutputRoot
    )

    Assert-FileExists -Path $ZipPath -Message "updates: source zip not found at '$ZipPath'."
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $OutputRoot -Force
}

function Get-AuthenticatedRelease {
    param(
        [string]$RequestedVersion,
        [string]$OutputRoot
    )
    $headers = @{ 'User-Agent' = 'updates-install'; Accept = 'application/vnd.github+json' }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)"
    }
    $fixtureRoot = if ($env:UPDATES_INSTALL_TESTING -eq '1') { $env:UPDATES_INSTALL_RELEASE_FIXTURE_ROOT } else { $null }
    if ($fixtureRoot) {
        [Console]::Error.WriteLine('WARNING: updates installer test fixture mode bypasses the live canonical GitHub release fetch; verification uses local fixture files.')
        $release = Get-JsonFile -Path (Join-Path $fixtureRoot 'release-metadata.json')
        Write-Utf8NoBom -Path (Join-Path $fixtureRoot 'authorization-kind.txt') -Content $(if ($headers.ContainsKey('Authorization')) { 'bearer' } else { 'none' })
    } else {
        $release = Invoke-RestMethod -Uri ("https://api.github.com/repos/{0}/releases/tags/v{1}" -f $script:CanonicalRepo, $RequestedVersion) -Headers $headers -TimeoutSec 60
    }
    if ([string]$release.tag_name -ne "v$RequestedVersion" -or [bool]$release.draft -or [bool]$release.prerelease -or (-not [bool]$release.immutable)) {
        Fail-Install 'updates: release metadata is mutable, draft, prerelease, or has the wrong tag.'
    }
    $assets = @{}
    foreach ($asset in @($release.assets)) { $assets[[string]$asset.name] = $asset }
    foreach ($name in @($script:WindowsAssetName, $script:ReleaseManifestName, $script:ChecksumAssetName)) {
        if (-not $assets.ContainsKey($name) -or [string]$assets[$name].digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
            Fail-Install "updates: release asset '$name' is missing or has no SHA-256 digest."
        }
        $path = Join-Path $OutputRoot $name
        [Console]::Error.WriteLine("updates: downloading $($assets[$name].browser_download_url)")
        if ($fixtureRoot) {
            Copy-Item -LiteralPath (Join-Path $fixtureRoot $name) -Destination $path -Force
        } else {
            Invoke-WebRequest -Uri $assets[$name].browser_download_url -OutFile $path -Headers $headers -TimeoutSec 60
        }
        if (('sha256:' + (Get-Sha256Hex $path)) -ne ([string]$assets[$name].digest).ToLowerInvariant()) {
            Fail-Install "updates: release digest mismatch for '$name'."
        }
    }
    $manifest = Get-JsonFile -Path (Join-Path $OutputRoot $script:ReleaseManifestName)
    if (
        [string]$manifest.version -ne $RequestedVersion -or
        [string]$manifest.source_repo -ne $script:CanonicalRepo -or
        [string]$manifest.channel -ne $script:ReleaseChannel -or
        [string]$manifest.bootstrap_min -ne [string]$script:BootstrapMin -or
        [string]$manifest.windows_asset -ne $script:WindowsAssetName -or
        [string]$manifest.unix_asset -ne 'updates' -or
        [string]$manifest.checksum_asset -ne $script:ChecksumAssetName
    ) {
        Fail-Install 'updates: release manifest does not match the requested Windows release.'
    }
    $sumPattern = ('^([0-9a-fA-F]{{64}})\s+{0}$' -f [regex]::Escape($script:WindowsAssetName))
    $sumLine = Select-String -LiteralPath (Join-Path $OutputRoot $script:ChecksumAssetName) -Pattern $sumPattern | Select-Object -First 1
    if (-not $sumLine -or $sumLine.Matches[0].Groups[1].Value.ToLowerInvariant() -ne (Get-Sha256Hex (Join-Path $OutputRoot $script:WindowsAssetName))) {
        Fail-Install 'updates: SHA256SUMS does not authenticate updates-windows.zip.'
    }
    return (Join-Path $OutputRoot $script:WindowsAssetName)
}

function Get-JsonFile {
    param([string]$Path)

    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable)
    } catch {
        Fail-Install "updates: invalid JSON in '$Path'."
    }
}

function Get-ValidatedLayout {
    param(
        [string]$LayoutRoot,
        [string]$ExpectedVersion
    )

    $layoutRootFull = Get-CanonicalPath $LayoutRoot
    foreach ($fileName in @('updates.cmd', 'updates.ps1', 'current.txt', 'previous.txt', 'install-source.json')) {
        $layoutFile = Join-Path $layoutRootFull $fileName
        if (-not (Test-TrustedRegularFile -ParentPath $layoutRootFull -Path $layoutFile)) {
            Fail-Install "updates: layout file '$fileName' is missing, redirected, or outside the layout root."
        }
    }

    $currentVersion = Read-TrimmedTextFile (Join-Path $layoutRootFull 'current.txt')
    if (-not (Test-SemVerString $currentVersion)) {
        Fail-Install "updates: current.txt version '$currentVersion' is not SemVer."
    }

    if ($currentVersion -ne $ExpectedVersion) {
        Fail-Install "updates: current.txt version '$currentVersion' does not match requested version '$ExpectedVersion'."
    }

    $receiptPath = Join-Path $layoutRootFull 'install-source.json'
    $receipt = Get-JsonFile -Path $receiptPath
    if (
        $receipt.kind -ne 'standalone' -or
        $receipt.channel -ne $script:ReleaseChannel -or
        $receipt.source_repo -ne $script:CanonicalRepo -or
        $receipt.scope -ne 'user' -or
        $receipt.installed_version -ne $currentVersion
    ) {
        Fail-Install "updates: install-source.json does not match the official standalone receipt contract."
    }

    $versionsRoot = Join-Path $layoutRootFull 'versions'
    $versionRoot = Get-CanonicalPath (Join-Path $versionsRoot $currentVersion)
    if (-not (Test-PathWithin -ParentPath $versionsRoot -CandidatePath $versionRoot)) {
        Fail-Install 'updates: version directory escapes versions root.'
    }

    if (-not (Test-Path -LiteralPath $versionRoot -PathType Container)) {
        Fail-Install "updates: missing version directory '$versionRoot'."
    }

    $manifestPath = Join-Path $versionRoot 'manifest.json'
    $payloadPath = Join-Path $versionRoot 'updates-main.ps1'
    if (-not (Test-TrustedRegularFile -ParentPath $versionRoot -Path $manifestPath)) { Fail-Install "updates: payload manifest is missing or redirected." }
    if (-not (Test-TrustedRegularFile -ParentPath $versionRoot -Path $payloadPath)) { Fail-Install "updates: payload script is missing or redirected." }

    $manifest = Get-JsonFile -Path $manifestPath
    if (
        $manifest.version -ne $currentVersion -or
        [string]$manifest.bootstrap_min -ne [string]$script:BootstrapMin -or
        $manifest.entry_script -ne 'updates-main.ps1'
    ) {
        Fail-Install "updates: payload manifest does not match the v$ExpectedVersion Windows contract."
    }

    $payloadVersion = Get-WindowsPayloadVersion -PayloadPath $payloadPath
    if ($payloadVersion -ne $currentVersion) {
        Fail-Install "updates: payload version '$payloadVersion' does not match current.txt '$currentVersion'."
    }

    return [pscustomobject]@{
        LayoutRoot     = $layoutRootFull
        CurrentVersion = $currentVersion
        VersionRoot    = $versionRoot
    }
}

function Test-InstalledVersionRoot {
    param([string]$VersionRoot, [string]$ExpectedVersion)
    try {
        $manifestPath = Join-Path $VersionRoot 'manifest.json'
        $payloadPath = Join-Path $VersionRoot 'updates-main.ps1'
        $rootItem = Get-Item -LiteralPath $VersionRoot -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if (-not (Test-TrustedRegularFile -ParentPath $VersionRoot -Path $manifestPath) -or -not (Test-TrustedRegularFile -ParentPath $VersionRoot -Path $payloadPath)) { return $false }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
        if ($manifest.version -ne $ExpectedVersion -or [string]$manifest.bootstrap_min -ne [string]$script:BootstrapMin -or $manifest.entry_script -ne 'updates-main.ps1') { return $false }
        return (Get-WindowsPayloadVersion -PayloadPath $payloadPath) -eq $ExpectedVersion
    } catch {
        return $false
    }
}

function Copy-LayoutToInstallRoot {
    param(
        [pscustomobject]$Layout,
        [string]$TargetRoot
    )

    $targetRootFull = Get-CanonicalPath $TargetRoot
    $versionsRoot = Join-Path $targetRootFull 'versions'
    $targetVersionRoot = Join-Path $versionsRoot $Layout.CurrentVersion
    $stagingRoot = Join-Path $versionsRoot ('.install-{0}-{1}.staging' -f $Layout.CurrentVersion, [guid]::NewGuid().ToString('N'))

    foreach ($trustedRoot in @($targetRootFull, $versionsRoot, $targetVersionRoot)) {
        if (Test-Path -LiteralPath $trustedRoot) {
            $item = Get-Item -LiteralPath $trustedRoot -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail-Install "updates: refusing to install through reparse-point path '$trustedRoot'."
            }
        }
    }

    $null = New-Item -ItemType Directory -Path $targetRootFull -Force
    $null = New-Item -ItemType Directory -Path $stagingRoot -Force
    try {
        foreach ($fileName in @('manifest.json', 'updates-main.ps1')) {
            Copy-Item -LiteralPath (Join-Path $Layout.VersionRoot $fileName) -Destination (Join-Path $stagingRoot $fileName) -Force
        }
        Invoke-InstallCommitHook -Step 'payload-staged'
        if (-not (Test-InstalledVersionRoot -VersionRoot $stagingRoot -ExpectedVersion $Layout.CurrentVersion)) {
            Fail-Install 'updates: staged payload failed validation.'
        }
        Invoke-InstallCommitHook -Step 'payload-validated'
        if (-not (Test-Path -LiteralPath $targetVersionRoot -PathType Container)) {
            Move-Item -LiteralPath $stagingRoot -Destination $targetVersionRoot
        } elseif (Test-InstalledVersionRoot -VersionRoot $targetVersionRoot -ExpectedVersion $Layout.CurrentVersion) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force
        } else {
            Remove-Item -LiteralPath $targetVersionRoot -Recurse -Force
            Move-Item -LiteralPath $stagingRoot -Destination $targetVersionRoot
        }

        foreach ($fileName in @('updates.cmd', 'updates.ps1')) {
            $source = Join-Path $Layout.LayoutRoot $fileName
            $temp = Join-Path $targetRootFull ('.{0}.{1}.tmp' -f $fileName, [guid]::NewGuid().ToString('N'))
            try {
                Copy-Item -LiteralPath $source -Destination $temp -Force
                Invoke-InstallCommitHook -Step ($fileName + '-temp')
                Move-Item -LiteralPath $temp -Destination (Join-Path $targetRootFull $fileName) -Force
            } finally {
                if (Test-Path -LiteralPath $temp) {
                    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                }
            }
            Invoke-InstallCommitHook -Step $fileName
        }
        $oldCurrent = if (Test-Path -LiteralPath (Join-Path $targetRootFull 'current.txt') -PathType Leaf) { Read-TrimmedTextFile (Join-Path $targetRootFull 'current.txt') } else { '' }
        $oldVersionRoot = if ($oldCurrent -and (Test-SemVerString $oldCurrent)) { Join-Path $versionsRoot $oldCurrent } else { '' }
        if (-not $oldVersionRoot -or -not (Test-InstalledVersionRoot -VersionRoot $oldVersionRoot -ExpectedVersion $oldCurrent)) { $oldCurrent = '' }
        $oldPrevious = if (Test-Path -LiteralPath (Join-Path $targetRootFull 'previous.txt') -PathType Leaf) { Read-TrimmedTextFile (Join-Path $targetRootFull 'previous.txt') } else { '' }
        $oldPreviousRoot = if ($oldPrevious -and (Test-SemVerString $oldPrevious)) { Join-Path $versionsRoot $oldPrevious } else { '' }
        if (-not $oldPreviousRoot -or -not (Test-InstalledVersionRoot -VersionRoot $oldPreviousRoot -ExpectedVersion $oldPrevious)) { $oldPrevious = '' }
        $rollbackVersion = if ($oldCurrent -and $oldCurrent -ne $Layout.CurrentVersion) { $oldCurrent } elseif ($oldPrevious -and $oldPrevious -ne $Layout.CurrentVersion) { $oldPrevious } else { '' }
        $receipt = Get-JsonFile -Path (Join-Path $Layout.LayoutRoot 'install-source.json')
        Write-AtomicText -Path (Join-Path $targetRootFull 'install-source.json') -Content (($receipt | ConvertTo-Json -Depth 10) + "`n") -Step 'receipt'
        Invoke-InstallCommitHook -Step 'receipt'
        Write-AtomicText -Path (Join-Path $targetRootFull 'previous.txt') -Content $(if ($rollbackVersion) { $rollbackVersion + "`n" } else { '' }) -Step 'previous'
        Invoke-InstallCommitHook -Step 'previous'
        Write-AtomicText -Path (Join-Path $targetRootFull 'current.txt') -Content ($Layout.CurrentVersion + "`n") -Step 'current'
        Invoke-InstallCommitHook -Step 'current'
    } finally {
        try {
            if (Test-Path -LiteralPath $stagingRoot) {
                $stagingItem = Get-Item -LiteralPath $stagingRoot -Force -ErrorAction Stop
                if (
                    (Test-PathWithin -ParentPath $versionsRoot -CandidatePath $stagingRoot) -and
                    [System.IO.Path]::GetFileName($stagingRoot) -match ('^\.install-{0}-[0-9a-f]{{32}}\.staging$' -f [regex]::Escape($Layout.CurrentVersion)) -and
                    ($stagingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0
                ) {
                    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction Stop
                }
            }
        } catch {
            # Preserve the original install failure; never broaden cleanup beyond our owned staging path.
        }
    }

    return $targetRootFull
}

if (-not $IsWindows) {
    Fail-Install 'updates: native Windows install requires Windows + PowerShell 7.'
}

if (-not (Test-SemVerString $Version)) {
    Fail-Install "updates: Version must be SemVer X.Y.Z; got '$Version'."
}

if ($SourceZip -and $SourceRoot) {
    Fail-Install 'updates: choose only one of -SourceZip or -SourceRoot.'
}
if ($SourceZipSha256 -and (-not $SourceZip)) {
    Fail-Install 'updates: -SourceZipSha256 requires -SourceZip.'
}

$resolvedInstallRoot = if ($InstallRoot) { $InstallRoot } else { Get-DefaultInstallRoot }
$tempRoot = New-TempDirectory
$layoutRoot = Join-Path $tempRoot 'layout'
$null = New-Item -ItemType Directory -Path $layoutRoot -Force

try {
    if ($SourceRoot) {
        New-LayoutFromSourceRoot -Root $SourceRoot -ExpectedVersion $Version -OutputRoot $layoutRoot
    } else {
        $zipPath = if ($SourceZip) { Get-CanonicalPath $SourceZip } else { Get-AuthenticatedRelease -RequestedVersion $Version -OutputRoot $tempRoot }
        if ($SourceZip) {
            if ($SourceZipSha256) {
                if ($SourceZipSha256 -notmatch '^[0-9a-fA-F]{64}$' -or (Get-Sha256Hex $zipPath) -ne $SourceZipSha256.ToLowerInvariant()) {
                    Fail-Install 'updates: -SourceZipSha256 does not match the local ZIP.'
                }
            } else {
                [Console]::Error.WriteLine('updates: warning: local -SourceZip is unauthenticated; pass -SourceZipSha256 to verify it.')
            }
        }
        Expand-SourceZip -ZipPath $zipPath -OutputRoot $layoutRoot
    }

    $layout = Get-ValidatedLayout -LayoutRoot $layoutRoot -ExpectedVersion $Version
    $installedRoot = Copy-LayoutToInstallRoot -Layout $layout -TargetRoot $resolvedInstallRoot

    [Console]::Out.WriteLine("updates: installed v$($layout.CurrentVersion) to $installedRoot")
    [Console]::Out.WriteLine("updates: run $installedRoot\updates.cmd")
} finally {
    Remove-TempDirectory -Path $tempRoot
}
