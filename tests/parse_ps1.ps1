# Parse host/gpupv-host.ps1 with the PowerShell parser (syntax only, no execution).
# Used by `make check`; skipped when pwsh is not installed.
param([string]$Path = 'host/gpupv-host.ps1')
$errors = $null
$tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path), [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -eq 0) {
    Write-Output "ok  $Path"
    exit 0
}
$errors | ForEach-Object { Write-Output ("ERR line " + $_.Extent.StartLineNumber + ": " + $_.Message) }
exit 1
