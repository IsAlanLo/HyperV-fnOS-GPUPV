# HyperV-fnos-GPUPV

Hyper-V **GPU-PV** 用於 fnOS HyperV vm

已在 fnOS 1.20.0505 和 Windows 10 22h2 RTX 3060 Ti/RTX 5070 上測試

```
Windows 主機                            Linux guest (fnOS / Debian / Ubuntu)
──────────────────────────────────      ──────────────────────────────────────
gpupv-windows.ps1                       gpupv-fnos.sh
  Check        看現況                      triage     哪一層壞了（不用 root）
  Auto         一行裝到好                  verify     五道 gate
  Deploy       同上，指定參數               setup      工具鏈 + 模組 + driverstore + 服務
  ShowDriverStore / Push / Remote         driverstore / loaders / module / service …
  FixMmio / AddPartition                  receive    HTTP 接收（沒有 sshd 時）
```

---

## 快速上手

以**系統管理員 PowerShell** 執行：

```powershell
.\gpupv-windows.ps1 -Action Auto -GuestUser <guest 帳號> -GuestHost <guest ip> -SudoPrompt
```

`Auto` = 自動偵測 VM → 自動取得 guest IP（有時候取不到，需要加上 `-GuestHost ip`）→ 缺 GPU 分區就自己分配（含 MMIO）並冷啟動 →
上傳 guest 腳本與 `lxss\lib` loader → 上傳完整 DriverStore → 在 guest 執行 `setup` → 跑 gate。

只會問你：

1. guest 的 user 和 sudo 密碼（~~要打好多次~~）
2. 若需要分配分區：`Type YES to continue`（VM 會被關機再冷啟動）

不用記任何旗標。若 VM 有多台、或 Hyper-V 拿不到 IP，它會**列出清單要你指定**。

`Deploy` 實際做的事：SSH 進去 → 上傳 guest 腳本 → 把主機的 `nv_dispi.inf_amd64_<hash>` 整個資料夾打包成 tar → 上傳 → 在 guest 執行 `setup`（缺模組才編譯、鋪 DriverStore、裝開機服務）→ 把 gate 結果印回 Windows。

guest 沒有 sshd 也可以：兩邊都支援純 HTTP 傳輸（`-Action Push` ↔ `gpupv-fnos.sh receive`）。

> **sudo 密碼不能「一邊抓輸出、一邊等輸入」。** 如果 ssh 的輸出被接管（例如 `-Capture`），遠端 pty 的內容（含 `password:` 提示）會等到程序結束才一次吐出來，程式就會卡在等一個你看不到的密碼。工具因此**只串流、不接管**那一步。想完全不出現遠端提示，改用本機隱藏輸入：`-SudoPrompt`。

---

## 這個 repo 有什麼

| 檔案                | 跑在哪                                | 作用                                                           |
| ------------------- | ------------------------------------- | -------------------------------------------------------------- |
| `gpupv-windows.ps1` | Windows 主機（系統管理員 PowerShell） | 主機檢查、GPU 分區/MMIO 修復、把 guest 整套裝好（SSH 或 HTTP） |
| `gpupv-fnos.sh`     | Linux guest                           | 單一檔案：診斷、編譯模組、鋪 payload/loader、開機服務、驗證    |

**不需要 ExHyperV 或任何第三方工具。** 兩個目錄的來源都是 Windows 本身：

| 半邊    | guest 路徑                                        | 主機來源                                           |
| ------- | ------------------------------------------------- | -------------------------------------------------- |
| loaders | `/usr/lib/wsl/lib`                                | `C:\Windows\System32\lxss\lib`                     |
| payload | `/usr/lib/wsl/drivers/nv_dispi.inf_amd64_<hash>/` | `C:\Windows\System32\DriverStore\FileRepository\…` |

---

## 自動判斷的部分（傻瓜化）

