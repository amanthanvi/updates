param(
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot,
    [Parameter(Mandatory = $true)]
    [ValidateSet('CtrlC', 'CtrlBreak')]
    [string]$SignalType,
    [Parameter(Mandatory = $true)]
    [string]$ReadyPath,
    [Parameter(Mandatory = $true)]
    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'windows_test_lib.ps1')

$process = $null
$nativeProcess = $null
$result = [ordered]@{
    signal_type = $SignalType
    status = 'error'
    child_exit = $null
    message = ''
}

try {
    if ($SignalType -eq 'CtrlBreak') {
        $nativeProcess = Start-BootstrapProcessInNewGroup -InstallRoot $InstallRoot -ArgumentList @('--no-self-update', '--no-color', '--no-emoji')
    } else {
        $process = Start-BootstrapProcess -InstallRoot $InstallRoot -ArgumentList @('--no-self-update', '--no-color', '--no-emoji')
    }

    Wait-ForCondition -Predicate {
        if ($SignalType -eq 'CtrlBreak') {
            if (Test-NativeProcessExited -Process $nativeProcess) {
                throw ("bootstrap exited before {0} readiness with code {1}" -f $SignalType, (Get-NativeProcessExitCode -Process $nativeProcess))
            }
        } elseif ($process.HasExited) {
            throw ("bootstrap exited before {0} readiness with code {1}" -f $SignalType, $process.ExitCode)
        }
        Test-Path -LiteralPath $ReadyPath
    } -FailureMessage ("bootstrap never became ready for {0}" -f $SignalType)

    if ($SignalType -eq 'CtrlBreak') {
        Send-CtrlBreak -ProcessGroupId $nativeProcess.ProcessId
        Wait-ForNativeProcessExit -Process $nativeProcess -FailureMessage ("bootstrap did not exit after {0}" -f $SignalType)
        $result.child_exit = Get-NativeProcessExitCode -Process $nativeProcess
    } else {
        try {
            Set-IgnoreCtrlC $true
            Send-CtrlC
        }
        finally {
            Set-IgnoreCtrlC $false
        }

        Wait-ForProcessExit -Process $process -FailureMessage ("bootstrap did not exit after {0}" -f $SignalType)
        $result.child_exit = $process.ExitCode
    }
    if ($result.child_exit -ne 130) {
        throw ("bootstrap exit code after {0} was {1}, expected 130" -f $SignalType, $result.child_exit)
    }

    $result.status = 'ok'
}
catch {
    if ($SignalType -eq 'CtrlBreak' -and $nativeProcess) {
        try {
            if (Test-NativeProcessExited -Process $nativeProcess) {
                $result.child_exit = Get-NativeProcessExitCode -Process $nativeProcess
            }
        } catch {
        }
    } elseif ($process -and $process.HasExited) {
        $result.child_exit = $process.ExitCode
    }
    $result.message = $_.Exception.Message
}
finally {
    if ($nativeProcess) {
        try {
            Stop-NativeProcess -Process $nativeProcess
        } catch {
        }
    } elseif ($process -and -not $process.HasExited) {
        try {
            $process.Kill($true)
        } catch {
        }
    }

    Write-JsonFile -Path $ResultPath -Data $result
}

if ($result.status -eq 'ok') {
    exit 0
}

[Console]::Error.WriteLine($result.message)
exit 1
