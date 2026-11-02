# fnOS Hyper-V GPU-PV 完整成功報告

## 一、最終驗證結果（重開機後實測）

### 系統狀態

```
kernel        6.18.18.c1032-trim
uptime        up 7 minutes
dxgkrnl       178920E805823DAC2C7D763      ← dkms 版，非測試版
VMBus 通道    0020f27b-...=state3, 711dad3a-...=state3   ← 兩個 dxg 通道都綁定
PCI 樁設備    Microsoft Basic Render Driver [1414:008e]
/dev/dxg      crw-rw-rw-  10, 262
driverstore   153 files / 135 non-so
nvidia-smi    591.86 / CUDA 13.1
```

### CUDA

```
cuInit              0
cuDeviceGetCount    0 -> 1
cuDeviceGetName     NVIDIA GeForce RTX 3060 Ti
cuDeviceTotalMem    8191 MiB
cuDriverGetVersion  13010  (CUDA 13.1)
```

### 編碼 / 解碼（發行版 ffmpeg 8.1.1-mediasrv）

| 功能       | 指令                         | 結果                                          |
| ---------- | ---------------------------- | --------------------------------------------- |
| H.264 編碼 | `-c:v h264_nvenc -preset p4` | rc=0，1080p 5 秒 → 1,588,229 bytes            |
| HEVC 編碼  | `-c:v hevc_nvenc -preset p4` | rc=0，1080p 5 秒 → 1,571,664 bytes            |
| H.264 解碼 | `-c:v h264_cuvid`            | rc=0                                          |
| HEVC 解碼  | `-c:v hevc_cuvid`            | rc=0                                          |
| AV1 解碼   | `-c:v av1_cuvid`             | rc=0                                          |
| AV1 編碼   | `-c:v av1_nvenc`             | **不支援**（GA104 硬體無 AV1 編碼器，非故障） |

### NVML

```
NVIDIA GeForce RTX 3060 Ti, 591.86, 8192 MiB, 646 MiB used, 11% util, 51°C
encoder.stats: sessionCount=1, averageFps=31
```

---

## 二、根因分析

### 2.1 為什麼少 135 個檔案會讓 CUDA 崩潰

WSL 的 CUDA 是四層堆疊：

```
應用 → libcuda.so.1 (loader, 175 KB)
       ↓ dlopen
       libcuda.so.1.1 (真 payload, 24.7 MB)
       ↓ dlopen
       libdxcore.so → D3DKMTOpenAdapterFromLuid → /dev/dxg
       ↓ 按目錄約定讀取
       /usr/lib/wsl/drivers/nv_dispi.inf_amd64_<hash>/nvinfo.pb 等 135 個資料檔
```

`nvinfo.pb` 是 NVIDIA 的 GPU 資訊描述檔（153,562 bytes）。`libcuda` 在建構 adapter 物件時要靠它填入欄位。缺它，某個指標欄位保持未初始化，於是出現：

```asm
; libcuda.so.1.1+0x516f6d
mov    0x20(%r15),%rax      ; rax = 0x30  ← 該是位址，實際是小整數
movb   $0x0,0x293c(%rax)    ; 寫到 0x30 + 0x293c = 0x296c → SIGSEGV
```

而 `libnvdxgdmal.so.1(dxgdmalEnumAdapters+0x44c)` 的 `call *%rbx` 會拿到 stack 位址當函式指標，也是同一個未初始化結構的下游症狀。

### 2.2 正確的診斷順序

```bash
# 第一步，永遠先看這個
ls /usr/lib/wsl/drivers/nv_dispi.inf_amd64_*/ | wc -l              # < 20 → 被裁剪過
ls /usr/lib/wsl/drivers/nv_dispi.inf_amd64_*/ | grep -vc '\.so'    # 0    → 確定是裁剪版
```

兩條都命中，就是這個 bug，不用再查內核、協議、庫版本。

主機端對照（PowerShell）：

```powershell
(Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf_amd64_*' -File).Count
# 正確值 ≈ 153
```

