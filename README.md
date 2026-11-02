# hyperv-gpupv

Hyper-V **GPU-PV** (GPU partitioning) for a Linux guest — the distilled, scripted version of a working
fnOS/Debian setup on an RTX 3060 Ti, where the final blocker turned out to be a **trimmed NVIDIA
DriverStore directory**, not the kernel, the protocol or the library generation.

Two files do everything:

| file                    | runs on                                 | role                                                                                           |
| ----------------------- | --------------------------------------- | ---------------------------------------------------------------------------------------------- |
| **`gpupv-windows.ps1`** | Windows host (Administrator PowerShell) | host checks, GPU partition / MMIO, and the whole guest install **over SSH**                    |
| **`gpupv-fnos.sh`**     | the Linux guest (fnOS, Debian, Ubuntu…) | diagnostic + repair tool: triage, verify, build dxgkrnl, install the DriverStore, boot service |

The Windows script SSHes into the guest, uploads `gpupv-fnos.sh` and the complete DriverStore
archive, runs the install and reads the verification back. If the guest has no `sshd`, both sides
also support a plain HTTP transfer (`-Action Push` ↔ `gpupv-fnos.sh receive`).

Every claim in this repo is measured behaviour. Every script fails loudly, keeps a rollback, and
refuses to call anything working off `nvidia-smi`.

---

## Why this exists

A GPU-PV guest is four layers, and each has a signature that looks like the others:

```
app → libcuda.so.1  (loader, ~171 KB)         "NVML prints a table but cuInit segfaults"
      → libcuda.so.1.1 (payload, ~25 MB)
      → libdxcore → /dev/dxg → dxgkrnl         "GPU access blocked by the operating system"
      → VMBus channel → GPU partition (host)   "no adapter started"
      → DriverStore/nv_dispi…/nvinfo.pb …      the metadata nobody copies
```

On the machine this came from the guest's DriverStore copy had **18 files, all `.so`, zero
metadata**, while the host's folder held **153 files**. `nvidia-smi` printed a full table and
`cuInit` segfaulted at a constant offset (`libcuda+0x516f71`, `si_addr 0x296c`). Copying the complete
host folder made `cuInit` return `0` immediately; `h264_nvenc`, `hevc_nvenc`, `h264_cuvid`,
`hevc_cuvid` and `hwaccel cuda` all worked.

So: **count files before theorising about mechanisms.** Two commands decide it.

```bash
ls /usr/lib/wsl/drivers/nv_dispi.inf_amd64_*/ | wc -l             # < 20  → trimmed
ls /usr/lib/wsl/drivers/nv_dispi.inf_amd64_*/ | grep -vc '\.so'    # 0     → trimmed
```

---

繁體中文快速上手：**[docs/quickstart.zh-TW.md](docs/quickstart.zh-TW.md)**

## Quick start

### Windows host, with SSH into the guest (recommended)

```powershell
# 1. what does the host look like? (read-only)
.\gpupv-windows.ps1 -Action Check -VMName fnos

# 2. is the host's DriverStore complete? (~150 files + nvinfo.pb)
.\gpupv-windows.ps1 -Action ShowDriverStore

# 3. do the whole guest install and verify it
.\gpupv-windows.ps1 -Action Deploy -VMName fnos -GuestHost 192.168.x.x -GuestUser youruser
```

`Deploy` prints six numbered steps: ssh reachability → upload the script → pack the DriverStore →
upload the archive → install in the guest (sudo prompts appear in this console) → run the gates and
repeat their output here. Nothing is hidden behind a spinner.

Host requirements: Administrator PowerShell, the guest's OpenSSH server enabled, `tar.exe` (bundled
with Windows 10 1803+).

### No SSH? (HTTP transfer)

```powershell
.\gpupv-windows.ps1 -Action Push -GuestUrl http://192.168.x.x:8899/
```

```bash
# in the guest first:
./gpupv-fnos.sh receive /tmp/nvstore 8899
# then, after the push lands:
./gpupv-fnos.sh driverstore compare /tmp/nvstore
sudo ./gpupv-fnos.sh driverstore install /tmp/nvstore
sudo ./gpupv-fnos.sh service install --selftest
./gpupv-fnos.sh verify
```