| 以前要自己填            | 現在                                                                        |
| ----------------------- | --------------------------------------------------------------------------- |
| VM 名稱                 | 只有一台就自動用；多台會列出讓你選                                          |
| guest IP                | 從 Hyper-V 整合服務取得；拿不到才要你給                                     |
| DriverStore 的 `<hash>` | 從 `Win32_VideoController.InstalledDisplayDrivers` 解析                     |
| loader 目錄             | 固定解析 `%SystemRoot%\System32\lxss\lib`                                   |
| GPU 分區 / MMIO         | `Auto`／`-FixPartition` 自動分配，含冷啟動與等待 SSH 回來                   |
| 核心版本（開機腳本）    | 一律 `KERNEL="$(uname -r)"`                                                 |
| 編譯工具鏈              | 缺 `gcc`/`headers` 自動 `apt-get`（非 apt 系統會列出對應指令）              |
| 重新打包單檔            | `tools/build-single.sh` 產生 `gpupv-fnos.sh`（已內含 C 探針與 HTTP 接收器） |

---

## 手動分步（想看清楚每一步時）

```powershell
# 1. 主機現況（唯讀）
.\gpupv-windows.ps1 -Action Check

# 2. 主機端兩份來源是否完整
.\gpupv-windows.ps1 -Action ShowDriverStore

# 3. 需要時才單獨修分區（會關機 + 冷啟動）
.\gpupv-windows.ps1 -Action AddPartition

# 4. 安裝（等同 Auto，但不由 Auto 幫你補旗標）
.\gpupv-windows.ps1 -Action Deploy -FixPartition
```

guest 端（`gpupv-fnos.sh` 是單檔，`scp` 過去就能跑）：

```bash
./gpupv-fnos.sh triage        # 哪一層壞了
./gpupv-fnos.sh verify        # 五道 gate
sudo ./gpupv-fnos.sh setup    # 工具鏈 + 模組 + driverstore + 開機服務 + 驗證
```

沒有 SSH 時：

```powershell
.\gpupv-windows.ps1 -Action Push -GuestUrl http://192.168.x.x:8899/
```

```bash
# guest 先開接收端
./gpupv-fnos.sh receive /tmp/nvstore 8899
# 檔案落地後
./gpupv-fnos.sh driverstore compare /tmp/nvstore          # 同一個 build？還是子集？
sudo ./gpupv-fnos.sh driverstore install /tmp/nvstore     # overlay，先備份，裝完立刻測 cuInit
sudo ./gpupv-fnos.sh service install --selftest           # 開機自動載入 + 開機自檢
./gpupv-fnos.sh verify
```

> `compare` 若輸出 **SUBSET**，代表你要裝的那份比現有的還少 —— 不要裝，那是反向操作。

---

## 驗證：五道 gate（`verify`）

順序不能換：

1. `dxgkrnl` 已載入、`/dev/dxg` 存在、**兩個** dxg VMBus 通道都已綁定
2. userland 兩半齊備：`/usr/lib/wsl/lib` 的 loader + 完整的 DriverStore payload（>150 檔且含非 `.so` 的 metadata）
3. `nvidia-smi` 有回應（**只代表監控路徑可用**，標為 monitoring only）
4. `cuInit(0) == 0`，並取得真實卡名與 VRAM
5. 實際會用到的編解碼：`h264_nvenc`、`hevc_nvenc`、`h264_cuvid`、`hevc_cuvid`

`av1_nvenc` 在 GA104（3060 Ti / 3070 / 3080）失敗屬硬體限制，不算故障。

**`nvidia-smi` 正常不等於可用**，唯一驗收是 `cuInit(0) == 0` 加上真實編解碼 rc=0。沒有任何腳本的 `[STATUS: SUCCESS]` 或 exit code 可以取代它。

---

## 排錯

### 一、先判斷壞在哪一層

```powershell
.\gpupv-windows.ps1 -Action Check -VMName fnos
```

```bash
./gpupv-fnos.sh triage   # guest 上
```

| 症狀                                                            | 層                                                     |
| --------------------------------------------------------------- | ------------------------------------------------------ |
| `nvidia-smi` 顯示 `GPU access blocked by the operating system`  | 主機：分區沒給，或 `/dev/dxg` 不存在                   |
| `nvidia-smi` 顯示 `couldn't communicate with the NVIDIA driver` | guest：`/usr/lib/wsl/lib`（loader）與 payload 的關係錯 |
| `nvidia-smi` 正常但 `cuInit` 崩                                 | **guest：DriverStore 被裁剪**（最常見）                |
| 完全沒有 dxg VMBus 通道                                         | 主機：沒分配 GPU 分區                                  |

