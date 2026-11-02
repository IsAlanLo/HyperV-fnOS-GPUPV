# Troubleshooting: symptom → layer → fix

Each section names the **measured** signature and the command that confirms it. Work top-down: an
earlier layer failing makes every later observation meaningless.

## Layer map

```
 5  app (ffmpeg / Jellyfin / a container)      ← "no GPU work" but the guest is fine
 4  userland payload  /usr/lib/wsl/drivers/…   ← NVML green, cuInit crashes
 3  loaders           /usr/lib/wsl/lib         ← "couldn't communicate with the NVIDIA driver"
 2  module            dxgkrnl + /dev/dxg       ← "Failed to initialize NVML"
 1  host              partition + MMIO         ← "no adapter started", no VMBus channel
```

| `nvidia-smi` says | layer |
|---|---|
| `GPU access blocked by the operating system` | 1-2: `/dev/dxg` absent, or present with no adapter started |
| `couldn't communicate with the NVIDIA driver` | 3-4: `/dev/dxg` works, the payload set is wrong or too shallow |
| `Failed to initialize NVML` and no `/dev/dxg` | 2: the module never loaded |
| a full table, but `cuInit` crashes | 4: DriverStore is trimmed (§4 below) |

---

## 1. No `/dev/dxg`, no `dxgkrnl`

```bash
gpupv-fnos.sh triage
```

- **No dxg VMBus channels at all** → host side. `gpupv-windows.ps1 -Action Check`, then
  `-Action AddPartition`. A stale `HostResource` (after a driver reinstall) still hands the guest
  channels but nothing usable behind them.
- **Channels present, module not loaded** → build and install it:

  ```bash
  ./gpupv-fnos.sh module build
  sudo ./gpupv-fnos.sh module install ~/.cache/gpupv/dxgkrnl-$(uname -r)/dxgkrnl.ko
  ```

- **`modprobe` reports `Error running install command '/bin/false'`** → a policy file blocks it.
  The deploy scripts only delete `/etc/modprobe.d/blacklist-dxgkrnl.conf`; a file saved under any
  other name (e.g. `blacklist-dxgkrnl-recovery.conf`) survives every re-run:

  ```bash
  grep -rn 'dxgkrnl' /etc/modprobe.d/ /lib/modprobe.d/ /usr/lib/modprobe.d/
  ```

  Delete by the name the grep printed. `service install` renames such files automatically.

- **`modprobe` hangs and never returns** → the probe is stuck, and the task is unkillable:

  ```bash
  ps -eo pid,stat,cmd | awk '$2 ~ /D/'
  gpupv-fnos.sh doctor           # §5 there: D-state tasks, dmesg oops fingerprint
  ```

  Two causes, told apart by `dmesg`: a `BUG: kernel NULL pointer dereference` at
  `dxg_probe_vmbus+…` means the module was built against a foreign `hyperv.h` (§2); a hang with
  `pci_device_probe` in `/proc/<pid>/stack` and all-zero PCI BARs means the host gave no MMIO (§1).
  Either way only a cold VM stop/start clears the `D` task.

## 2. The module loads but the build is wrong (matching `vermagic` proves nothing)

```bash
./gpupv-fnos.sh module verify /path/to/dxgkrnl.ko     # offine gates
gpupv-fnos.sh doctor                                   # gates applied to the RUNNING module
```

`channel-off` is the gate that matters. `dxg_probe_vmbus` must read `hdev->channel` at the running
kernel's offset. A module built against the WSL branch's `include/linux/hyperv.h` reads a
neighbouring field (`driver_override`, NULL for a VMBus device) and dereferences `NULL + 0x34`:

```
BUG: kernel NULL pointer dereference, address: 0000000000000034
RIP: dxg_probe_vmbus+0xa1/0x150 [dxgkrnl]
```

`gpupv-fnos.sh module build` never does this — it keeps the kernel's header and adds only the two GPU-PV
GUIDs in a generated `include/linux/hyperv_gpup.h`.

## 3. NVML says "couldn't communicate with the NVIDIA driver"

The loader/payload split:

```bash
ls -l /usr/lib/wsl/lib/libcuda.so.1.1                              # ~171 KB  → loader
ls -l /usr/lib/wsl/drivers/nv_dispi.inf_amd64_*/libcuda.so.1.1      # ~25 MB   → payload
```

`/usr/lib/wsl/lib` mirrors `C:\Windows\System32\lxss\lib`; `/usr/lib/wsl/drivers/<folder>` mirrors
`C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf_amd64_<hash>` and is the only place
`libnvidia-nvvm.so.4`, `libnvidia-ptxjitcompiler.so.1`, `libnvidia-tileiras.so` and
`libnvdxgdmal.so.1` exist.

The **payload must live one directory deeper than you think**: DXCore hands the loader a driver-store
*folder name* and the loader opens `<that>/<lib>`. Copying the payload flat into
`/usr/lib/wsl/drivers/` leaves every library unreachable and produces exactly this message.

Confirm a payload is reached at all before touching versions:

```bash
LD_DEBUG=files /usr/bin/nvidia-smi 2>&1 | grep -c /usr/lib/wsl/drivers   # 0 = never reached
gpupv-fnos.sh doctor                                                        # does this for you
```

A trace that stops after `libnvidia-ml.so.1` + `libdxcore.so` means the fault is **upstream of the
payload** — no version of either directory can fix it. Go back to layer 2.

## 4. NVML prints a table but `cuInit` segfaults  ← the big one

**Check the file count first. Always.**

```bash
ls /usr/lib/wsl/drivers/nv_dispi.inf_amd64_*/ | wc -l
ls /usr/lib/wsl/drivers/nv_dispi.inf_amd64_*/ | grep -vc '\.so'
```

