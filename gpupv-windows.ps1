<#
.SYNOPSIS
    Hyper-V GPU-PV for a Linux guest - the Windows host side, end to end.

.DESCRIPTION
    One script for the host, two ways to reach the guest:

      * over SSH (default when OpenSSH is available): push the guest script and the
        driver's DriverStore folder, run the install remotely, verify remotely.
      * over HTTP PUT (no SSH client / no sshd in the guest): the guest runs
        `gpupv-fnos.sh receive`, this script pushes the same folder to it.

    Everything host-side is verified against Windows 10 Pro for Workstations 22H2
    (19045) + RTX 3060 Ti, but the pitfalls it encodes are general:

      * Get-VMGpuPartitionAdapter printing empty Min/Max/Optimal fields is NORMAL;
        assignment goes through Msvm_GpuPartitionSettingData + AddResourceSettings,
        which never fills them. Do not "fix" it.
      * GuestControlledCacheTypes=$false, or a small HighMemoryMappedIoSpace, lets
        the guest open the channel but not map the GPU's BARs.
      * The WinNT->ServerNT "black magic" some tools ship gates DDA (PCIe
        passthrough) only; it cannot change GPU-PV.
      * MMIO / partition changes need the VM stopped, which takes the guest - and
        anything running inside it - down with it.
      * The guest needs the COMPLETE nv_dispi folder (~150 files incl. nvinfo.pb),
        not the handful of .so files most deploy scripts copy. A trimmed copy gives
        a working nvidia-smi and a segfaulting cuInit.

.PARAMETER Action
    Check            read-only host report (VM settings, partition, GPU pool, driver, DriverStore)
    ShowDriverStore  find the complete nv_dispi folder, count files, print a one-liner
    Deploy           SSH: upload guest script + DriverStore, run install, verify
    Push             HTTP PUT: push the DriverStore folder to a running guest receiver
    Remote           SSH: run one gpupv-fnos.sh command in the guest (default: verify)
    FixMmio          stop -> GuestControlledCacheTypes + MMIO gaps (does not start the VM)
    AddPartition     stop -> remove + re-add the GPU partition (does not start the VM)
    ShowPowerShell   print the equivalent one-liner for an action, for pasting
    Auto             Deploy with the host side handled too: detect the VM, discover the
                     guest address, repair the GPU partition if it is missing, then install
    Version          print the script version (a stale copy is the usual cause of
                     "parameter cannot be found")

.EXAMPLE
    .\gpupv-windows.ps1 -Action Check -VMName fnos

.EXAMPLE
    .\gpupv-windows.ps1 -Action ShowDriverStore

.EXAMPLE
    # full install over SSH (will prompt for the guest sudo password)
    .\gpupv-windows.ps1 -Action Deploy -VMName fnos -GuestHost 192.168.x.x -GuestUser youruser

.EXAMPLE
    # no sshd in the guest: start `gpupv-fnos.sh receive` there, then
    .\gpupv-windows.ps1 -Action Push -GuestUrl http://192.168.x.x:8899/
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Check', 'ShowDriverStore', 'Deploy', 'Push', 'Remote',
                 'FixMmio', 'AddPartition', 'ShowPowerShell', 'Version')]
    [string]$Action = 'Check',

    # which action's one-liner to print for -Action ShowPowerShell
    [ValidateSet('Check', 'ShowDriverStore', 'Push', 'FixMmio', 'AddPartition', 'Deploy')]
    [string]$For = 'Check',

    # Empty = auto-detect: if the host has exactly one VM, that one is used; if it
    # has several, the script lists them instead of guessing.
    [string]$VMName = '',

    # guest, for SSH actions
    [string]$GuestHost = '',
    [string]$GuestUser = 'root',
    [int]$SshPort = 22,
    [string]$SshKey = '',
    [string]$GuestScript = 'gpupv-fnos.sh',
    [string]$RemoteDir = '/tmp/gpupv',

    # guest, for HTTP PUT actions
    [string]$GuestUrl = '',
    [int]$Port = 8899,

    # one gpupv-fnos.sh command line, for -Action Remote
    [string]$GuestCommand = 'verify',

    # -Action Remote: run it through sudo (prompts once, visibly, on this console)
    [switch]$AsRoot,

    # Ask for the guest sudo password once (hidden) and feed it to 'sudo -S'
    # instead of letting sudo prompt on the remote pty. Use this when the console
    # cannot show a remote prompt, or when nobody is watching the window.
    [switch]$SudoPrompt,

    # MMIO candidates
    [string]$HighMmio = '256GB',
    [string]$LowMmio = '3584MB',

    # Where the guest's /usr/lib/wsl/lib comes from. Default: C:\Windows\System32\lxss\lib,
    # which IS that directory's source - it ships with Windows and the NVIDIA driver,
    # no third-party package involved. Override only for an unusual layout.
    [string]$LoadersDir = '',

    # Deploy: assign a GPU partition when the VM has none (stops and cold-starts
    # the VM, then waits for ssh before continuing)
    [switch]$FixPartition,

    # skip the loader copy when the guest already has /usr/lib/wsl/lib populated
    [switch]$SkipLoaders,

    # skip re-copying the DriverStore when the guest already has it complete
    [switch]$SkipDriverStore,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:GPUPV_VERSION = '1.1.2'
# The guest's DriverStore root, used to find an already-deployed payload when the
# copy step is skipped. Mirrors WSL_DRIVERS in gpupv-fnos.sh.
$WSL_DRIVERS_GUEST = '/usr/lib/wsl/drivers'