### 二、最常見：DriverStore 少檔案

兩條指令就能判斷：

```bash
ls /usr/lib/wsl/drivers/nv_dispi.inf_amd64_*/ | wc -l            # < 20  → 被裁剪
ls /usr/lib/wsl/drivers/nv_dispi.inf_amd64_*/ | grep -vc '\.so'   # 0     → 確定是裁剪版
```

完整的資料夾約 **150 個檔案**，包含 `nvinfo.pb`（約 153 KB）、`nvapi64.dll`、`nvml.dll`、`nvEncodeAPI64.dll`。只複製 `.so` 會讓 `nvidia-smi` 正常、`cuInit` 直接 SIGSEGV（固定崩在 `libcuda+0x516f71` / `si_addr 0x296c`）。

修法（Windows 上）：

```powershell
.\gpupv-windows.ps1 -Action ShowDriverStore     # 確認 files≈150、nvinfo.pb 存在
.\gpupv-windows.ps1 -Action Deploy -VMName fnos -GuestHost 192.168.x.x -GuestUser youruser -FixPartition
```

`-FixPartition`：VM 沒有 GPU 分區時，Deploy 會自己關機 → 分配分區與 MMIO → 冷啟動 → 等 SSH 回來 → 繼續安裝。不加這個旗標則會在上傳前停下並告訴你要跑哪一行指令。

### 三、userland 的兩半，缺一不可

| 路徑                                              | 內容                                                                                    | 來源                           |
| ------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------ |
| `/usr/lib/wsl/lib`                                | 載入器（`libcuda.so.1.1` 約 171 KB、`libnvidia-ml.so.1`、`libdxcore.so`）+ `nvidia-smi` | `C:\Windows\System32\lxss\lib` |
| `/usr/lib/wsl/drivers/nv_dispi.inf_amd64_<hash>/` | 真正的 payload（`libcuda.so.1.1` 約 25 MB）+ 資料檔（`nvinfo.pb`）                      | 主機的 DriverStore             |

```bash
./gpupv-fnos.sh loaders status                  # 兩半 + ld.so 搜尋路徑
sudo ./gpupv-fnos.sh loaders install <從 C:\Windows\System32\lxss\lib 複製過來的目錄>
```

只有 payload 沒有載入器 → `libcuda.so.1 missing`；只有載入器而 payload 被裁剪 → `nvidia-smi` 正常但 `cuInit` 崩。`verify` 會分開評分，訊息才指得出是哪一半。

### 四、常見錯誤與真正的原因

| 你看到                                                                                      | 其實是                                                                                                                                          |
| ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `A parameter cannot be found that matches parameter name 'FixPartition'`                    | 磁碟上是舊版腳本。先跑 `-Action Version`，應該看到 `1.1.2`                                                                                      |
| `host refused HighMemoryMappedIoSpace=256GB : ... Input string was not in a correct format` | 已修：`Set-VM` 要的是位元組數，不是 `"256GB"` 字串（1.1.1 起會先解析）                                                                          |
| `You cannot call a method on a null-valued expression`                                      | 已修：`wc -l` 的輸出帶前導空白，解析前要先 trim（1.1.1）                                                                                        |
| `gpupv-fnos.sh: line N: b: unbound variable`                                                | 已修：`local b` 宣告但未賦值就讀取，`set -u` 會中止函式（1.1.2）。這也是為什麼它會一邊報錯一邊印 OK                                             |
| `tar: /tmp/gpupv/nvstore.tar: Cannot open` 搭配 `-SkipDriverStore`                          | 已修：跳過上傳時不會再去解包不存在的檔案，改為直接找 guest 上已部署的 payload（1.1.2）                                                          |
| `dxg VMBus channels (0)`                                                                    | 這台 VM 沒有 GPU 分區（`/dev/dxg` 是模組載入時就建立的，不代表有 adapter）。用 `-Action Auto` 或 `AddPartition`                                 |
| `no loaders at /usr/lib/wsl/lib`                                                            | loader 沒鋪。`Auto`/`Deploy` 會自動從 `lxss\lib` 送                                                                                             |
| `nvidia-smi` 有表格但 `cuInit` 崩                                                           | DriverStore 被裁剪（少了 `nvinfo.pb` 等 metadata）                                                                                              |
| `gcc: not found` / `Error 127`                                                              | 缺編譯器（fnOS 預設只有 `make`，沒有 `gcc`）。`sudo ./gpupv-fnos.sh deps --install`                                                             |
| sudo 提示看不到                                                                             | 已修：privileged 步驟跑在 guest 的 pty（`script -q -e`）上，提示會即時 flush。若 console 仍吃不到，用 `-SudoPrompt`（本機隱藏輸入 → `sudo -S`） |
| `av1_nvenc` 失敗                                                                            | GA104 沒有 AV1 編碼器，正常                                                                                                                     |

