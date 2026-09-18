# StarListener (Mac 語音喚醒詞常駐守護進程)

StarListener 係一個專為 macOS 設計、極度輕量（CPU 佔用僅 ~2%–3%）嘅原生 Menu Bar 守護應用程式（Daemon App）。
佢常駐喺 macOS 狀態列（Menu Bar），持續監聽唯一喚醒詞 **「Stella」**（以及 Hello Stella / Hi Stella / Hey Stella）。

---

## 🌟 核心視覺與觸發體驗 (Visual & Audio Feedback)

* **待機狀態 (Idle)**：螢幕右上角 Menu Bar（時鐘附近）常駐顯示單色星星 **`☆`**。
* **喚醒觸發 (Triggered)**：當聽到「Stella」時，星星瞬間點亮為璀璨發光的 **`🌟`**，並同步播放系統提示音 `Tink`。
* **重置狀態 (Reset)**：0.8 秒後自動恢復為待機狀態的 **`☆`**，防抖機制（Debounce 0.4s）避免重複觸發。

---

## ⚡ 超低功耗架構 (Low Power & Efficiency Design)

| 指標 | 傳統連續語音辨識 (Paraformer ASR) | 本專案專用門鈴引擎 (Zipformer KWS) |
| :--- | :--- | :--- |
| **CPU 佔用** | **~103.7%** (全速霸佔 1 個 CPU 核心，發熱耗電) | **~2.0% – 3.0%** (單線程能效核心微頻運作) |
| **記憶體佔用** | 477 MB | **~80 MB** (節省 83%) |
| **運作模型** | 228MB 中粵英三語 ASR | **3.3M 超輕量 Zipformer Transducer KWS** |
| **電池續航** | MacBook 拔電掉電明顯 | **完全 0 影響**，拔電常駐 24/7 無感知 |

---

## 🧩 關鍵技術發現與底層不可變規範 (Critical Discoveries & Invariants)

> ⚠️ **所有開發者與 AI Agent 請注意：在維護或重構代碼時，絕對不可違反以下 6 大不變量！**

### 1. 輸出管道鐵律：JSON 只輸出在 `STDERR`，不可與管道分離
* `sherpa-onnx-keyword-spotter-microphone` 內部將檢測成功的 JSON（`{"start_time": ..., "keyword": ...}`）**唯一輸出到 STDERR**，而非 STDOUT。
* 在 `src/main.swift` 中，**必須**將 `process.standardError` 連接到讀取管道 `pipe`：
  ```swift
  process?.standardOutput = pipe
  process?.standardError = pipe // ⚠️ 絕不可移除或分開！
  ```

### 2. 二進制區分鐵律
* **即時麥克風串流**：必須使用 `bin/sherpa-onnx-keyword-spotter-microphone`。
* **離線 WAV 單元測試**：使用 `bin/sherpa-onnx-keyword-spotter`（只接收 wav 檔案，不可用於即時收音）。

### 3. 廣東話聲學對齊真相 (Cantonese Phoneme Mapping)
* 模型詞表 `tokens.txt` 採用聲母 + 帶聲調韻母建模。
* **實測突破**：真人口語廣東話「星仔」(sing1 zai2) 在該聲學模型中被精準對齊為：
  ```text
  sh ēng z ài @星仔
  n ǐ h ǎo sh ēng z ài @你好星仔
  ```
* 單純使用普通話拼音（如 `s īng z ǎi` 或 `x īng z ǐ`）在廣東話聲學特徵下距離過遠；引入 `sh ēng z ài` 後即刻 100% 秒命中！

### 4. Beam Search 剪枝盲點 (`--max-active-paths=16`)
* 官方二進制預設 `--max-active-paths=4`。當 `keywords.txt` 中有多個發音規則時，前綴分支競爭會導致 Beam Search 過早剪枝（Prune），造成漏檢。
* **必須設定 `--max-active-paths=16`**，完整保留多候選路徑，同時完全不增加 CPU 負擔。

### 5. 聲學門檻與加權 (Tuned Parameters)
* `--keywords-threshold=0.06`：模型最佳觸發門檻（官方預設 0.25 太嚴格，0.06 在真人錄音下 100% 召回，且在 7 段非喚醒詞測試音訊庫中達 **0 誤觸發**）。
* `--keywords-score=2.0`：聲學候選加權分數。
* `--num-threads=1`：單線程鎖定，極致節能。

### 6. macOS 權限與 Line Buffering
* `Info.plist` 必須包含 `NSMicrophoneUsageDescription` 與 `LSUIElement=true`。
* 啟動時必須透過 `stdbuf -oL` 強制行緩衝，防止 C++ 緩存輸出。
* `pipe.availableData.isEmpty` 時必須將 `readabilityHandler` 設為 `nil`，防止子進程退出時 CPU 飆升至 100%。

---

## 🛠️ 操作與管理命令 (CLI Commands)

所有操作均以標準 Bash 腳本封裝，完全無需 Python：

```bash
# 1. 啟動 StarListener（常駐 Menu Bar）
./start.sh

# 2. 停止 StarListener
./stop.sh

# 3. 重新編譯 Swift 原生 App
./scripts/build_app.sh

# 4. 錄製真人音訊並離線檢測 / 自動 Tuning
./scripts/record_sample.sh

# 5. 查看即時運行日誌
tail -f listener.log
```

---

## 📁 專案目錄結構 (Project Structure)

```text
star-mac-listener/
├── ARCHITECTURE.md          # 核心架構、設計陷阱與不可變規範
├── TROUBLESHOOTING.md        # 詳細排錯手冊、逐音素 Probe 診斷法
├── README.md                # 專案總覽與使用手冊
├── start.sh                 # 啟動腳本
├── stop.sh                  # 停止腳本
├── listener.log             # 即時運作與喚醒日誌
├── bin/
│   ├── sherpa-onnx-keyword-spotter-microphone  # 即時麥克風 KWS 引擎
│   └── sherpa-onnx-keyword-spotter             # 離線 WAV 測試引擎
├── config/
│   └── keywords.txt         # 喚醒詞定義（收錄 sh ēng z ài 等最佳音素）
├── model/                   # Zipformer 3.3M 聲學模型檔案
│   ├── tokens.txt
│   ├── encoder.onnx
│   ├── decoder.onnx
│   └── joiner.onnx
├── scripts/
│   ├── build_app.sh         # Swift App 編譯與 Info.plist 打包腳本
│   └── record_sample.sh     # 真人錄音與離線比對 Tuning 腳本
└── src/
    └── main.swift           # Native Swift Menu Bar 守護進程源碼
```