- `< 20` files, or `0` non-`.so` → **trimmed**. A complete folder has ~150 files including
  `nvinfo.pb` (≈153 KB), `nvapi64.dll`, `nvml.dll`, `nvEncodeAPI64.dll`.

Why it matters: `nvinfo.pb` and friends are data files the loader finds **by convention inside that
directory**; `libcuda` fills adapter fields from them. Missing → an uninitialised pointer field:

```asm
; libcuda.so.1.1+0x516f6d
mov  0x20(%r15),%rax      ; rax = 0x30, not an address
movb $0x0,0x293c(%rax)    ; write to 0x30 + 0x293c = 0x296c → SIGSEGV
```

`strings libcuda.so.1.1 | grep nvinfo` finds the name **once, without a path** — that is not evidence
it is unused. A filename absent from a library's strings is not proof.

Fix:

```bash
# host
gpupv-windows.ps1 -Action ShowDriverStore      # expect files=153, nvinfo.pb present
gpupv-windows.ps1 -Action Push -GuestUrl http://<guest-ip>:8899/
#   guest first:  python3 src/http_put_server.py /tmp/nvstore 8899

# guest
./gpupv-fnos.sh driverstore compare /tmp/nvstore      # same build? subset? different build?
sudo ./gpupv-fnos.sh driverstore install /tmp/nvstore # overlay, backup kept, cuInit tested
```

`different driver BUILD` in the compare output ⇒ use `install … --replace` instead of an overlay.

If `cuInit` is **still** non-zero with a complete DriverStore, the remaining candidates are the module
branch (layer 2) and the host driver generation (layer 1). Do not spend build cycles on these — each
was measured and rejected on the original machine:

| tried | result |
|---|---|
| interface version 40 → 46 (branch head) | NVML fine, `cuInit` crashed at the *same* offset |
| 6.6.y sources instead of 6.18.y | `diff` of `dxgvmbus.c`/`ioctl.c`/`dxgmodule.c`/`dxgkrnl.h`: 0 lines |
| `remap_pfn_range` WARN as the cause | the assert returns `void`; `WARN_ON` does not abort the path |
| `mmap_write_lock` rebuild | crash offset unchanged |
| clang-14 `libdxcore`/`libd3d12` from a WSL msix | byte-identical to the deployed ones |
| stubbing 9 missing `D3DKMT*` exports | crash offset unchanged |
| `ld.so.conf` search order | both orders crash identically |

The signature that kills a hypothesis: **the crash offset did not move.** If `libcuda+0x516f71` /
`si_addr 0x296c` / `dxgdmalEnumAdapters+0x44c` are unchanged, the thing you changed is not the cause.

## 5. Codecs fail although `cuInit` is 0

- **`Driver does not support the required nvenc API version. Required: 13.1 Found: 13.0`** → the
  ffmpeg is newer than the driver. Use the distribution build (`/usr/bin/ffmpeg`, 8.x here), not a
  bundled static 9.x. `gpupv-fnos.sh verify` prefers `/usr/bin/ffmpeg`.
- **`av1_nvenc` fails on RTX 3060 Ti / 3070 / 3080** → GA104 has no AV1 encoder. Decode
  (`av1_cuvid`) works. Not a fault.
- **`nvidia-smi --query-gpu=encoder.stats.sessionCount` shows a session but the output is 0 bytes** →
  the session opened and no frame was submitted; not success.
- **A container sees no GPU while the host ffmpeg is perfect** → the runtime injected only the compute
  half. Check `/proc/<pid>/mountinfo` for `libcuda`, `libnvidia-*`, `/dev/dxg`; an app whose `auto`
  backend looks for `/dev/nvidia0` or `/proc/driver/nvidia/version` will always pick software under
  GPU-PV. Also check the codec histogram of the material: a browser-native H.264 MP4 is direct-played
  and never reaches a transcoder, so 0 % GPU is the correct answer there.

## 6. It worked, then a guest kernel update broke it

A kernel bump invalidates the DKMS module. Before updating:

```bash
# back up what works
sudo cp -a /lib/modules/$(uname -r)/updates/dkms/dxgkrnl.ko.xz /root/dxgkrnl-$(uname -r).ko.xz
sudo cp -a /usr/src/dxgkrnl-* /root/ 2>/dev/null
```

After the update:

```bash
./gpupv-fnos.sh module build            # branch chosen from uname -r automatically
sudo ./gpupv-fnos.sh module install ~/.cache/gpupv/dxgkrnl-$(uname -r)/dxgkrnl.ko
sudo ./gpupv-fnos.sh service install --selftest
```

`module build --branch wsl-6.6.y` also works on a 6.13+ kernel: the port rewrites
`eventfd_signal(fd, 1)`, `__get_task_comm`, the missing `vmalloc.h` include and the removed
`dma_fence_ops.fence_value_str`/`.timeline_value_str` slots. Verified compile-and-link on
6.18.18, gates passing — but which branch fixes a given *runtime* symptom is a separate question:
never present the swap as a fix until `verify` says so.

## 7. Reading a result correctly

- An exit code read through a pipe is the **pipe's**. `ffmpeg … | tail` reports `tail`'s 0 and hides a
  segfault. Run standalone, or use `${PIPESTATUS[0]}`.
- A deploy script's `[STATUS: SUCCESS]` proves nothing: those scripts are full of `|| true`.
- `Get-VMGpuPartitionAdapter` with empty Min/Max/Optimal fields is normal.
- The `WinNT → ServerNT` toggle in GPU tools gates **DDA**, not GPU-PV.
- `HypervisorSchedulerType = 1` (core scheduling) costs guest CPU throughput and the dxg path is a
  synchronous round-trip; `2` or absent is classic.
