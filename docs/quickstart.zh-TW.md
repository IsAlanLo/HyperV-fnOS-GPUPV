# 快速上手（繁體中文）

這個 repo 只有兩個檔案需要你動手：

| 檔案                | 跑在哪                                    | 做什麼                                                               |
| ------------------- | ----------------------------------------- | -------------------------------------------------------------------- |
| `gpupv-windows.ps1` | Windows 主機（**系統管理員 PowerShell**） | 主機檢查、GPU 分區 / MMIO、透過 **SSH** 把 guest 整套裝好            |
| `gpupv-fnos.sh`     | Linux guest（fnOS / Debian / Ubuntu…）    | guest 端工具：triage、verify、編譯 dxgkrnl、鋪 DriverStore、開機服務 |

`gpupv-windows.ps1 -Action Deploy` 會：SSH 進去 → 上傳 guest 腳本 → 把主機的
`nv_dispi.inf_amd64_<hash>` 整個資料夾打包成 tar → 上傳 → 在 guest 裡執行 `setup`
（缺模組才編譯、鋪 DriverStore、裝開機服務）→ 把 gate 結果印回 Windows 這邊。

guest 沒有 sshd 也可以：兩邊都支援純 HTTP 傳輸（`-Action Push` ↔ `gpupv-fnos.sh receive`）。

> **sudo 密碼不能「一邊抓輸出、一邊等輸入」。** 如果 ssh 的輸出被接管（例如 `-Capture`），
> 遠端 pty 的內容（含 `password:` 提示）會等到程序結束才一次吐出來，於是程式在等一個你根本
> 看不到的密碼 → 整個卡住。工具因此**只串流、不接管**那一步。
> 想完全不出現遠端提示，改用本機隱藏輸入：
>
> ```powershell
> .\gpupv-windows.ps1 -Action Deploy ... -SudoPrompt
> ```

---

## 一、先判斷壞在哪一層

```powershell
.\gpupv-windows.ps1 -Action Check -VMName fnos
```

```bash
# guest 上
./gpupv-fnos.sh triage
```

四層的症狀互不相同，先定位再動手：

| 症狀                                                            | 層                                                     |
| --------------------------------------------------------------- | ------------------------------------------------------ |
| `nvidia-smi` 顯示 `GPU access blocked by the operating system`  | 主機：分區沒給，或 `/dev/dxg` 不存在                   |
| `nvidia-smi` 顯示 `couldn't communicate with the NVIDIA driver` | guest：`/usr/lib/wsl/lib`（loader）與 payload 的關係錯 |
| `nvidia-smi` 正常但 `cuInit` 崩                                 | **guest：DriverStore 被裁剪**（最常見）                |
| 完全沒有 dxg VMBus 通道                                         | 主機：沒分配 GPU 分區                                  |

---

## 二、最常見的情況：DriverStore 少檔案

兩條指令就判斷完，不要先研究機制：

```bash
ls /usr/lib/wsl/drivers/nv_dispi.inf_amd64_*/ | wc -l            # < 20  → 被裁剪
ls /usr/lib/wsl/drivers/nv_dispi.inf_amd64_*/ | grep -vc '\.so'   # 0     → 確定是裁剪版
```

完整的資料夾約 **150 個檔案**，其中包含 `nvinfo.pb`（約 153 KB）、`nvapi64.dll`、
`nvml.dll`、`nvEncodeAPI64.dll`。只複製 `.so` 會讓 `nvidia-smi` 正常、`cuInit` 直接
SIGSEGV（本案固定崩在 `libcuda+0x516f71` / `si_addr 0x296c`）。

修法（Windows 上）：

