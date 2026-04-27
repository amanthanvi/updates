Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$targets = @(
    'updates',
    '.github/workflows',
    'scripts',
    'tests'
)

$tracked = & git ls-files -- $targets
if ($LASTEXITCODE -ne 0) {
    throw 'git ls-files failed'
}

$paths = $tracked |
    Where-Object { $_ } |
    Where-Object {
        $_ -eq 'updates' -or
        $_.EndsWith('.sh') -or
        $_.EndsWith('.ps1') -or
        $_.EndsWith('.cmd') -or
        $_.EndsWith('.yml') -or
        $_.EndsWith('.yaml')
    } |
    Sort-Object -Unique

$crlf = New-Object System.Collections.Generic.List[string]

foreach ($path in $paths) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repoRoot $path))
    for ($i = 0; $i -lt ($bytes.Length - 1); $i++) {
        if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10) {
            $crlf.Add($path)
            break
        }
    }
}

if ($crlf.Count -gt 0) {
    Write-Error ("LF guard failed; CRLF bytes detected in:`n - " + ($crlf -join "`n - "))
    exit 1
}

Write-Host ("LF guard passed for {0} tracked files." -f $paths.Count)