---

## 三、完整部署步驟（從零重建）

### 3.1 主機（Windows）端

**① 確認 GPU 分區已分配**

```powershell
Get-VMGpuPartitionAdapter -VMName <VM名字> | Select-Object VMName, InstancePath
```

`InstancePath` 應含 `VEN_10DE`。

**② 設定 MMIO 與快取**

```powershell
Set-VM -GuestControlledCacheTypes $true -VMName <VM名字>
Set-VM -HighMemoryMappedIoSpace 32GB -VMName <VM名字>
Set-VM -LowMemoryMappedIoSpace 1GB -VMName <VM名字>
```

**③ 記錄主機資訊（本機實測值）**

```
OS        Windows 10 Pro for Workstations 22H2  UBR=7184
dxgkrnl.sys  10.0.19041.7181
GPU       NVIDIA GeForce RTX 3060 Ti
Driver    32.0.15.9186  (= 591.86),  2026-01-20
```

**④ 找出完整 DriverStore 目錄**

```powershell
$d=(Get-CimInstance Win32_VideoController | Where-Object { $_.AdapterCompatibility -match "NVIDIA" }).InstalledDisplayDrivers -split ',' | Select-Object -First 1 | Split-Path -Parent
"dir=$d"
"files=$((Get-ChildItem $d -File).Count)"
$n=Get-Item "$d\nvinfo.pb" -ErrorAction SilentlyContinue
"nvinfo.pb=" + $(if($n){"$($n.Length) bytes"}else{"MISSING"})
```

**期望輸出**：

```
dir=C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf_amd64_adc55ecfca814224
files=153
nvinfo.pb=153562 bytes
```

> ⚠️ **這是整個流程最關鍵的一步**。`files` 必須是 150 以上。如果是十幾個，代表主機驅動本身不完整，要先重裝顯卡驅動。

### 3.2 傳輸到 guest

如果 guest 沒有共用目錄，用 HTTP PUT 接收端（`http_put_server.py`）：

```bash
# guest 上（用你自己的帳號即可，不需要 root）
mkdir -p /root/gpupv/nvstore
python3 <skill>/scripts/http_put_server.py /root/gpupv/nvstore 8899
```

```powershell
# Windows 上（單行貼上）
Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf_amd64_adc55ecfca814224' -File | ForEach-Object { $r = curl.exe -s --max-time 300 -T $_.FullName 'http://<guest-ip>:8899/'; if ($r -notmatch '^ok') { "FAIL: $($_.Name)" } }; "done"
```

每個檔會回 `ok <檔名> <bytes>`，用來核對數量。

### 3.3 guest 端（fnOS）

**① 部署 dxgkrnl 模組**

```bash
# 用 ExHyperV 的 fnOS 腳本，或手動 DKMS
sudo bash fnOS-1.1.23-6.12.18-trim-GPU-PV.sh
```

驗證：

```bash
lsmod | grep dxgkrnl
ls -l /dev/dxg
for d in /sys/bus/vmbus/devices/*/; do c=$(cat $d/class_id 2>/dev/null); case "$c" in *6e382d18*|*dde9cbc0*) echo "$(basename $d) state=$(cat $d/state)";; esac; done
```

**② 鋪完整 DriverStore（關鍵步驟）**

```bash
P=/usr/lib/wsl/drivers/nv_dispi.inf_amd64_adc55ecfca814224
BK=/root/nvstore-full-backup

# 備份
mkdir -p $BK && cp -a $P $BK/nv_dispi

# 複製完整版
cp -a /root/gpupv/nvstore/. $P/
chmod -R a+r $P

# 驗證
ls $P | wc -l              # 必須是 153
ls $P | grep -vc '\.so'    # 必須是 135
```

**③ 確認 ld.so 設定**

```bash
cat /etc/ld.so.conf.d/ld.wsl.conf
# /usr/lib/wsl/lib
# /usr/lib/wsl/drivers
sudo ldconfig
```

