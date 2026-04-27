#requires -Version 7.0
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BootstrapSchemaVersion = 1
$script:CanonicalRepo = 'amanthanvi/updates'
$script:SupportedEntryScript = 'updates-main.ps1'
$script:CancelExitCode = 130
$script:CloseExitCode = 143

function Write-BootstrapError {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
}

function Write-BootstrapWarning {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
}

function Fail-Bootstrap {
    param(
        [int]$Code,
        [string]$Message
    )

    if ($Message) {
        Write-BootstrapError $Message
    }

    exit $Code
}

function Read-TrimmedTextFile {
    param([string]$Path)

    $raw = [System.IO.File]::ReadAllText($Path)
    return $raw.Trim()
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

function Resolve-SafeChildPath {
    param(
        [string]$ParentPath,
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "entry_script is empty."
    }

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "entry_script must be a relative path."
    }

    $candidatePath = Get-CanonicalPath (Join-Path $ParentPath $RelativePath)
    if (-not (Test-PathWithin -ParentPath $ParentPath -CandidatePath $candidatePath)) {
        throw "entry_script escapes version directory."
    }

    return $candidatePath
}

function ConvertTo-BootstrapMin {
    param($Value)

    if ($Value -is [int] -or $Value -is [long]) {
        if ($Value -lt 0) {
            throw "bootstrap_min must be non-negative."
        }

        return [int]$Value
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or $text -notmatch '^\d+$') {
        throw "bootstrap_min must be an integer."
    }

    return [int]$text
}

function Get-ValidatedManifest {
    param(
        [string]$ManifestPath,
        [string]$ExpectedVersion,
        [string]$VersionRoot
    )

    $manifestRaw = [System.IO.File]::ReadAllText($ManifestPath)
    try {
        $manifest = $manifestRaw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "manifest.json is not valid JSON."
    }

    foreach ($key in @('version', 'bootstrap_min', 'entry_script')) {
        if (-not $manifest.ContainsKey($key)) {
            throw "manifest.json missing '$key'."
        }
    }

    $manifestVersion = [string]$manifest['version']
    if (-not (Test-SemVerString $manifestVersion)) {
        throw "manifest.json version '$manifestVersion' is not a valid semantic version."
    }

    if ($manifestVersion -ne $ExpectedVersion) {
        throw "manifest.json version '$manifestVersion' does not match pointer version '$ExpectedVersion'."
    }

    $bootstrapMin = ConvertTo-BootstrapMin $manifest['bootstrap_min']
    if ($bootstrapMin -gt $script:BootstrapSchemaVersion) {
        throw "manifest.json bootstrap_min '$bootstrapMin' requires a newer bootstrap."
    }

    $entryScript = [string]$manifest['entry_script']
    if ($entryScript -ne $script:SupportedEntryScript) {
        throw "entry_script must be '$($script:SupportedEntryScript)'."
    }

    $entryPath = Resolve-SafeChildPath -ParentPath $VersionRoot -RelativePath $entryScript
    if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) {
        throw "entry_script '$entryScript' does not exist."
    }

    if ([System.IO.Path]::GetExtension($entryPath) -ne '.ps1') {
        throw "entry_script '$entryScript' must target a .ps1 file."
    }

    return [pscustomobject]@{
        Version      = $manifestVersion
        BootstrapMin = $bootstrapMin
        EntryScript  = $entryScript
        EntryPath    = $entryPath
        ManifestPath = $ManifestPath
    }
}

function Resolve-PayloadCandidate {
    param(
        [string]$InstallRoot,
        [string]$PointerName
    )

    $pointerPath = Join-Path $InstallRoot $PointerName
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) {
        return [pscustomobject]@{
            PointerName = $PointerName
            PointerPath = $pointerPath
            IsValid     = $false
            Reason      = 'missing pointer file'
        }
    }

    try {
        $version = Read-TrimmedTextFile $pointerPath
        if ([string]::IsNullOrWhiteSpace($version)) {
            throw "pointer file is empty."
        }

        if (-not (Test-SemVerString $version)) {
            throw "pointer version '$version' is not a valid semantic version."
        }

        $versionsRoot = Join-Path $InstallRoot 'versions'
        $versionRoot = Get-CanonicalPath (Join-Path $versionsRoot $version)
        if (-not (Test-PathWithin -ParentPath $versionsRoot -CandidatePath $versionRoot)) {
            throw "version path escapes versions directory."
        }

        if (-not (Test-Path -LiteralPath $versionRoot -PathType Container)) {
            throw "version directory '$versionRoot' does not exist."
        }

        $manifestPath = Join-Path $versionRoot 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "manifest.json missing from '$versionRoot'."
        }

        $manifest = Get-ValidatedManifest -ManifestPath $manifestPath -ExpectedVersion $version -VersionRoot $versionRoot

        return [pscustomobject]@{
            PointerName = $PointerName
            PointerPath = $pointerPath
            IsValid     = $true
            Version     = $manifest.Version
            VersionRoot = $versionRoot
            EntryPath   = $manifest.EntryPath
            EntryScript = $manifest.EntryScript
            ManifestPath = $manifest.ManifestPath
        }
    }
    catch {
        return [pscustomobject]@{
            PointerName = $PointerName
            PointerPath = $pointerPath
            IsValid     = $false
            Reason      = $_.Exception.Message
        }
    }
}

