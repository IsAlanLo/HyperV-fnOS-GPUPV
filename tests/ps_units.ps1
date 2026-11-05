# Unit tests for the pure helper functions, without running the script's actions.
#
# The helpers are extracted from gpupv-windows.ps1 by the PowerShell parser and
# defined in this session, so a unit test can never drift from the shipped code
# (a copy-pasted reimplementation is how the toolchain probe once disagreed with
# the real check).
#
#   pwsh -NoProfile -File tests/ps_units.ps1
param([string]$Script = 'gpupv-windows.ps1')

$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Ok($m)  { Write-Host "  PASS $m" -ForegroundColor Green; $script:pass++ }
function Bad($m, $d) { Write-Host "  FAIL $m" -ForegroundColor Red; if ($d) { Write-Host "       $d" }; $script:fail++ }
function Check($cond, $m, $d) { if ($cond) { Ok $m } else { Bad $m $d } }

$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Script), [ref]$null, [ref]$null)
$src = Get-Content -Raw $Script
function Get-Fn($name) {
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn -or $fn.Count -eq 0) { throw "function $name not found in $Script" }
    return $fn[0]
}

foreach ($name in @('ConvertTo-MmioBytes', 'Format-Bytes')) {
    . ([scriptblock]::Create((Get-Fn $name).Extent.Text))
}

Write-Host "== ConvertTo-MmioBytes"
# Set-VM -HighMemoryMappedIoSpace takes UInt64; the string form must be parsed here
# or parameter binding fails with "Input string was not in a correct format" - which
# reads like the host refusing the value (it happened, on 256GB/128GB/64GB/34.5GB).
$cases = @(
    @{ In = '256GB';    Want = 274877906944 },
    @{ In = '128GB';    Want = 137438953472 },
    @{ In = '64GB';     Want = 68719476736 },
    @{ In = '34.5GB';   Want = 37044092928 },
    @{ In = '3584MB';   Want = 3758096384 },
    @{ In = '1GB';      Want = 1073741824 },
    @{ In = '512KB';    Want = 524288 },
    @{ In = '1024';     Want = 1024 }
)
foreach ($c in $cases) {
    $got = ConvertTo-MmioBytes -Text $c.In
    Check ($got -eq $c.Want) "parse $($c.In) -> $($c.Want)" "got $got"
}
foreach ($bad in @('', 'abc', '256 GB x', 'GB')) {
    $got = ConvertTo-MmioBytes -Text $bad
    Check ($null -eq $got) "reject '$bad'" "got $got"
}

Write-Host "== the exact values passed to Set-VM bind as UInt64"
foreach ($s in @('256GB', '3584MB', '34.5GB')) {
    $b = ConvertTo-MmioBytes -Text $s
    Check ($b -is [uint64]) "$s converts to [uint64]" "type is $($b.GetType().Name)"
}

Write-Host "== Format-Bytes"
Check ((Format-Bytes 274877906944) -eq '256.0GB') 'format 256GB' (Format-Bytes 274877906944)
Check ((Format-Bytes 3758096384) -eq '3.5GB') 'format 3.5GB' (Format-Bytes 3758096384)
Check ((Format-Bytes 536870912) -eq '512MB') 'format 512MB' (Format-Bytes 536870912)

Write-Host "== the MMIO strings in the script itself are all parseable"
# Only the candidate list matters: -HighMmio/-LowMmio are caller supplied defaults
# and are parsed at use time anyway.
foreach ($m in [regex]::Matches($src, "@\(\`$HighMmio,\s*([^)]*)\)")) {
    foreach ($lit in [regex]::Matches($m.Groups[1].Value, "'([0-9.]+(?:TB|GB|MB|KB|B))'")) {
        $v = $lit.Groups[1].Value
        Check ((ConvertTo-MmioBytes -Text $v) -ne $null) "candidate literal $v parses" 'unparseable candidate'
    }
}

Write-Host "== every Set-VM MMIO call passes bytes, never a size string"
# This is the bug that made the partition repair look like "host refused 256GB":
# Set-VM -HighMemoryMappedIoSpace is UInt64 and '256GB' fails parameter binding.
$vmCalls = [regex]::Matches($src, '-(?:High|Low)MemoryMappedIoSpace\s+([^\r?\n;]+?)(?:\s+-|\s*$)')
Check ($vmCalls.Count -ge 2) "found the Set-VM MMIO call sites ($($vmCalls.Count))" ''
foreach ($c in $vmCalls) {
    $arg = $c.Groups[1].Value.Trim()
    $isBytes = ($arg -match '^\$(lowBytes|bytes)$') -or ($arg -match '^\d+$')
    Check $isBytes "MMIO argument '$arg' is a byte value" '- pass a parsed [uint64], not a string like 256GB'
}

Write-Host "== Get-VMName / Get-GuestAddress refuse rather than guess"
$vmFn = (Get-Fn 'Get-VMName').Extent.Text
Check ($vmFn -match 'several VMs exist') 'Get-VMName lists the VMs instead of picking one' ''
$gaFn = (Get-Fn 'Get-GuestAddress').Extent.Text
Check ($gaFn -match 'reports several addresses') 'Get-GuestAddress asks when the address is ambiguous' ''
Check ($gaFn -match '169\\.254\\.') 'Get-GuestAddress ignores link-local addresses' ''

Write-Host ''
Write-Host "==== ps units: $pass passed, $fail failed ===="
if ($fail -gt 0) { exit 1 }