### Guest only, from scratch

```bash
# one file, no repo checkout needed
sudo ./gpupv-fnos.sh setup              # module + boot service, then verify
sudo ./gpupv-fnos.sh setup /tmp/nvstore # ... and overlay the DriverStore from a directory
```

`setup` is idempotent: it skips every step whose result already exists.

---

## What the guest script does

```
triage      root-free: module / /dev/dxg / VMBus channels / DriverStore / NVML / load path
verify      5 gates: device → DriverStore shape → NVML → cuInit → NVENC/CUVID matrix
probe       compiles dxg_probe.c: proves module → channel → host partition with no NVIDIA lib
doctor      DriverStore counts, offline module ABI gates, LD_DEBUG payload trace, D-state probes
report      writes a markdown evidence file (attach this to an issue)
setup       the whole guest side in one shot, idempotent
module build | verify | install | restore
driverstore status | compare | install | rollback
receive     HTTP PUT receiver for the DriverStore
service install | status | uninstall
```

### The five gates that count

`verify` will not call anything working until all of these pass, in order:

1. `dxgkrnl` loaded, `/dev/dxg` present, **both** dxg VMBus channels bound
2. DriverStore complete (>150 files **and** non-`.so` metadata present)
3. `nvidia-smi` answers — labelled *monitoring path only*, because that alone proves nothing
4. `cuInit(0) == 0` with a real device name and VRAM
5. the codecs actually used: `h264_nvenc`, `hevc_nvenc`, `h264_cuvid`, `hevc_cuvid`

`av1_nvenc` failing on GA104-class cards (RTX 3060 Ti / 3070 / 3080) is **silicon**, not a stack
fault — those decode AV1 but cannot encode it. The tool says so instead of counting it as breakage.

### `doctor` answers the expensive question first

```bash
./gpupv-fnos.sh doctor
```

1. DriverStore file counts (two `ls | wc` — explains most `cuInit` crashes)
2. loader vs payload sizes, and the version stamped in the payload
3. offline ABI gates on the **running** module
4. does any payload under `/usr/lib/wsl/drivers` get `dlopen`ed at all (`LD_DEBUG=files`)
5. hung `D`-state probes and the dmesg oops fingerprint

If step 4 shows zero, no amount of library swapping can help — the fault is upstream of the payload.

---

## What the Windows script does

| action            | changes state | what it does                                                                                                     |
| ----------------- | ------------- | ---------------------------------------------------------------------------------------------------------------- |
| `Check`           | no            | VM settings, partition, partitionable GPU pool, host driver, policy, hypervisor scheduler, DriverStore           |
| `ShowDriverStore` | no            | resolves the `nv_dispi.inf_amd64_<hash>` folder without hard-coding the hash; counts files; flags incompleteness |
| `Deploy`          | guest yes     | ssh → script + tar → install + service → verify, all in one                                                      |
| `Remote`          | –             | run one guest command over ssh (default `verify`)                                                                |
| `Push`            | guest yes     | HTTP PUT of the full DriverStore to a running receiver                                                           |
| `FixMmio`         | host yes      | stop VM → `GuestControlledCacheTypes` + MMIO gaps (does **not** start it)                                        |
| `AddPartition`    | host yes      | stop VM → remove + re-add the GPU partition (does **not** start it)                                              |
| `ShowPowerShell`  | no            | prints one paste-ready line for an action (the host console reorders multi-line pastes)                          |

---

## Requirements

Guest (Hyper-V gen-2 VM with a GPU partition): `bash`, `curl`, `gcc`, `make`, `xz`, `python3`;
kernel headers at `/lib/modules/$(uname -r)/build`; root only for `module install`,
`driverstore install/rollback` and `service install`.

Host: Windows 10 19045 / 11 / Server 2022+, Administrator PowerShell, OpenSSH client (for `Deploy`)
or `curl.exe` (for `Push`).

---

## Traps this repo encodes

