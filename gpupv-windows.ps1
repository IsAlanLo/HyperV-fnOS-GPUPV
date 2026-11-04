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
    [ValidateSet('Check', 'ShowDriverStore', 'Deploy', 'Push', 'Remote',
                 'FixMmio', 'AddPartition', 'ShowPowerShell')]
    [string]$Action = 'Check',

    # which action's one-liner to print for -Action ShowPowerShell
    [ValidateSet('Check', 'ShowDriverStore', 'Push', 'FixMmio', 'AddPartition', 'Deploy')]
    [string]$For = 'Check',

    [string]$VMName = 'fnos',

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

    # skip re-copying the DriverStore when the guest already has it complete
    [switch]$SkipDriverStore,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Head($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Write-Item($k, $v) { Write-Host ("  {0,-26} {1}" -f $k, $v) }
function Write-Warn2($m) { Write-Host "  WARN $m" -ForegroundColor Yellow }
function Write-Bad($m)   { Write-Host "  FAIL $m" -ForegroundColor Red }
function Write-Good($m)  { Write-Host "  OK   $m" -ForegroundColor Green }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this in an Administrator PowerShell.'
    }
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

function Get-SshTarget {
    if (-not $GuestHost) { throw '-GuestHost <guest ip or name> is required for SSH actions' }
    "$GuestUser@$GuestHost"
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
switch ($Action) {

    'Check' {
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
        $target = Get-SshTarget

        Write-Head "Deploy to $target"
        Write-Item 'DriverStore' "$($ds.Path) ($($ds.Files) files, $($ds.SizeMB) MB)"

        # 1. reachability as its own step: if this is what fails, the user must be
        #    able to tell that nothing else was attempted. The same probe checks the
        #    guest's build prerequisites, because a stock fnOS has `make` but no
        #    `gcc` - and finding that out after a 2.5 GB upload wastes the upload.
        Write-Host '  [1/6] ssh + guest prerequisites'
        $probe = 'echo GPUPV_ALIVE; uname -r; id -un; ' +
                 'for b in gcc make xz depmod; do command -v $b >/dev/null 2>&1 || printf "MISSING %s\n" $b; done; ' +
                 '[ -d /lib/modules/$(uname -r)/build ] || echo "MISSING headers"'
        $r = Invoke-GuestSsh -Remote @($probe) -Capture
        if ($r.Output -notmatch 'GPUPV_ALIVE') {
            Write-Bad "ssh to $target failed:"
            Write-Host $r.Output
            throw 'fix ssh first (or use -Action Push over HTTP)'
        }
        $guestKernel = (($r.Output -split "`n") | Where-Object { $_ -match '^\d+\.\d+' } | Select-Object -First 1)
        Write-Good "ssh ok - guest kernel $guestKernel"

        $missing = @(($r.Output -split "`n") | Where-Object { $_ -match '^MISSING ' } | ForEach-Object { $_.Substring(8).Trim() })
        if ($missing -contains 'headers') {
            Write-Bad "kernel headers for $guestKernel are not installed in the guest"
            Write-Host "  in the guest:  sudo apt-get install -y linux-headers-$guestKernel" -ForegroundColor Cyan
            throw 'the module cannot be built without the kernel headers'
        } elseif ($missing.Count -gt 0) {
            Write-Warn2 "guest is missing: $($missing -join ', ')"
            Write-Warn2 "a stock fnOS has make but no gcc - 'setup' installs the toolchain as root (one apt-get)."
            Write-Warn2 'to install it up front instead:  sudo ./gpupv-fnos.sh deps --install'
        } else {
            Write-Good 'toolchain present (gcc, make, xz, depmod, kernel headers)'
        }

        # 2. the guest script
        Write-Host '  [2/6] upload ' -NoNewline
        $localScript = Join-Path $RepoRoot $GuestScript
        if (-not (Test-Path $localScript)) { throw "$GuestScript not found next to this script" }
        Invoke-GuestSsh -Remote @("mkdir -p $RemoteDir") | Out-Null
        Send-GuestFile -Local $localScript -RemotePath "$RemoteDir/$GuestScript"
        Write-Good "$GuestScript ($([math]::Round((Get-Item $localScript).Length/1KB,1)) KB)"

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

        # 4. unpack first, WITHOUT a tty: no root is needed, so its output is
        #    collected and read directly.
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
        if ($SudoPrompt) {
            # Password is asked here, hidden, and piped to 'sudo -S' on the guest:
            # no remote pty prompt is involved, so nothing can hang waiting for a
            # prompt the console never shows.
            Write-Host '    (you will be asked for the guest sudo password once)' -ForegroundColor DarkGray
            $v = Invoke-GuestSshSudo -Remote "$RemoteDir/$GuestScript setup$storeArg" -LogPath $log
        } else {
            # Default: stream the run on this console. sudo prompts on the remote
            # tty, which works whenever this window is interactive - and 'sudo -v'
            # keeps it to a single prompt for the whole run.
            $v = Invoke-GuestSshStream -Remote @("sudo -v && sudo -n $RemoteDir/$GuestScript setup$storeArg") -LogPath $log
        }

        if ($v.Code -eq 0 -and $v.Output -match 'gates: \d+ checks, 0 failed') {
            Write-Good 'guest verified: CUDA + codecs work'
        } elseif ($v.Output -match 'Password:|try again') {
            Write-Bad 'the guest never accepted the sudo password, so nothing was installed'
            Write-Host "  re-run just the install (it will prompt once, visibly):" -ForegroundColor Cyan
            Write-Host "    .\gpupv-windows.ps1 -Action Remote -GuestHost $GuestHost -GuestUser $GuestUser -AsRoot -GuestCommand `"setup$storeArg`""
        } else {
            Write-Bad "guest setup did not finish cleanly (ssh exit $($v.Code)) - full log: $log"
            Write-Host "  deeper: " -NoNewline
            Write-Host ("  .\gpupv-windows.ps1 -Action Remote -GuestHost $GuestHost -GuestCommand doctor") -ForegroundColor Cyan
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
            if ($AsRoot -and $line -notmatch '^\s*sudo') { $line = "sudo -v && sudo -n $line" }
            $v = Invoke-GuestSshStream -Remote @($line) -LogPath $log
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
        Write-Head "FixMmio: $VMName"
        if ((Get-VM -Name $VMName).State -ne 'Off') { Confirm-StopVm 'the VM must be stopped to change MMIO' }
        Stop-VM -Name $VMName -Force
        Set-VM -Name $VMName -GuestControlledCacheTypes $true
        Set-VM -Name $VMName -LowMemoryMappedIoSpace $LowMmio
        $applied = $null
        foreach ($cand in @($HighMmio, '128GB', '64GB', '34.5GB')) {
            try {
                Set-VM -Name $VMName -HighMemoryMappedIoSpace $cand -ErrorAction Stop
                $applied = $cand; Write-Good "HighMemoryMappedIoSpace = $cand"; break
            } catch {
                Write-Warn2 "host refused HighMemoryMappedIoSpace=$cand : $(($_.Exception.Message -split "`n")[0])"
            }
        }
        if (-not $applied) { Write-Bad 'no MMIO candidate accepted - the host ceiling is below 34.5GB' }
        $vm = Get-VM -Name $VMName
        Write-Item 'GuestControlledCacheTypes' $vm.GuestControlledCacheTypes
        Write-Item 'LowMemoryMappedIoSpace'    $vm.LowMemoryMappedIoSpace
        Write-Item 'HighMemoryMappedIoSpace'   $vm.HighMemoryMappedIoSpace
        Write-Host "`n  next: Start-VM $VMName   (cold start, not a guest reboot)" -ForegroundColor Cyan
    }

    'AddPartition' {
        Assert-Admin
        Write-Head "AddPartition: $VMName"
        if ((Get-VM -Name $VMName).State -ne 'Off') { Confirm-StopVm 'the VM must be stopped to re-assign the partition' }
        if ((Get-VM -Name $VMName).State -ne 'Off') { Stop-VM -Name $VMName -Force }
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
        Get-VMGpuPartitionAdapter -VMName $VMName | Format-List VMName, InstancePath | Out-String | Write-Host
        Write-Host "  next: Start-VM $VMName" -ForegroundColor Cyan
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
                '$VM="' + $VMName + '"; Stop-VM $VM -Force; Set-VM -VM $VM -GuestControlledCacheTypes $true; Set-VM -VM $VM -LowMemoryMappedIoSpace ' + $LowMmio + '; Set-VM -VM $VM -HighMemoryMappedIoSpace ' + $HighMmio + '; Get-VM $VM | Select Name,State,GuestControlledCacheTypes,LowMemoryMappedIoSpace,HighMemoryMappedIoSpace'
            }
            'AddPartition' {
                '$VM="' + $VMName + '"; if((Get-VM $VM).State -ne "Off"){Stop-VM $VM -Force}; Remove-VMGpuPartitionAdapter -VMName $VM -EA 0; Add-VMGpuPartitionAdapter -VMName $VM; Get-VMGpuPartitionAdapter -VMName $VM | Select VMName,InstancePath'
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