**④ 修 loader 腳本的硬編核心版本**

```bash
# 原腳本有 bug：KERNEL="6.12.18-trim" 寫死
sudo sed -i 's/^KERNEL=.*/KERNEL="$(uname -r)"/' /usr/local/bin/load_dxg_driver.sh
grep -n '^KERNEL=' /usr/local/bin/load_dxg_driver.sh
```

**⑤ 驗證 CUDA**

```bash
python3 -c '
import ctypes
l = ctypes.CDLL("/usr/lib/wsl/lib/libcuda.so.1")
print("cuInit", l.cuInit(0))
n = ctypes.c_int(); l.cuDeviceGetCount(ctypes.byref(n)); print("count", n.value)
d = ctypes.c_int(); l.cuDeviceGet(ctypes.byref(d), 0)
b = ctypes.create_string_buffer(128); l.cuDeviceGetName(b, 128, d); print(b.value.decode())
m = ctypes.c_size_t(); l.cuDeviceTotalMem_v2(ctypes.byref(m), d); print(m.value//1048576, "MiB")
'
```

`cuInit 0` 就是通了。

**⑥ 驗證編解碼**

> **必須用發行版 ffmpeg**，不要用自帶的新版靜態建置。fnOS 的是 `/usr/trim/lib/mediasrv/ffmpeg`（8.1.1-mediasrv），`/usr/bin/ffmpeg` 是指向它的符號連結。
>
> 用 ffmpeg 9.x 會得到 `Driver does not support the required nvenc API version. Required: 13.1 Found: 13.0` —— 那是 ffmpeg 比驅動新，不是 GPU-PV 故障。

```bash
# 編碼
/usr/bin/ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=1920x1080:rate=30:duration=5 -c:v h264_nvenc -preset p4 -y /tmp/t.mp4; echo "rc=$?"

# 解碼
/usr/bin/ffmpeg -hide_banner -c:v h264_cuvid -i /tmp/t.mp4 -f null - 2>&1 | tail -2; echo "rc=$?"
```

---

### 額外驗證過但無效的方向

- 換成 WSL 3.0.3 內附的 clang 14 版 `libdxcore`/`libd3d12`（與 ExHyperV 提供的逐位元組相同）→ `D3D12CreateDevice` 結果完全一樣
- 9 個缺失的 `D3DKMT*` 符號用 `E_NOTIMPL` stub 補上 → 崩點不變
- `ld.so.conf` 兩種搜尋順序（`drivers` 優先 / `lib` 優先）→ 兩者都崩
- 專案自己的 fnOS 腳本（ExHyperV 官方版 3.8.0 vs 使用者修改版 3.7.0）→ 兩者都只 `cp` 到 `/usr/lib/wsl/lib`，都不碰 `drivers/`

---

## 附錄：最終功能清單

| 功能                | 狀態 | 備註                                                      |
| ------------------- | ---- | --------------------------------------------------------- |
| NVML (`nvidia-smi`) | ✅    | 591.86 / CUDA 13.1 / 8192 MiB                             |
| CUDA (`cuInit`)     | ✅    | 1 個裝置，RTX 3060 Ti                                     |
| H.264 NVENC         | ✅    | 1080p p4 preset                                           |
| HEVC NVENC          | ✅    | 1080p p4 preset                                           |
| H.264 CUVID         | ✅    | 16.5x 解碼速度                                            |
| HEVC CUVID          | ✅    | 14.2x 解碼速度                                            |
| AV1 CUVID           | ✅    | GA104 支援 AV1 解碼                                       |
| AV1 NVENC           | ❌    | GA104 無 AV1 編碼器（硬體限制，非故障）                   |
| Mesa d3d12 / OpenGL | ⚠️    | 需 `GALLIUM_DRIVER=d3d12` + video/render 群組；非本案重點 |
| VA-API              | ⚠️    | 同上，未完整驗證                                          |
| 重開機自動生效      | ✅    | dkms 模組 + 完整 driverstore                              |