### 五、診斷工具

```bash
./gpupv-fnos.sh doctor      # DriverStore 檔案數 → ABI gate → payload 是否真的被 dlopen → D 狀態卡住的 probe
./gpupv-fnos.sh report      # 產一份 markdown 證據檔，可直接貼到 issue
```

`doctor` 第 4 步（`LD_DEBUG=files` 有沒有出現 `/usr/lib/wsl/drivers/...`）若為 0，代表問題在 payload 之前，換任何 lib 版本都不會好。

完整的「症狀 → 層 → 修法」對照表：`docs/troubleshooting.md`；實測過程（含 6 個被推翻的假設）：`docs/success-report.md`

### 六、一定會踩到的坑

- **不要用 WSL 分支的 `include/linux/hyperv.h` 去編 `dxgmodule.c`**。`struct hv_device` 會換掉，probe 讀錯 `hdev->channel` 偏移 → NULL deref（`address: 0x34`）→ 佔著 `device_mutex` → `modprobe` 卡在 `D`，而且 `vermagic` 完全正確，所有「這顆 .ko 對不對」檢查都會通過。本工具只補兩個 GPU-PV GUID，不動內核標頭，並且每次從**執行中的內核**重新推算預期偏移。
- **自檢 unit 掛 `multi-user.target` 看不到 `graphical.target` 之後才載入的模組**，兩個 unit 都用 `After=graphical.target` / `WantedBy=graphical.target`。
- **比驅動新的 ffmpeg**（自帶 9.x）會報 `Required: 13.1 Found: 13.0`，那是 ffmpeg 比驅動新，不是 GPU-PV 壞掉。`verify` 優先用 `/usr/bin/ffmpeg`。
- **`Get-VMGpuPartitionAdapter` 的 Min/Max/Optimal 是空的屬正常**，實際分配走 WMI `Msvm_GpuPartitionSettingData` + `AddResourceSettings`，本來就不會填。
- **`D` 狀態的 `modprobe` 殺不掉**，只能冷關機再開；改 MMIO / 分區都必須先關機，guest 會跟著下線。
- **空目錄不算備份**：第一次安裝若在複製前就中斷會留下空目錄，之後 `rollback` 會還原成空的。工具只信任非空備份，並會先清掉空的殘留。
- **Windows PowerShell 5.1 沒有 `ProcessStartInfo.ArgumentList`**，所以 `Deploy` 用 `scp`，`scp` 不存在時退回 `cmd.exe` 的 stdin 重導。

---

## 從零重建 guest（不需要 repo）

`gpupv-fnos.sh` 是**單一檔案**（C 探針、HTTP 接收器、ABI gate 都已內嵌成 base64），`scp` 一份過去就能跑，連 `/tmp` 都可以：

```bash
scp gpupv-fnos.sh youruser@192.168.x.x:/tmp/
ssh youruser@192.168.x.x
chmod +x /tmp/gpupv-fnos.sh
sudo /tmp/gpupv-fnos.sh setup                 # 工具鏈 + 編譯模組（若缺）+ 開機服務 + 驗證
sudo /tmp/gpupv-fnos.sh setup /tmp/nvstore/nv_dispi.inf_amd64_<hash>
```

`setup` 是 idempotent：已經好的步驟會跳過，重跑安全。它會自動用 root 安裝工具鏈；也可以先自己確認／安裝：