function Write-Head($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Write-Item($k, $v) { Write-Host ("  {0,-26} {1}" -f $k, $v) }
function Write-Warn2($m) { Write-Host "  WARN $m" -ForegroundColor Yellow }
function Write-Bad($m)   { Write-Host "  FAIL $m" -ForegroundColor Red }
function Write-Good($m)  { Write-Host "  OK   $m" -ForegroundColor Green }

function Test-Admin {
    <#  $true when this session is elevated. On a non-Windows PowerShell (the test
        harness runs pwsh on Linux) the check cannot work, so it reports $false
        rather than throwing. #>
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-Admin {
    if (Test-Admin) { return }
    throw 'Run this in an Administrator PowerShell.'
}

function Confirm-StopVm($why) {
    Write-Warn2 $why
    Write-Warn2 'the guest - and anything running inside it - goes down. A cold start is then required.'
    if ($Force) { return }
    $a = Read-Host "Type YES to continue"
    if ($a -ne 'YES') { Write-Host 'aborted'; exit 1 }
}

# --- the NVIDIA DriverStore folder --------------------------------------
# The <hash> segment changes with every driver update, so it is never hard-coded:
# resolve it from the installed display driver, fall back to the newest nv_dispi
# folder, and refuse to proceed when the folder itself is incomplete.
function Get-NvDriverStore {
    $vc = Get-CimInstance Win32_VideoController |
          Where-Object { $_.AdapterCompatibility -match 'NVIDIA' } |
          Select-Object -First 1
    if (-not $vc) { throw 'no NVIDIA adapter reported by Win32_VideoController' }

    $dir = $null
    $first = ($vc.InstalledDisplayDrivers -split ',')[0]
    if ($first) {
        $parent = Split-Path -Parent $first
        if ($parent -match 'DriverStore' -and (Test-Path $parent)) { $dir = $parent }
    }
    if (-not $dir) {
        $cand = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory `
                    -Filter 'nv_dispi.inf_amd64_*' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($cand) { $dir = $cand.FullName }
    }
    if (-not $dir) { throw 'no nv_dispi.inf_amd64_* folder under DriverStore\FileRepository' }

    $files = Get-ChildItem $dir -File
    $nvinfo = Get-Item (Join-Path $dir 'nvinfo.pb') -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Path     = $dir
        Files    = $files.Count
        SizeMB   = [math]::Round((($files | Measure-Object Length -Sum).Sum / 1MB), 0)
        NvinfoPb = $nvinfo
        Complete = ($files.Count -ge 150 -and $null -ne $nvinfo)
    }
}

# --- the WSL userland libraries ----------------------------------------
# /usr/lib/wsl/lib in the guest mirrors this directory, which Windows itself
# provides: lxss\lib ships with the OS + the installed NVIDIA driver. Nothing here
# requires any third-party package.
function Get-LoadersDir {
    if ($LoadersDir) {
        if (-not (Test-Path $LoadersDir)) { throw "-LoadersDir not found: $LoadersDir" }
        return (Resolve-Path $LoadersDir).Path
    }
    $cand = Join-Path $env:SystemRoot 'System32\lxss\lib'
    if (Test-Path $cand) { return $cand }
    throw "neither $cand nor -LoadersDir exists: this host never installed the WSL userland libraries"
}

function Get-LoaderSet($dir) {
    $files = Get-ChildItem $dir -File
    # the few that must be there for cuInit to be reachable at all
    $need = @('libcuda.so.1', 'libnvidia-ml.so.1', 'libdxcore.so', 'libd3d12core.so', 'nvidia-smi')
    $have = @($need | Where-Object { Test-Path (Join-Path $dir $_) })
    [pscustomobject]@{
        Path     = $dir
        Files    = $files.Count
        SizeMB   = [math]::Round((($files | Measure-Object Length -Sum).Sum / 1MB), 0)
        Present  = $have
        Missing  = @($need | Where-Object { $have -notcontains $_ })
    }
}

function ConvertTo-MmioBytes {
    <#  '256GB' / '3584MB' / '274877906944' -> [uint64] bytes, or $null when the
        text is not a size.

        Set-VM -HighMemoryMappedIoSpace takes UInt64; passing the string '256GB'
        fails parameter binding with "Input string was not in a correct format",
        which reads like the host refusing the value. Parse it here. #>
    param([string]$Text = '')
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t -match '^\d+$') { return [uint64]$t }
    if ($t -match '^(?<n>\d+(?:\.\d+)?)\s*(?<u>TB|GB|MB|KB|B)$') {
        $n = [double]$Matches['n']
        $mult = switch ($Matches['u'].ToUpper()) {
            'TB' { 1099511627776 }
            'GB' { 1073741824 }
            'MB' { 1048576 }
            'KB' { 1024 }
            'B'  { 1 }
        }
        return [uint64][math]::Round($n * $mult)
    }
    return $null
}

function Format-Bytes {
    param([uint64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1}GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0}MB' -f ($Bytes / 1MB)) }
    return "$Bytes B"
}

# --- GPU partition + MMIO ----------------------------------------------
# One repair sequence, used by -Action AddPartition and by Deploy's preflight, so
# the two can never drift apart (a second copy of this is how the toolchain probe
# ended up disagreeing with `deps`).
function Repair-GpuPartition {
    <#  Assign a GPU partition and give the VM enough MMIO to map its BARs.
        The VM must be stopped; it is left RUNNING afterwards unless -NoStart. #>
    param([string]$VMName, [switch]$NoStart)

    $vm = Get-VM -Name $VMName
    if ($vm.State -ne 'Off') {
        Stop-VM -Name $VMName -Force
    }

    # MMIO: the guest can open the channel without it and then fail to map the GPU.
    # Values are parsed to bytes first - see ConvertTo-MmioBytes.
    Set-VM -Name $VMName -GuestControlledCacheTypes $true

    $lowBytes = ConvertTo-MmioBytes -Text $LowMmio
    if ($lowBytes) {
        try {
            Set-VM -Name $VMName -LowMemoryMappedIoSpace $lowBytes -ErrorAction Stop
            Write-Good "LowMemoryMappedIoSpace = $(Format-Bytes $lowBytes)"
        } catch {
            Write-Warn2 "host refused LowMemoryMappedIoSpace=$LowMmio : $(($_.Exception.Message -split "`n")[0])"
        }
    } else {
        Write-Warn2 "cannot parse -LowMmio '$LowMmio' as a size (use e.g. 3584MB)"
    }

    # Descend through candidates: a host rejects a gap it cannot back, and the
    # largest one that is accepted is the best available.
    $applied = $null
    foreach ($cand in @($HighMmio, '256GB', '128GB', '64GB', '34.5GB')) {
        $bytes = ConvertTo-MmioBytes -Text $cand
        if (-not $bytes) { continue }
        try {
            Set-VM -Name $VMName -HighMemoryMappedIoSpace $bytes -ErrorAction Stop
            $applied = $bytes; break
        } catch {
            Write-Warn2 "host refused HighMemoryMappedIoSpace=$cand : $(($_.Exception.Message -split "`n")[0])"
        }
    }
    if (-not $applied) { Write-Warn2 'no HighMemoryMappedIoSpace candidate accepted (host ceiling below 34.5GB)' }

    # The partition itself.
    Remove-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue
    try {
        $path = Get-VMHostPartitionableGpu -ErrorAction Stop |
                Select-Object -First 1 -ExpandProperty Name
        if (-not $path) { throw 'empty partitionable GPU list' }
        Add-VMGpuPartitionAdapter -VMName $VMName -InstancePath $path
    } catch {
        # Windows 10 has no Get-VMHostPartitionableGpu: the shorthand works there.
        Add-VMGpuPartitionAdapter -VMName $VMName
    }

    $p = Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue
    $vm = Get-VM -Name $VMName
    # An empty InstancePath is normal for an assignment from the generic pool: the
    # record lives in Msvm_GpuPartitionSettingData, which this cmdlet never fills.
    if ($p) {
        $where = if ($p.InstancePath) { $p.InstancePath } else { 'generic pool (no explicit instance path - normal)' }
        Write-Item 'partition' $where
    } else {
        Write-Item 'partition' 'STILL EMPTY'
    }
    Write-Item 'cache types'  $vm.GuestControlledCacheTypes
    Write-Item 'low MMIO'     "$($vm.LowMemoryMappedIoSpace) ($(Format-Bytes $vm.LowMemoryMappedIoSpace))"
    Write-Item 'high MMIO'    "$($vm.HighMemoryMappedIoSpace) ($(Format-Bytes $vm.HighMemoryMappedIoSpace))"

    # Read the MMIO back: a guest that cannot map the GPU's BARs produces a
    # `modprobe` stuck in D, which is far harder to diagnose than this warning.
    if ($vm.HighMemoryMappedIoSpace -lt 8GB) {
        Write-Warn2 "HighMemoryMappedIoSpace is still only $(Format-Bytes $vm.HighMemoryMappedIoSpace) - the guest may not be able to map the GPU's BARs"
    }

    if (-not $NoStart) {
        Start-VM -Name $VMName
        Write-Good "VM started (cold start: the VPCI device is re-enumerated with real BARs)"
    }
    return [bool]$p
}

function Wait-GuestSsh {
    <#  Poll until the guest accepts ssh again (a cold start takes a while). #>
    param([int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-GuestSsh -Capture -Remote @('echo GPUPV_ALIVE')
        if ($r.Output -match 'GPUPV_ALIVE') { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Assert-DriverStore($ds) {
    if ($ds.Complete) { Write-Good "DriverStore complete: $($ds.Files) files, $($ds.SizeMB) MB"; return }
    Write-Bad "DriverStore INCOMPLETE on the host: $($ds.Files) files, nvinfo.pb $(if ($ds.NvinfoPb) { 'present' } else { 'MISSING' })"
    throw 'reinstall the NVIDIA driver on the host before copying anything to the guest'
}

# --- ssh plumbing -------------------------------------------------------
function Get-SshExe {
    $c = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $c) { $c = Get-Command ssh -ErrorAction SilentlyContinue }
    if ($c) { return $c.Source }
    $p = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    if (Test-Path $p) { return $p }
    throw 'ssh.exe not found (Settings > Apps > Optional features > OpenSSH Client, or use -Action Push)'
}

function Get-ScpExe {
    $c = Get-Command scp.exe -ErrorAction SilentlyContinue
    if (-not $c) { $c = Get-Command scp -ErrorAction SilentlyContinue }
    if ($c) { return $c.Source }
    $p = Join-Path $env:SystemRoot 'System32\OpenSSH\scp.exe'
    if (Test-Path $p) { return $p }
    throw 'scp.exe not found (use -Action Push instead)'
}

function Get-VMName {
    <#  Resolve -VMName. Empty means "the host's only VM"; several VMs is an error
        that lists them, because guessing which one to reconfigure is how the wrong
        VM gets stopped. #>
    param([string]$Requested = $VMName)
    if ($Requested) {
        if (-not (Get-VM -Name $Requested -ErrorAction SilentlyContinue)) {
            $all = @(Get-VM -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            $hint = if ($all.Count) { " (this host has: $($all -join ', '))" } else { '' }
            throw "no VM named '$Requested'$hint"
        }
        return $Requested
    }
    $vms = @(Get-VM -ErrorAction SilentlyContinue)
    if ($vms.Count -eq 0) {
        throw 'no Hyper-V VMs on this host (or Get-VM needs elevation): pass -VMName explicitly'
    }
    if ($vms.Count -eq 1) {
        Write-Host "  (no -VMName given; using the only VM: $($vms[0].Name))" -ForegroundColor DarkGray
        return $vms[0].Name
    }
    $list = ($vms | ForEach-Object { "    $($_.Name)  [$($_.State)]" }) -join "`n"
    throw "several VMs exist, so -VMName is required:`n$list"
}

function Get-GuestAddress {
    <#  Resolve the guest's IP. -GuestHost wins; otherwise ask Hyper-V for the
        addresses its integration services reported for that VM. That removes the
        most common first-run friction ("what is the VM's IP?") while still
        refusing to guess when there is nothing to go on. #>
    param([string]$Requested = $GuestHost, [string]$VM = $VMName)
    if ($Requested) { return $Requested }
    if (-not $VM) { throw '-GuestHost <ip> is required (or pass -VMName so it can be discovered)' }

    $ips = @()
    try {
        $ips = @(Get-VMNetworkAdapter -VMName $VM -ErrorAction Stop |
                 ForEach-Object { $_.IPAddresses } |
                 Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notmatch '^169\.254\.' -and $_ -ne '127.0.0.1' } |
                 Select-Object -Unique)
    } catch { }
    if ($ips.Count -eq 1) {
        Write-Host "  (no -GuestHost given; using the address Hyper-V reports for '$VM': $($ips[0]))" -ForegroundColor DarkGray
        return $ips[0]
    }
    if ($ips.Count -gt 1) {
        throw "VM '$VM' reports several addresses, pass -GuestHost:`n    $($ips -join "`n    ")"
    }
    throw "-GuestHost <ip> is required: Hyper-V reports no IPv4 address for '$VM' (integration services off, or the guest is not running)"
}

function Get-SshTarget {
    # Auto-discovered address is cached in the script scope so every later call
    # (scp, the pty run, the status reads) targets the same host.
    if (-not $script:ResolvedGuestHost) {
        $script:ResolvedGuestHost = Get-GuestAddress -Requested $GuestHost -VM $VMName
    }
    if (-not $script:ResolvedGuestHost) { throw '-GuestHost <guest ip or name> is required for SSH actions' }
    "$GuestUser@$script:ResolvedGuestHost"
}

function Invoke-GuestSsh {
    <#  -Tty streams to this console and lets sudo/scp ask for a password on it.
        -Capture collects the output and returns an exit code.

        They are MUTUALLY EXCLUSIVE, and not as a style preference: with -Capture
        ssh's stdout is a pipe, so the remote pty's output - including sudo's
        "password:" prompt - is buffered until ssh exits, and ssh waits for a
        password nobody can see. The run hangs with no output at all. Ask for one
        or the other; when a step needs both a prompt and its result, stream it
        here and read the result back with a second, non-tty call. #>
    param([string[]]$Remote, [switch]$Tty, [switch]$Capture, [int]$TimeoutSec = 0)
    if ($Tty -and $Capture) {
        throw 'Invoke-GuestSsh: -Tty and -Capture cannot be combined (the password prompt would be swallowed)'
    }
    $ssh = Get-SshExe
    # ServerAlive options only reap a DEAD connection; they say nothing about a
    # process that is merely slow, so a long step is bounded on the guest side.
    $argv = @('-o','BatchMode=no','-o','StrictHostKeyChecking=accept-new',
              '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=8',
              '-p',$SshPort)
    if ($SshKey) { $argv += @('-i',$SshKey) }
    if ($Tty)    { $argv += '-t' }
    $argv += Get-SshTarget
    $argv += ($Remote -join '; ')
    if ($Capture) {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out  = & $ssh @argv 2>&1 | ForEach-Object { "$_" }
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $old
        }
        return [pscustomobject]@{ Output = ($out -join "`n"); Code = $code }
    }
    & $ssh @argv
    if ($LASTEXITCODE -ne 0) { throw "ssh command failed (exit $LASTEXITCODE): $($Remote -join '; ')" }
}

function Invoke-GuestSshStream {
    <#  Run a guest command with a tty, SHOWING its output live and saving it to
        -LogPath at the same time. Returns the ssh exit code plus the captured
        text.

        This exists because -Tty and -Capture cannot be combined (see above): the
        long step needs the tty for sudo's prompt, but its result still has to be
        classified afterwards. Tee'ing to a file keeps the prompt visible on the
        console AND leaves the text readable, without waiting for the process to
        exit to see anything. #>
    param([string[]]$Remote, [string]$LogPath, [int]$TimeoutSec = 0)
    $ssh = Get-SshExe
    $argv = @('-o','BatchMode=no','-o','StrictHostKeyChecking=accept-new',
              '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=8',
              '-p',$SshPort)
    if ($SshKey) { $argv += @('-i',$SshKey) }
    $argv += '-t'
    $argv += Get-SshTarget
    $argv += ($Remote -join '; ')

    $lines = New-Object System.Collections.Generic.List[string]
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $ssh @argv 2>&1 | ForEach-Object {
            $s = "$_"
            $lines.Add($s) | Out-Null
            # Write-Host keeps the live stream (and the password prompt) on the
            # console; the copy above is what gets classified.
            Write-Host $s
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    $text = $lines -join "`n"
    if ($LogPath) {
        try { Set-Content -LiteralPath $LogPath -Value $text -Encoding UTF8 } catch { }
    }
    return [pscustomobject]@{ Output = $text; Code = $code }
}

function Invoke-GuestSshSudo {
    <#  Run a command as root WITHOUT relying on a remote tty prompt: ask for the
        sudo password here (Read-Host -AsSecureString, so it never echoes and
        never lands in the command line or history), then feed it to `sudo -S`
        over ssh's stdin.

        No -t is passed on purpose: with a pty allocated sudo reads the terminal
        instead of stdin, which is exactly the mode that hangs when the console
        cannot present the prompt. The password exists only in this process's
        memory and on the (already encrypted) ssh stream. #>
    param([string]$Remote, [string]$LogPath, [switch]$AssumeYes)
    $ssh = Get-SshExe
    $sec = Read-Host -AsSecureString "sudo password for $(Get-SshTarget)"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $argv = @('-o','BatchMode=no','-o','StrictHostKeyChecking=accept-new',
              '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=8',
              '-p',$SshPort)
    if ($SshKey) { $argv += @('-i',$SshKey) }
    $argv += Get-SshTarget
    # -p '' silences sudo's own prompt; -S makes it read stdin (the password line)
    $argv += "sudo -S -p '' $Remote"

    $lines = New-Object System.Collections.Generic.List[string]
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # The first line is the password; it is consumed by sudo's -S read and
        # never echoed back by the guest.
        "$plain" | & $ssh @argv 2>&1 | ForEach-Object {
            $s = "$_"
            if ($s -match [regex]::Escape($plain)) { $s = '***' }
            $lines.Add($s) | Out-Null
            Write-Host $s
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    $text = $lines -join "`n"
    if ($LogPath) { try { Set-Content -LiteralPath $LogPath -Value $text -Encoding UTF8 } catch { } }
    return [pscustomobject]@{ Output = $text; Code = $code }
}

function Invoke-GuestSshLive {
    <#  Run a guest command with a tty, showing its output live AND keeping a
        machine-readable copy.

        Two separate traps, both of which bit us:

        1. Piping ssh's output on the HOST (`& $ssh ... | ForEach-Object {}`)
           buffers by line, so a prompt written WITHOUT a trailing newline -
           `[sudo] password for test:` is exactly that - never appears until you
           type something and press Enter. So ssh must inherit the console.
        2. Redirecting the guest command (`cmd 2>&1 | tee log`) replaces the tty
           with a pipe, and then the prompt is buffered on the guest side instead.

        The way to have both is a pty on the guest that also records: `script -q`.
        It gives the command a tty (prompt flushed immediately, echo normal),
        relays everything to this console, and writes the transcript to a file the
        caller can read back for classification. #>
    param([string]$Remote, [string]$LogPath, [string]$RemoteLog = '/tmp/gpupv-run.log',
          [string]$RemoteRc = '/tmp/gpupv-run.rc')
    $ssh = Get-SshExe
    $argv = @('-o','BatchMode=no','-o','StrictHostKeyChecking=accept-new',
              '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=8',
              '-p',$SshPort)
    if ($SshKey) { $argv += @('-i',$SshKey) }
    $argv += '-t'
    $argv += Get-SshTarget

    # -e: return the child's exit status; -q: no header/footer in the transcript.
    # Fall back to plain execution when `script` is not installed.
    $inner = $Remote -replace '"', '\"'
    $argv += "rm -f $RemoteLog $RemoteRc; " +
             "if command -v script >/dev/null 2>&1; then script -q -e -c ""$inner"" $RemoteLog; " +
             "else $Remote ; fi; echo `$? > $RemoteRc"

    & $ssh @argv
    $sshCode = $LASTEXITCODE

    # Read the transcript and the recorded status back with a plain, non-tty call.
    $r = Invoke-GuestSsh -Capture -Remote @(
        "cat $RemoteLog 2>/dev/null",
        "cat $RemoteRc 2>/dev/null"
    )
    $text = $r.Output
    $rc = $null
    if ($text -match '(?m)^\s*(\d+)\s*$') { $rc = [int]$Matches[1] }
    if ($null -eq $rc) { $rc = $sshCode }
    if ($LogPath) { try { Set-Content -LiteralPath $LogPath -Value $text -Encoding UTF8 } catch { } }
    return [pscustomobject]@{
        Output  = $text
        Code    = $rc
        SshCode = $sshCode
        Log     = $RemoteLog
    }
}

function Send-GuestFile {
    <#  scp when available (standard, no quoting games), else pipe through ssh
        with cmd.exe stdin redirection. ProcessStartInfo.ArgumentList does NOT
        exist in Windows PowerShell 5.1 (.NET Framework), so that route is not
        used - it would throw on a stock Windows 10. #>
    param([string]$Local, [string]$RemotePath)
    if (-not (Test-Path $Local)) { throw "local file missing: $Local" }

    $scp = $null
    try { $scp = Get-ScpExe } catch { $scp = $null }
    if ($scp) {
        $argv = @('-o', 'StrictHostKeyChecking=accept-new', '-P', "$SshPort")
        if ($SshKey) { $argv += @('-i', $SshKey) }
        $argv += @($Local, "$(Get-SshTarget):$RemotePath")
        & $scp @argv
        if ($LASTEXITCODE -ne 0) { throw "scp of $Local failed (exit $LASTEXITCODE)" }
        return
    }

    $ssh = Get-SshExe
    $opts = @('-o', 'BatchMode=no', '-o', 'StrictHostKeyChecking=accept-new', '-p', "$SshPort")
    if ($SshKey) { $opts += @('-i', $SshKey) }
    $cmdLine = '"{0}" {1} {2} "cat > ''{3}''" < "{4}"' -f $ssh, ($opts -join ' '), (Get-SshTarget), $RemotePath, $Local
    & cmd.exe /c $cmdLine
    if ($LASTEXITCODE -ne 0) { throw "upload of $Local failed (exit $LASTEXITCODE)" }
}

# --- actions ------------------------------------------------------------
# 'Auto' is the one-command path: everything Deploy does, plus whatever host-side
# repair is needed first (partition, MMIO) and both discovery steps (which VM, which
# address). 'Version' exists because "parameter cannot be found" almost always means
# the copy on disk is older than the invocation.
if ($Action -eq 'Version') {
    Write-Output "gpupv-windows.ps1 $script:GPUPV_VERSION"
    exit 0
}

Write-Host "gpupv-windows.ps1 $script:GPUPV_VERSION" -ForegroundColor DarkGray

if ($Action -eq 'Auto') {
    Write-Head 'Auto: host-side check, repair if needed, then the guest install'
    # Auto == Deploy with the host side repaired when needed, so no flag memory is
    # required. -Force still wins if the caller wants to skip the repair.
    # It can stop/start the VM, so it needs elevation up front - say that here
    # instead of failing later inside Get-VM.
    if (-not (Test-Admin)) {
        throw '-Action Auto can stop/start the VM, so it needs an Administrator PowerShell. Use -Action Deploy if you only want the guest side.'
    }
    if (-not $Force) { $FixPartition = $true }
    $Action = 'Deploy'
}

switch ($Action) {

    'Check' {
        $VMName = Get-VMName
        Write-Head "VM: $VMName"
        $vm = Get-VM -Name $VMName
        Write-Item 'State'                   $vm.State
        Write-Item 'Generation'              $vm.Generation
        Write-Item 'GuestControlledCache'    $vm.GuestControlledCacheTypes
        Write-Item 'LowMemoryMappedIoSpace'  $vm.LowMemoryMappedIoSpace
        Write-Item 'HighMemoryMappedIoSpace' $vm.HighMemoryMappedIoSpace
        if (-not $vm.GuestControlledCacheTypes) { Write-Warn2 'GuestControlledCacheTypes=$false - the guest may map no GPU BARs' }

        Write-Head 'GPU partition'
        $p = Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue
        if (-not $p) {
            Write-Bad 'no GPU partition assigned (run -Action AddPartition)'
        } else {
            $p | Format-List VMName, InstancePath | Out-String | Write-Host
            if ($p.InstancePath -match 'VEN_10DE') { Write-Good 'partition points at the NVIDIA GPU' }
            else { Write-Warn2 "InstancePath does not name VEN_10DE: $($p.InstancePath)" }
            Write-Item 'note' 'empty Min/Max/Optimal fields are normal'
        }

        Write-Head 'Host GPU pool'
        try {
            Get-VMHostPartitionableGpu -ErrorAction Stop | ForEach-Object { Write-Item 'partitionable' $_.Name }
        } catch {
            $pool = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_PartitionableGpu -ErrorAction SilentlyContinue
            if ($pool) { $pool | ForEach-Object { Write-Item 'partitionable' $_.Name } }
            else { Write-Bad 'no partitionable GPU - the host driver/GPU cannot partition at all' }
        }

        Write-Head 'Host GPU driver'
        Get-CimInstance Win32_VideoController | Where-Object { $_.AdapterCompatibility -match 'NVIDIA' } |
            ForEach-Object {
                Write-Item 'name'          $_.Name
                Write-Item 'DriverVersion' $_.DriverVersion
                Write-Item 'DriverDate'    $_.DriverDate
            }
        $dxgk = Get-Item "$env:SystemRoot\System32\drivers\dxgkrnl.sys" -ErrorAction SilentlyContinue
        if ($dxgk) { Write-Item 'dxgkrnl.sys' $dxgk.VersionInfo.FileVersion }

        Write-Head 'GPU assignment policy'
        $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV' -ErrorAction SilentlyContinue
        if ($pol) {
            Write-Item 'RequireSecureDeviceAssignment'    $pol.RequireSecureDeviceAssignment
            Write-Item 'RequireSupportedDeviceAssignment' $pol.RequireSupportedDeviceAssignment
            if ($pol.RequireSupportedDeviceAssignment -ne 0) { Write-Warn2 'consumer GPUs may be refused (0 = allowed)' }
        } else { Write-Item 'policy key' 'absent (defaults apply)' }

        Write-Head 'Hypervisor scheduler'
        $hs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Kernel' -ErrorAction SilentlyContinue).HypervisorSchedulerType
        if ($null -eq $hs) { Write-Item 'HypervisorSchedulerType' 'absent (= classic)' }
        else { Write-Item 'HypervisorSchedulerType' "$hs $(if ($hs -eq 1) { '(core: costs guest CPU throughput; the dxg path is latency-sensitive)' } else { '' })" }

        Write-Head 'DriverStore'
        try {
            $ds = Get-NvDriverStore
            Write-Item 'path'      $ds.Path
            Write-Item 'files'     $ds.Files
            Write-Item 'size'      "$($ds.SizeMB) MB"
            Write-Item 'nvinfo.pb' $(if ($ds.NvinfoPb) { "$($ds.NvinfoPb.Length) bytes" } else { 'MISSING' })
            if ($ds.Complete) { Write-Good 'complete - this is what the guest needs' }
            else { Write-Bad 'incomplete on the HOST - reinstall the NVIDIA driver before copying anything' }
        } catch { Write-Bad $_.Exception.Message }

        Write-Head 'Loader set (guest /usr/lib/wsl/lib)'
        try {
            $ld = Get-LoaderSet (Get-LoadersDir)
            Write-Item 'path'   $ld.Path
            Write-Item 'files'  $ld.Files
            Write-Item 'size'   "$($ld.SizeMB) MB"
            if ($ld.Missing.Count -eq 0) { Write-Good 'complete (cuda, nvml, dxcore, d3d12, nvidia-smi)' }
            else { Write-Bad "incomplete: missing $($ld.Missing -join ', ')" }
        } catch { Write-Bad $_.Exception.Message }

        Write-Head 'Which side is broken?'
        Write-Host @'
  guest: no /dev/dxg, or nvidia-smi says "blocked by the operating system"
      -> host: partition + MMIO.  This Check, then FixMmio / AddPartition.

  guest: nvidia-smi prints a table but cuInit segfaults
      -> guest userland: the DriverStore copy is trimmed.
         ShowDriverStore here, then Deploy (ssh) or Push (http).

  guest: nothing at all, no VMBus dxg channel
      -> host: no partition assigned. AddPartition.
'@
    }

    'ShowDriverStore' {
        Write-Head 'DriverStore'
        $ds = Get-NvDriverStore
        Write-Item 'path'      $ds.Path
        Write-Item 'files'     $ds.Files
        Write-Item 'size'      "$($ds.SizeMB) MB"
        Write-Item 'nvinfo.pb' $(if ($ds.NvinfoPb) { "$($ds.NvinfoPb.Length) bytes" } else { 'MISSING' })
        if ($ds.Complete) { Write-Good 'complete (~150 files). This is the folder the guest needs.' }
        else { Write-Bad 'incomplete - reinstall the NVIDIA driver first, do not copy this' }
        Write-Host ''
        Write-Host '  get it into the guest, either way:' -ForegroundColor Cyan
        if ($GuestHost) {
            Write-Host "    .\gpupv-windows.ps1 -Action Deploy -GuestHost $GuestHost -GuestUser $GuestUser"
        } else {
            Write-Host '    .\gpupv-windows.ps1 -Action Deploy -GuestHost <guest-ip> -GuestUser <user>   # ssh'
            Write-Host '    .\gpupv-windows.ps1 -Action Push   -GuestUrl http://<guest-ip>:8899/          # http'
        }
        Write-Output "DRIVERSTORE=$($ds.Path)"
    }

    'Deploy' {
        # End-to-end: script + DriverStore over ssh, install remotely, verify remotely.
        # No admin needed on the host: it only reads the DriverStore and writes
        # to the guest. (FixMmio / AddPartition do need it - they change the VM.)
        $ds = Get-NvDriverStore
        Assert-DriverStore $ds
        # -VMName is optional (one VM on the host implies it), and with the VM known
        # -GuestHost can be discovered from Hyper-V instead of typed by hand.
        $VMName = Get-VMName
        $target = Get-SshTarget

        Write-Head "Deploy to $target"
        Write-Item 'DriverStore' "$($ds.Path) ($($ds.Files) files, $($ds.SizeMB) MB)"

        # Partition preflight: without a partition the guest loads dxgkrnl and sees
        # zero adapters, and that is not something the guest side can fix.
        #   (default)   stop with instructions, before any multi-GB transfer
        #   -FixPartition stop the VM, assign the partition + MMIO, cold start it,
        #                 wait for ssh, then carry on with the install
        #   -Force      install the guest side anyway
        $vmState = $null
        try { $vmState = (Get-VM -Name $VMName -ErrorAction Stop).State } catch { $vmState = $null }
        if ($vmState) {
            $part = $null
            try { $part = Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction Stop } catch { }
            if (-not $part) {
                Write-Warn2 "VM '$VMName' has no GPU partition - the guest would load dxgkrnl and see zero adapters"
                if ($FixPartition) {
                    Assert-Admin
                    Confirm-StopVm "assigning a GPU partition requires stopping '$VMName'"
                    Write-Host '  assigning the partition and MMIO (cold start)' -ForegroundColor Cyan
                    if (-not (Repair-GpuPartition -VMName $VMName)) {
                        throw 'the host still reports no GPU partition for this VM - check Get-VMHostPartitionableGpu'
                    }
                    Write-Host '  waiting for the guest to accept ssh again' -ForegroundColor DarkGray
                    if (-not (Wait-GuestSsh -TimeoutSec 300)) {
                        throw "the guest did not come back on ssh within 5 minutes after the cold start"
                    }
                    Write-Good 'guest is back; continuing with the install'
                } elseif ($Force) {
                    Write-Warn2 'continuing anyway (-Force): the guest will be complete but show no adapter'
                } else {
                    Write-Host '  fix it now, without leaving this command:' -ForegroundColor Cyan
                    Write-Host "    .\gpupv-windows.ps1 -Action Deploy ... -FixPartition"
                    Write-Host '  or do it separately (both need the VM stopped):' -ForegroundColor Cyan
                    Write-Host "    .\gpupv-windows.ps1 -Action AddPartition -VMName $VMName"
                    throw 'no GPU partition on this VM; re-run with -FixPartition to assign it, or -Force to skip this check'
                }
            } else {
                Write-Good "GPU partition present ($($part.InstancePath))"
            }
        } else {
            Write-Host '    (VM state not readable without elevation - partition preflight skipped)' -ForegroundColor DarkGray
        }

        # 1. reachability as its own step: if this is what fails, the user must be
        #    able to tell that nothing else was attempted. The same probe checks the
        #    guest's build prerequisites, because a stock fnOS has `make` but no
        #    `gcc` - and finding that out after a 2.5 GB upload wastes the upload.
        Write-Host '  [1/6] ssh reachability'
        $r = Invoke-GuestSsh -Remote @('echo GPUPV_ALIVE; uname -r; id -un') -Capture
        if ($r.Output -notmatch 'GPUPV_ALIVE') {
            Write-Bad "ssh to $target failed:"
            Write-Host $r.Output
            throw 'fix ssh first (or use -Action Push over HTTP)'
        }
        $guestKernel = (($r.Output -split "`n") | Where-Object { $_ -match '^\d+\.\d+' } | Select-Object -First 1)
        Write-Good "ssh ok - guest kernel $guestKernel"

        # 2. the guest script, then ask THAT script about the toolchain: a
        #    hand-rolled probe here once said "toolchain present" while gcc was
        #    missing, because it was a second copy of the logic that could drift.
        #    (The loaders are uploaded in this step too - see below.)
        Write-Host '  [2/6] upload ' -NoNewline
        $localScript = Join-Path $RepoRoot $GuestScript
        if (-not (Test-Path $localScript)) { throw "$GuestScript not found next to this script" }
        Invoke-GuestSsh -Remote @("mkdir -p $RemoteDir") | Out-Null
        Send-GuestFile -Local $localScript -RemotePath "$RemoteDir/$GuestScript"
        Write-Good "$GuestScript ($([math]::Round((Get-Item $localScript).Length/1KB,1)) KB)"

        # The loaders are the OTHER half of the userland, and they do not come from
        # the DriverStore: /usr/lib/wsl/lib mirrors C:\Windows\System32\lxss\lib,
        # which Windows and the installed NVIDIA driver already provide. No
        # third-party package is involved unless you override -LoadersDir.
        $loadersRemote = ''
        if ($SkipLoaders) {
            Write-Host '  loaders skipped (-SkipLoaders)'
            # Skipping a step that has not been done leaves the stack unusable:
            # say what is actually in the guest, not just that we skipped.
            $chk = Invoke-GuestSsh -Capture -Remote @(
                "for f in libcuda.so.1 libnvidia-ml.so.1 libdxcore.so; do [ -e /usr/lib/wsl/lib/\$f ] && echo HAVE \$f; done"
            )
            $have = @($chk.Output -split "`n" | Where-Object { $_ -match '^HAVE ' })
            if ($have.Count -ge 3) {
                Write-Good 'guest already has the loaders'
            } else {
                Write-Warn2 "guest has only $($have.Count)/3 loader files - the stack will NOT work"
                Write-Warn2 'drop -SkipLoaders to upload them (from C:\Windows\System32\lxss\lib)'
            }
        } else {
            $ldDir = Get-LoadersDir
            $ld = Get-LoaderSet $ldDir
            if ($ld.Missing.Count -gt 0) {
                Write-Bad "the loader set at $($ld.Path) is incomplete: missing $($ld.Missing -join ', ')"
                throw 'the guest would get a payload with no usable loaders; install the NVIDIA driver (or a WSL update) on the host first'
            }
            Write-Item 'loaders' "$($ld.Path) ($($ld.Files) files, $($ld.SizeMB) MB)"
            $ltar = Join-Path $env:TEMP 'gpupv-loaders.tar'
            if (Test-Path $ltar) { Remove-Item $ltar -Force }
            & tar.exe -cf $ltar -C $ldDir .
            if ($LASTEXITCODE -ne 0) { throw "tar of the loader directory failed (exit $LASTEXITCODE)" }
            Send-GuestFile -Local $ltar -RemotePath "$RemoteDir/loaders.tar"
            Remove-Item $ltar -Force -ErrorAction SilentlyContinue
            $loadersRemote = "$RemoteDir/loaders"
            $lo = Invoke-GuestSsh -Capture -Remote @(
                "rm -rf $loadersRemote && mkdir -p $loadersRemote",
                "tar -xf $RemoteDir/loaders.tar -C $loadersRemote",
                "ls -1 $loadersRemote | wc -l"
            )
            # `wc -l` pads its output with spaces, so the number has to be trimmed
            # before it can be recognised - matching '^\d+$' without trimming found
            # nothing and the caller then called .Trim() on $null.
            $cnt = @($lo.Output -split "`n" |
                     ForEach-Object { $_.Trim() } |
                     Where-Object { $_ -match '^\d+$' } |
                     Select-Object -First 1)
            if ($cnt) {
                Write-Good "loaders uploaded and unpacked ($cnt files)"
            } else {
                Write-Warn2 'loaders archive uploaded, but the file count could not be read back'
                Write-Warn2 "check on the guest:  ls -1 $loadersRemote | wc -l"
            }
        }

        # deps is the guest tool's own answer, not a second implementation: it also
        # covers bison/flex/libelf, which the earlier hand-written probe missed.
        $d = Invoke-GuestSsh -Capture -Remote @("$RemoteDir/$GuestScript deps 2>&1")
        # deps prints one FAIL line per missing group, or a single OK line.
        $depsLines = @(($d.Output -split "`n") | ForEach-Object { $_.TrimEnd() } |
                       Where-Object { $_ -match 'missing|OK   gcc|gcc:|MISSING' })
        $depsMissing = @($depsLines | Where-Object { $_ -match 'missing|MISSING' })
        if ($depsMissing.Count -gt 0) {
            $depsLines | ForEach-Object { Write-Host "    $_" }
            if ($depsMissing -match 'linux-headers|headers  MISSING') {
                Write-Bad "kernel headers for $guestKernel are not installed in the guest"
                Write-Host "  in the guest:  sudo apt-get install -y linux-headers-$guestKernel" -ForegroundColor Cyan
                throw 'the module cannot be built without the kernel headers'
            }
            Write-Warn2 "'setup' installs the toolchain as root (one apt-get, one sudo prompt)."
            Write-Warn2 'to do it up front instead:  sudo ./gpupv-fnos.sh deps --install'
        } else {
            Write-Good 'toolchain present (gcc, make, xz, bison, flex, libelf/zlib headers)'
        }

        # 3. the DriverStore as ONE tar - 150 small files over scp is slow and the
        #    progress is invisible; one archive gives a single transfer to watch.
        #
        #    The archive keeps the nv_dispi.inf_amd64_<hash> folder as its ROOT.
        #    That folder NAME is half of the contract: on a fresh guest nothing is
        #    deployed yet, so DXCore's expected name can only come from the host's
        #    folder. Extracting with --strip-components=1 discards it and the
        #    install then has nothing to name the destination with.
        $dsLeaf = Split-Path -Leaf $ds.Path
        if ($SkipDriverStore) {
            Write-Host '  [3/6] DriverStore skipped (-SkipDriverStore)'
        } else {
            Write-Host '  [3/6] packing the DriverStore'
            $tar = Join-Path $env:TEMP 'gpupv-driverstore.tar'
            if (Test-Path $tar) { Remove-Item $tar -Force }
            & tar.exe -cf $tar -C (Split-Path -Parent $ds.Path) $dsLeaf
            if ($LASTEXITCODE -ne 0) { throw "tar failed (exit $LASTEXITCODE)" }
            $sizeMB = [math]::Round((Get-Item $tar).Length / 1MB, 1)
            Write-Item 'archive' "$tar ($sizeMB MB)"
            Write-Host '  [4/6] uploading (this is the slow part - 2.5 GB of driver payload)'
            Send-GuestFile -Local $tar -RemotePath "$RemoteDir/nvstore.tar"
            Write-Good 'archive uploaded'
            Remove-Item $tar -Force -ErrorAction SilentlyContinue
        }

        # 4. unpack, WITHOUT a tty: no root is needed, so its output is collected.
        #    With -SkipDriverStore there is nothing to unpack - resolve the payload
        #    that is already deployed instead of failing on a missing archive.
        $guestStore = ''
        if ($SkipDriverStore) {
            Write-Host '  [5/6] DriverStore skipped (-SkipDriverStore)'
            $u = Invoke-GuestSsh -Capture -Remote @(
                "chmod +x $RemoteDir/$GuestScript"
                "ls -d $WSL_DRIVERS_GUEST/nv_dispi.inf_amd64_* 2>/dev/null | head -1"
            )
            $guestStore = @($u.Output -split "`n" | ForEach-Object { $_.Trim() } |
                            Where-Object { $_ -match '/nv_dispi\.inf_amd64_' } |
                            Select-Object -First 1)
            if ($guestStore) {
                Write-Item 'payload' "$guestStore (already deployed)"
            } else {
                Write-Warn2 'no DriverStore is deployed in the guest either - nothing to install'
            }
        } else {
            Write-Host '  [5/6] unpacking in the guest'
            $u = Invoke-GuestSsh -Capture -Remote @(
                "chmod +x $RemoteDir/$GuestScript"
                "rm -rf $RemoteDir/nvstore && mkdir -p $RemoteDir/nvstore"
                "tar -xf $RemoteDir/nvstore.tar -C $RemoteDir/nvstore"
                "ls -d $RemoteDir/nvstore/nv_dispi.inf_amd64_* 2>/dev/null | head -1"
                "ls $RemoteDir/nvstore/*/ 2>/dev/null | wc -l || ls $RemoteDir/nvstore | wc -l"
            )
            $u.Output -split "`n" | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "    $_" }
            if ($u.Code -ne 0) { throw "unpack failed in the guest (exit $($u.Code)) - see the lines above" }

            # Resolve the unpacked payload from what the guest printed, not from an
            # assumption: the folder root is what DXCore will ask for by name.
            $lines = @($u.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $guestStore = $lines | Where-Object { $_ -match '/nvstore/nv_dispi\.inf_amd64_' } | Select-Object -First 1
            if (-not $guestStore) { $guestStore = "$RemoteDir/nvstore" }
            Write-Item 'payload' $guestStore
        }
        $storeArg = if ($SkipDriverStore) { '' } else { " $guestStore" }

        # 5. one privileged step, streamed live on this console.
        #
        #    Streaming, not capturing: with -Capture the pty's output (including
        #    sudo's "password:" prompt) is buffered until ssh exits, and ssh waits
        #    for a password nobody can see - the run then hangs with no output.
        #    sudo -v refreshes the timestamp once, so setup itself needs no prompt.
        Write-Host '  [6/6] running setup'
        $log = Join-Path $env:TEMP 'gpupv-deploy-guest.log'
        Write-Host "    (full guest output is also saved to $log)" -ForegroundColor DarkGray
        $setupArgs = $storeArg
        if ($loadersRemote) { $setupArgs = " --loaders $loadersRemote$storeArg" }
        if ($SudoPrompt) {
            # Password is asked HERE, hidden, and piped to 'sudo -S': no remote
            # prompt at all, so nothing can be swallowed by the console.
            Write-Host '    (you will be asked for the guest sudo password once)' -ForegroundColor DarkGray
            $v = Invoke-GuestSshSudo -Remote "$RemoteDir/$GuestScript setup$setupArgs" -LogPath $log
        } else {
            # Default: let ssh own the console (no host-side pipe), so sudo's prompt
            # is visible the moment it is written - it has no trailing newline, and
            # a piped stream would hold it until you typed something.
            Write-Host '    (sudo will ask for the password here; nothing is hidden)' -ForegroundColor DarkGray
            $v = Invoke-GuestSshLive -Remote "sudo $RemoteDir/$GuestScript setup$setupArgs" -LogPath $log
        }

        # Classify from evidence, in this order - a password line in the log does
        # NOT mean the password was rejected: ssh may re-prompt once for the second
        # channel while the first session runs fine.
        $setupRan = $v.Output -match 'setup: guest side'
        $allGates = $v.Output -match 'gates: \d+ checks, 0 failed'
        if ($v.Code -eq 0 -and $allGates) {
            Write-Good 'guest verified: CUDA + codecs work'
        } elseif (-not $setupRan) {
            Write-Bad 'the guest script never started, so nothing was installed'
            Write-Host "  the log's last lines are above; if it stops at a password prompt, use -SudoPrompt:" -ForegroundColor Cyan
            Write-Host "    .\gpupv-windows.ps1 -Action Deploy -GuestHost $GuestHost -GuestUser $GuestUser -SudoPrompt"
        } else {
            # setup ran: report what it actually said, do not guess a cause.
            $failed = @(($v.Output -split "`n") | Where-Object { $_ -match '^\s*(FAIL|ERROR)' } |
                        ForEach-Object { $_.Trim() })
            Write-Bad "guest setup ran but did not finish cleanly (ssh exit $($v.Code))"
            if ($failed.Count -gt 0) { $failed | Select-Object -First 8 | ForEach-Object { Write-Host "    $_" } }
            Write-Host "  full log: $log" -ForegroundColor DarkGray
            Write-Host "  deeper: " -NoNewline
            Write-Host (".\gpupv-windows.ps1 -Action Remote -GuestHost $GuestHost -GuestCommand doctor") -ForegroundColor Cyan
        }
    }

    'Remote' {
        <#  Stream to this console, never capture: a sudo password prompt has to
            be visible. -AsRoot refreshes the sudo timestamp once and then runs the
            command with -n, so exactly one prompt appears. #>
        $target = Get-SshTarget
        $line = "$RemoteDir/$GuestScript $GuestCommand"
        Write-Head "Remote: $target"
        Write-Host "  $line" -ForegroundColor DarkGray
        $log = Join-Path $env:TEMP 'gpupv-remote.log'
        if ($SudoPrompt) {
            $v = Invoke-GuestSshSudo -Remote $line -LogPath $log
        } else {
            if ($AsRoot -and $line -notmatch '^\s*sudo') { $line = "sudo $line" }
            $v = Invoke-GuestSshLive -Remote $line -LogPath $log
        }
        if ($v.Code -ne 0) { Write-Bad "remote command exited $($v.Code) (log: $log)" }
        exit $v.Code
    }

    'Push' {
        if (-not $GuestUrl) { throw '-GuestUrl http://<guest-ip>:8899/ is required' }
        if ($GuestUrl -notmatch '/$') { $GuestUrl += '/' }
        $ds = Get-NvDriverStore
        Assert-DriverStore $ds

        Write-Head "Push $($ds.Files) files -> $GuestUrl"
        try {
            $alive = curl.exe -s --max-time 5 $GuestUrl
            if ($alive -notmatch 'alive') {
                Write-Bad "guest receiver did not answer 'alive' (got: $alive)"
                Write-Host '  in the guest:  ./gpupv-fnos.sh receive /tmp/nvstore 8899' -ForegroundColor Cyan
                return
            }
            Write-Good 'guest receiver is alive'
        } catch { Write-Bad "cannot reach $GuestUrl"; return }

        $files = Get-ChildItem $ds.Path -File
        $i = 0; $failed = 0
        foreach ($f in $files) {
            $i++
            $r = curl.exe -s --max-time 600 -T $f.FullName $GuestUrl
            if ($r -notmatch '^ok') {
                $failed++
                Write-Host ("  FAIL [{0}/{1}] {2} -> {3}" -f $i, $files.Count, $f.Name, $r) -ForegroundColor Red
            } elseif ($i % 20 -eq 0) {
                Write-Host ("  [{0}/{1}] ok" -f $i, $files.Count)
            }
        }
        Write-Head 'Transfer complete'
        Write-Item 'sent'   $files.Count
        Write-Item 'failed' $failed
        if ($failed -eq 0) {
            Write-Good 'guest side now:'
            Write-Host '  ./gpupv-fnos.sh driverstore compare /tmp/nvstore'
            Write-Host '  sudo ./gpupv-fnos.sh driverstore install /tmp/nvstore'
            Write-Host '  sudo ./gpupv-fnos.sh service install --selftest'
            Write-Host '  ./gpupv-fnos.sh verify'
        } else {
            Write-Bad 'some files did not land - re-run before installing'
        }
    }

    'FixMmio' {
        Assert-Admin
        $VMName = Get-VMName
        Write-Head "FixMmio + partition: $VMName"
        if ((Get-VM -Name $VMName).State -ne 'Off') { Confirm-StopVm 'the VM must be stopped to change MMIO and the partition' }
        if (-not (Repair-GpuPartition -VMName $VMName)) {
            Write-Bad 'the host still reports no GPU partition - check Get-VMHostPartitionableGpu'
        }
        Write-Host ''
        Write-Host '  next: give the guest ~1 minute, then in the guest:  gpupv-fnos.sh verify' -ForegroundColor Cyan
    }

    'AddPartition' {
        Assert-Admin
        $VMName = Get-VMName
        Write-Head "AddPartition: $VMName"
        if ((Get-VM -Name $VMName).State -ne 'Off') { Confirm-StopVm 'the VM must be stopped to re-assign the partition' }
        if (-not (Repair-GpuPartition -VMName $VMName)) {
            Write-Bad 'the host still reports no GPU partition - check Get-VMHostPartitionableGpu'
        }
        Write-Host ''
        Write-Host "  next: .\gpupv-windows.ps1 -Action Remote -GuestHost <ip> -GuestCommand verify" -ForegroundColor Cyan
    }

    'ShowPowerShell' {
        # The host console reorders multi-line pastes, so this prints ONE line per
        # action that can be typed as-is. Nothing here changes state.
        $line = switch ($For) {
            'Check' {
                '$VM="' + $VMName + '"; Get-VM $VM | Select Name,State,GuestControlledCacheTypes,LowMemoryMappedIoSpace,HighMemoryMappedIoSpace; Get-VMGpuPartitionAdapter -VMName $VM | Select VMName,InstancePath; (Get-CimInstance Win32_VideoController | ? {$_.AdapterCompatibility -match "NVIDIA"}).DriverVersion; try{(Get-VMHostPartitionableGpu|select -first 3 -exp Name)}catch{(Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_PartitionableGpu|select -exp Name)}; Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HyperV" -EA 0'
            }
            'ShowDriverStore' {
                '$d=((Get-CimInstance Win32_VideoController | ? {$_.AdapterCompatibility -match "NVIDIA"}).InstalledDisplayDrivers -split ",")[0] | Split-Path -Parent; "dir=$d"; "files=" + (Get-ChildItem $d -File).Count; $n=Get-Item "$d\nvinfo.pb" -EA 0; "nvinfo.pb=" + $(if($n){"$($n.Length) bytes"}else{"MISSING"})'
            }
            'Push' {
                '$d=((Get-CimInstance Win32_VideoController | ? {$_.AdapterCompatibility -match "NVIDIA"}).InstalledDisplayDrivers -split ",")[0] | Split-Path -Parent; Get-ChildItem $d -File | % { $r = curl.exe -s --max-time 600 -T $_.FullName "' + $GuestUrl + '"; if ($r -notmatch "^ok") { "FAIL: $($_.Name)" } }; "done"'
            }
            'FixMmio' {
                # Same bug class as the script itself: Set-VM wants bytes, not '256GB'.
                '.\\gpupv-windows.ps1 -Action FixMmio -VMName ' + $VMName + ' -Force'
            }
            'AddPartition' {
                # One paste-ready line that calls the script itself, so the repair
                # exists in exactly one place (an inlined copy is how the two drift).
                '.\gpupv-windows.ps1 -Action AddPartition -VMName ' + $VMName + ' -Force'
            }
            'Deploy' {
                # The archive keeps the nv_dispi.inf_amd64_<hash> folder as its root -
                # that name is what DXCore asks the loader for, so it must survive the
                # transfer. One sudo prompt, then 'setup' does the whole guest side.
                '$d=((Get-CimInstance Win32_VideoController | ? {$_.AdapterCompatibility -match "NVIDIA"}).InstalledDisplayDrivers -split ",")[0] | Split-Path -Parent; $t=Join-Path $env:TEMP "nvstore.tar"; tar.exe -cf $t -C (Split-Path -Parent $d) (Split-Path -Leaf $d); ssh ' + $GuestUser + '@' + $GuestHost + ' "mkdir -p /tmp/gpupv"; cat $t | ssh ' + $GuestUser + '@' + $GuestHost + ' "cat > /tmp/gpupv/nvstore.tar"; scp -P ' + $SshPort + ' .\gpupv-fnos.sh ' + $GuestUser + '@' + $GuestHost + ':/tmp/gpupv/; ssh -t ' + $GuestUser + '@' + $GuestHost + ' "chmod +x /tmp/gpupv/gpupv-fnos.sh; rm -rf /tmp/gpupv/nvstore && mkdir -p /tmp/gpupv/nvstore; tar -xf /tmp/gpupv/nvstore.tar -C /tmp/gpupv/nvstore; sd=$(ls -d /tmp/gpupv/nvstore/nv_dispi.inf_amd64_* 2>/dev/null | head -1); sudo -v; sudo -n /tmp/gpupv/gpupv-fnos.sh setup ${sd:-/tmp/gpupv/nvstore}"'
            }
        }
        Write-Output $line
    }
}
