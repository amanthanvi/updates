#requires -Version 7.0
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Version = '2.0.1',
    [string]$InstallRoot,
    [string]$SourceZip,
    [string]$SourceRoot,
    [string]$ReleaseBaseUri = 'https://github.com/amanthanvi/updates/releases/download'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CanonicalRepo = 'amanthanvi/updates'
$script:ReleaseChannel = 'github-release'
$script:BootstrapMin = 1
$script:WindowsAssetName = 'updates-windows.zip'

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

function Get-DefaultInstallRoot {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Fail-Install 'updates: LOCALAPPDATA is required for the native Windows install root.'
    }

    return (Join-Path $env:LOCALAPPDATA 'Programs\updates')
}

function Get-WindowsPayloadVersion {
    param([string]$PayloadPath)

    $content = [System.IO.File]::ReadAllText($PayloadPath)
    $match = [regex]::Match($content, '(?m)^\$script:UpdatesVersion\s*=\s*''([^'']+)''')
    if (-not $match.Success) {
        Fail-Install "updates: failed to detect UpdatesVersion in '$PayloadPath'."
    }

    return $match.Groups[1].Value
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

function Download-ReleaseZip {
    param(
        [string]$RequestedVersion,
        [string]$OutputPath
    )

    $uri = ('{0}/v{1}/{2}' -f $ReleaseBaseUri.TrimEnd('/'), $RequestedVersion, $script:WindowsAssetName)
    [Console]::Error.WriteLine("updates: downloading $uri")
    Invoke-WebRequest -Uri $uri -OutFile $OutputPath -Headers @{ 'User-Agent' = 'updates-install' } -TimeoutSec 60
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
        Assert-FileExists -Path (Join-Path $layoutRootFull $fileName) -Message "updates: layout missing '$fileName'."
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
    Assert-FileExists -Path $manifestPath -Message "updates: missing payload manifest '$manifestPath'."
    Assert-FileExists -Path $payloadPath -Message "updates: missing payload script '$payloadPath'."

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

function Copy-LayoutToInstallRoot {
    param(
        [pscustomobject]$Layout,
        [string]$TargetRoot
    )

    $targetRootFull = Get-CanonicalPath $TargetRoot
    $targetVersionRoot = Join-Path $targetRootFull (Join-Path 'versions' $Layout.CurrentVersion)

    $null = New-Item -ItemType Directory -Path $targetRootFull -Force
    $null = New-Item -ItemType Directory -Path $targetVersionRoot -Force

    foreach ($fileName in @('updates.cmd', 'updates.ps1', 'current.txt', 'previous.txt', 'install-source.json')) {
        Copy-Item -LiteralPath (Join-Path $Layout.LayoutRoot $fileName) -Destination (Join-Path $targetRootFull $fileName) -Force
    }

    foreach ($fileName in @('manifest.json', 'updates-main.ps1')) {
        Copy-Item -LiteralPath (Join-Path $Layout.VersionRoot $fileName) -Destination (Join-Path $targetVersionRoot $fileName) -Force
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

$resolvedInstallRoot = if ($InstallRoot) { $InstallRoot } else { Get-DefaultInstallRoot }
$tempRoot = New-TempDirectory
$layoutRoot = Join-Path $tempRoot 'layout'
$null = New-Item -ItemType Directory -Path $layoutRoot -Force

try {
    if ($SourceRoot) {
        New-LayoutFromSourceRoot -Root $SourceRoot -ExpectedVersion $Version -OutputRoot $layoutRoot
    } else {
        $zipPath = if ($SourceZip) { Get-CanonicalPath $SourceZip } else { Join-Path $tempRoot $script:WindowsAssetName }
        if (-not $SourceZip) {
            Download-ReleaseZip -RequestedVersion $Version -OutputPath $zipPath
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