function Register-ConsoleExitHandler {
    if (-not $IsWindows) {
        return $false
    }

    if (-not ('UpdatesBootstrapConsoleSignals' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class UpdatesBootstrapConsoleSignals
{
    private delegate bool HandlerRoutine(int ctrlType);
    private static HandlerRoutine s_handler;
    private static int s_cancelExitCode;
    private static int s_closeExitCode;

    [DllImport("Kernel32", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

    public static bool Register(int cancelExitCode, int closeExitCode)
    {
        s_cancelExitCode = cancelExitCode;
        s_closeExitCode = closeExitCode;

        if (s_handler == null)
        {
            s_handler = HandleSignal;
        }

        return SetConsoleCtrlHandler(s_handler, true);
    }

    private static bool HandleSignal(int ctrlType)
    {
        if (ctrlType == 0 || ctrlType == 1)
        {
            try
            {
                Console.Error.WriteLine("updates: interrupted.");
            }
            catch
            {
            }

            Environment.Exit(s_cancelExitCode);
            return true;
        }

        if (ctrlType == 2)
        {
            try
            {
                Console.Error.WriteLine("updates: terminating.");
            }
            catch
            {
            }

            Environment.Exit(s_closeExitCode);
            return true;
        }

        return false;
    }
}
'@
    }

    return [UpdatesBootstrapConsoleSignals]::Register($script:CancelExitCode, $script:CloseExitCode)
}

function Get-SelectedPayload {
    param([string]$InstallRoot)

    $currentCandidate = Resolve-PayloadCandidate -InstallRoot $InstallRoot -PointerName 'current.txt'
    if ($currentCandidate.IsValid) {
        return $currentCandidate
    }

    $previousCandidate = Resolve-PayloadCandidate -InstallRoot $InstallRoot -PointerName 'previous.txt'
    if ($previousCandidate.IsValid) {
        Write-BootstrapWarning ("updates: current.txt invalid ({0}); falling back to previous.txt ({1})." -f $currentCandidate.Reason, $previousCandidate.Version)
        return $previousCandidate
    }

    $messages = @(
        "updates: no runnable Windows payload found beside '$InstallRoot'.",
        ("updates: current.txt -> {0}" -f $currentCandidate.Reason),
        ("updates: previous.txt -> {0}" -f $previousCandidate.Reason)
    )

    Fail-Bootstrap -Code 2 -Message ($messages -join [Environment]::NewLine)
}

if (-not $IsWindows) {
    Fail-Bootstrap -Code 2 -Message 'updates: native Windows bootstrap requires Windows + PowerShell 7.'
}

if (-not [string]::IsNullOrWhiteSpace($env:UPDATES_SELF_UPDATE_REPO)) {
    Fail-Bootstrap -Code 2 -Message ("updates: UPDATES_SELF_UPDATE_REPO is no longer supported on Windows; official self-update repo is '{0}'." -f $script:CanonicalRepo)
}

$installRoot = Split-Path -Parent $PSCommandPath
$selectedPayload = Get-SelectedPayload -InstallRoot $installRoot

try {
    if (-not (Register-ConsoleExitHandler)) {
        Write-BootstrapWarning 'updates: console control handler unavailable; Windows signal exit codes may not be preserved.'
    }
}
catch {
    Write-BootstrapWarning ("updates: failed to register console control handler; Windows signal exit codes may not be preserved ({0})." -f $_.Exception.Message)
}

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

try {
    & $selectedPayload.EntryPath -CliArgs $RemainingArgs
    $payloadExitCode = $LASTEXITCODE

    if ($null -ne $payloadExitCode) {
        exit ([int]$payloadExitCode)
    }

    if ($?) {
        exit 0
    }

    exit 1
}
catch {
    Fail-Bootstrap -Code 1 -Message ("updates: payload launch failed from '{0}': {1}" -f $selectedPayload.EntryPath, $_.Exception.Message)
}