```powershell
.\gpupv-windows.ps1 -Action ShowDriverStore     # 確認 files≈153、nvinfo.pb 存在
.\gpupv-windows.ps1 -Action Deploy -VMName fnos -GuestHost 192.168.x.x -GuestUser youruser
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

## 三、驗證：五道 gate，順序不能換

```bash
./gpupv-fnos.sh verify
```

1. `dxgkrnl` 已載入、`/dev/dxg` 存在、**兩個** dxg VMBus 通道都已綁定
2. DriverStore 完整（>150 檔且含非 `.so` 的 metadata）
3. `nvidia-smi` 有回應 —— 只標「monitoring only」，因為它本身不代表能用
4. `cuInit(0) == 0`，並且拿到真實的卡名與 VRAM
5. 真正會用到的編解碼：`h264_nvenc`、`hevc_nvenc`、`h264_cuvid`、`hevc_cuvid`

> RTX 3060 Ti / 3070 / 3080（GA104）**沒有 AV1 編碼器**，`av1_nvenc` 失敗是硬體，
> 不是故障；工具會這樣標註，不會算成失敗。

`cuInit` 不是 0 就是不成功，沒有任何腳本的 `[STATUS: SUCCESS]` 或 exit code 可以取代它。

---

## 四、從零重建 guest（不需要 repo）

`gpupv-fnos.sh` 是**單一檔案**（C 探針、HTTP 接收器、ABI gate 都已內嵌成 base64），
`scp` 一份過去就能跑，連 `/tmp` 都可以：

```bash
scp gpupv-fnos.sh youruser@192.168.x.x:/tmp/
ssh youruser@192.168.x.x
chmod +x /tmp/gpupv-fnos.sh
sudo /tmp/gpupv-fnos.sh setup                 # 工具鏈 + 編譯模組（若缺）+ 開機服務 + 驗證
sudo /tmp/gpupv-fnos.sh setup /tmp/nvstore/nv_dispi.inf_amd64_<hash>
```

`setup` 是 idempotent：已經好的步驟會跳過，重跑安全。

> **fnOS 預設沒有 `gcc`**（只有 `make`）。少了它 kbuild 只會說
> `/bin/sh: 1: gcc: not found … Error 127`，看起來像原始碼壞了。`setup` 會自動用 root 安裝
> 工具鏈；也可以先自己確認／安裝：
>
> ```bash
> ./gpupv-fnos.sh deps              # gcc、xz、bc、bison、flex、libelf/libssl/zlib headers
> sudo ./gpupv-fnos.sh deps --install
> ```

### userland 的兩半，缺一不可

| 路徑                                                      | 內容                                                                  | 來源                   |
| --------------------------------------------------------- | --------------------------------------------------------------------- | ---------------------- |
| `/usr/lib/wsl/lib`                                        | 載入器（`libcuda.so.1.1` 約 171 KB、`libnvidia-ml.so.1`、`libdxcore.so`）+ `nvidia-smi` | ExHyperV 的 `lib/`     |
| `/usr/lib/wsl/drivers/nv_dispi.inf_amd64_<hash>/`         | 真正的 payload（`libcuda.so.1.1` 約 25 MB）+ 資料檔（`nvinfo.pb`）     | 主機的 DriverStore     |

```bash
./gpupv-fnos.sh loaders status                  # 兩半 + ld.so 搜尋路徑
sudo ./gpupv-fnos.sh loaders install <ExHyperV>/lib
```

只有 payload 沒有載入器 → `libcuda.so.1 missing`；只有載入器而 payload 被裁剪 → `nvidia-smi`
正常但 `cuInit` 崩。`verify` 會分開評分，訊息才指得出是哪一半。

> 全新 guest 上什麼都還沒部署，資料夾名稱只能來自主機那一份，所以 `setup` 請傳**資料夾本身**
> （`.../nv_dispi.inf_amd64_<hash>`），或加 `--name nv_dispi.inf_amd64_<hash>`。

---

## 五、出問題時

```bash
./gpupv-fnos.sh doctor      # DriverStore 檔案數 → ABI gate → payload 是否真的被 dlopen → D 狀態卡住的 probe
./gpupv-fnos.sh report      # 產一份 markdown 證據檔，可直接貼到 issue
```

`doctor` 第 4 步（`LD_DEBUG=files` 有沒有出現 `/usr/lib/wsl/drivers/...`）若為 0，
代表問題在 payload 之前，換任何 lib 版本都不會好。

完整的「症狀 → 層 → 修法」對照表：`docs/troubleshooting.md`
本案實測過程（含 6 個被推翻的假設）：`docs/success-report.md`

---

## 六、幾個一定會踩到的坑

- **不要用 WSL 分支的 `include/linux/hyperv.h` 去編 `dxgmodule.c`**。`struct hv_device`
  會換掉，probe 讀錯 `hdev->channel` 偏移 → NULL deref（`address: 0x34`）→ 佔著
  `device_mutex` → `modprobe` 卡在 `D`，而且 `vermagic` 完全正確，所有「這顆 .ko 對不對」
  檢查都會通過。本工具只補兩個 GPU-PV GUID，不動內核標頭，並且每次從**執行中的內核**
  重新推算預期偏移。
- **自檢 unit 掛 `multi-user.target` 看不到 `graphical.target` 之後才載入的模組**，
  兩個 unit 都用 `After=graphical.target` / `WantedBy=graphical.target`。
- **比驅動新的 ffmpeg**（自帶 9.x）會報
  `Required: 13.1 Found: 13.0`，那是 ffmpeg 比驅動新，不是 GPU-PV 壞掉。`verify` 優先用
  `/usr/bin/ffmpeg`。
- **`Get-VMGpuPartitionAdapter` 的 Min/Max/Optimal 是空的屬正常**，實際分配走 WMI
  `Msvm_GpuPartitionSettingData` + `AddResourceSettings`，本來就不會填。
- **`D` 狀態的 `modprobe` 殺不掉**，只能冷關機再開；改 MMIO / 分區都必須先關機，
  guest 會跟著下線。
- **空目錄不算備份**：第一次安裝若在複製前就中斷會留下空目錄，之後 `rollback`
  會還原成空的。工具只信任非空備份，並會先清掉空的殘留。
- **Windows PowerShell 5.1 沒有 `ProcessStartInfo.ArgumentList`**，所以 `Deploy` 用 `scp`，
  `scp` 不存在時退回 `cmd.exe` 的 stdin 重導。