```bash
./gpupv-fnos.sh deps              # gcc、xz、bc、bison、flex、libelf/libssl/zlib headers
sudo ./gpupv-fnos.sh deps --install
```

> 全新 guest 上什麼都還沒部署，資料夾名稱只能來自主機那一份，所以 `setup` 請傳**資料夾本身**（`.../nv_dispi.inf_amd64_<hash>`），或加 `--name nv_dispi.inf_amd64_<hash>`。

---

## 其他 action

| action                     | 改動       | 做什麼                                                                       |
| -------------------------- | ---------- | ---------------------------------------------------------------------------- |
| `Auto`                     | host+guest | 一行裝到好（含分區修復）                                                     |
| `Check`                    | 無         | VM 設定、分區、可分配 GPU、驅動、policy、scheduler、DriverStore、loader 集合 |
| `ShowDriverStore`          | 無         | 解析並檢查完整 `nv_dispi` 目錄                                               |
| `Deploy`                   | guest      | SSH 上傳 + 安裝 + 驗證                                                       |
| `Push`                     | guest      | HTTP PUT（guest 端先跑 `receive`）                                           |
| `Remote`                   | –          | 在 guest 跑一行指令（`-AsRoot`、`-SudoPrompt`）                              |
| `FixMmio` / `AddPartition` | host       | 關機 → MMIO + 分區 → 冷啟動                                                  |
| `ShowPowerShell`           | 無         | 印出可貼上的單行指令                                                         |
| `Version`                  | 無         | 印版本（「找不到參數」通常是磁碟上是舊檔）                                   |

---

## 需求

**主機**：Windows 10 22H2 / 11 / Server 2022+、已啟用 Hyper-V、OpenSSH Client（`Deploy`/`Auto`）或 `curl.exe`（`Push`）、`tar.exe`（Win10 1803+ 內建）。`Auto`/`Deploy -FixPartition`/`FixMmio`/`AddPartition` 需要**管理員**權限；單純檢查不需要。

**Guest**：Hyper-V 第 2 代 VM、`bash`、`curl`、`python3`、kernel headers（`/lib/modules/$(uname -r)/build`）。`gcc`/`make`/`xz`/`bc`/`bison`/`flex` 由 `setup` 自動安裝。

---

## 已驗證

| 項目  | 內容                                                                                                                       |
| ----- | -------------------------------------------------------------------------------------------------------------------------- |
| guest | fnOS 1.20.0505，kernel 6.18.18.c1032-trim；RTX 3060 Ti（driver 591.86 / CUDA 13.1）、RTX 5070（driver 610.74 / CUDA 13.3） |
| host  | Windows 10 Pro for Workstations 22H2 19045 / Windows 10 Pro 22H2 19045                                                     |
| ✅     | `dkms status` 顯示模組已安裝                                                                                               |
| ✅     | `lsmod \| grep dxgkrnl` 模組已載入                                                                                         |
| ✅     | Codec                                                                                                                      |
| ✅     | CUDA/OpenCL                                                                                                                |
| ❌     | fnOS 相冊/影視 GPU 識別，建議使用第三方 app，例如 Jellyfin                                                                 |

## 開發

```bash
bash tools/build-assets.sh     # src/* 有改才需要
bash tools/build-single.sh     # 重新產生 gpupv-fnos.sh（會做 bash -n 檢查）
bash tests/smoke.sh --no-build # 47 項，不動系統
bash tests/e2e_deploy.sh       # 25 項，用假 ssh 跑完整 Deploy
make check                     # 語法 + PowerShell parser + pty probe
```

## 授權

MIT — 見 [LICENSE](LICENSE)。

## 參考資料 & 鳴謝

- [microsoft/WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel) — `dxgkrnl` 原始碼
- [microsoft/libdxg](https://github.com/microsoft/libdxg) — uapi 標頭
- [Justsenger/ExHyperV](https://github.com/Justsenger/ExHyperV) — GPU-PV 的前置研究與 Windows 端分配方式
- [MBRjun/dxgkrnl-dkms-lts](https://github.com/MBRjun/dxgkrnl-dkms-lts) — 早期相容性標頭