- **Never compile `dxgmodule.c` against the WSL branch's `include/linux/hyperv.h`.** That swaps the
  kernel's `struct hv_device` for the branch's; probe reads `hdev->channel` at the wrong offset,
  NULL-derefs while holding `device_mutex`, and `modprobe` parks in `D` — with a matching `vermagic`,
  so every "is this build valid" check passes. `module build` keeps the kernel's own header and adds
  only the two GPU-PV GUIDs; `abi_gates` derives the expected offset from the running kernel each
  time instead of memorising `0x328`.
- **Boot unit ordering**: a self-test `WantedBy=multi-user.target` cannot see a module loaded after
  `graphical.target`; both units are `After=graphical.target` / `WantedBy=graphical.target`.
- **A bundled static ffmpeg newer than the driver** reports
  `Driver does not support the required nvenc API version. Required: 13.1 Found: 13.0` on a healthy
  stack. That is ffmpeg > driver, not GPU-PV. `verify` prefers `/usr/bin/ffmpeg`.
- **`Get-VMGpuPartitionAdapter` with empty Min/Max/Optimal fields is normal** — assignment goes
  through WMI `Msvm_GpuPartitionSettingData` + `AddResourceSettings`, which never fills them.
- **Exit codes through a pipe belong to the pipe** — `ffmpeg … | tail` reports `tail`'s `0` and hides
  a segfault. Every check here runs standalone.
- **A `D`-state `modprobe` is unkillable** and only a cold VM stop/start clears it; MMIO or partition
  changes need the VM stopped, which takes the guest down with it. Both scripts say so before acting.
- **An empty backup directory is not a backup.** A first run that dies before copying leaves one
  behind; reusing it makes `rollback` restore nothing. `driverstore install` only trusts a non-empty
  backup and clears a stale empty one first.
- **`ProcessStartInfo.ArgumentList` does not exist in Windows PowerShell 5.1** — a stock Windows 10
  host needs `scp`, or a `cmd.exe` stdin redirect. `Deploy` uses `scp` and falls back.

---

## Scope and honesty

GPU-PV gives you CUDA, NVENC/NVDEC and `hwaccel cuda`. It does **not** give a real NVIDIA kernel
driver: `/dev/nvidia0`, `/proc/driver/nvidia/version` and `nvidia-persistenced` do not exist, so
anything that detects a GPU that way (many container toolkits' `auto` backends, some installers) will
still say "no GPU". Mesa `d3d12` / VA-API paths need extra setup and are not covered.

Nothing here claims success from a deploy script's `[STATUS: SUCCESS]` line, an exit code, or
`nvidia-smi`. If `cuInit` is not `0`, it is not working, and the tool says so.

---

## Layout

```
gpupv-windows.ps1     Windows host: Check / Deploy(ssh) / Push(http) / FixMmio / AddPartition
gpupv-fnos.sh         the guest tool - ONE file, no repo checkout needed
gpupv.sh              modular entrypoint (development; same code as gpupv-fnos.sh)
lib/                  the parts gpupv-fnos.sh is generated from
src/                  dxg_probe.c, http_put_server.py, ldpreload_trace.c (embedded as base64)
tests/                smoke suite + a Deploy end-to-end test with a fake ssh
tools/                build-single.sh / build-assets.sh (regenerate gpupv-fnos.sh)
docs/quickstart.zh-TW.md 繁體中文上手（症狀 → 修法，可直接貼上的指令）
docs/troubleshooting.md  symptom → layer → fix
docs/success-report.md   the measured case study
```

`gpupv-fnos.sh` is **generated** — edit `lib/*.sh` (or `src/*`), then:

```bash
bash tools/build-assets.sh     # only if you changed src/
bash tools/build-single.sh     # regenerates gpupv-fnos.sh and syntax-checks it
bash tests/smoke.sh --no-build # 39 checks, nothing mutated
```

## Verified on

|       |                                                                                                                     |
| ----- | ------------------------------------------------------------------------------------------------------------------- |
| guest | Debian 12 / fnOS, kernel 6.18.18.c1032-trim, RTX 3060 Ti, driver 591.86 / CUDA 13.1                                 |
| host  | Windows 10 Pro for Workstations 22H2 19045.7184                                                                     |
| tests | `tests/smoke.sh --no-build` 39/39, `tests/e2e_deploy.sh` 10/10, both module branches compile and pass the ABI gates |

## License

MIT — see [LICENSE](LICENSE).
