# StarListener Troubleshooting & Maintenance Guide (排錯與維護指引)

當系統出現「聽不到喚醒詞」或需要更新、除錯時，**請嚴格按照以下標準清單（Checklist）與調校診斷法逐項核對**：

---

## 🔍 標準排查清單 (Standard Troubleshooting Checklist)

### 步驟 1：檢查進程狀態與日誌
```bash
# 檢查進程是否正常在運行
ps aux | grep -E "StarListener|sherpa-onnx" | grep -v grep

# 即時查看輸出日誌
tail -f ~/Developer/star/star-mac-listener/listener.log
```
* **正常現象**：應該能看到 `Num devices: ... Use device: 0 ... Started`。
* **喚醒現象**：當你說出喚醒詞時，日誌應即時印出：
  `{"start_time":0.00, "keyword": "星仔", ...}`。

---

### 步驟 2：排查「聽不到」的常見原因
| 症狀 | 根本原因 | 解決辦法 |
| :--- | :--- | :--- |
| 進程存在但叫極無反應 | `process.standardError` 被分離或未讀取 | 檢查 `src/main.swift`，確保 `standardError = pipe`。所有命中 JSON 只在 stderr 輸出！ |
| 多條規則時單詞不觸發 | `--max-active-paths` 預設值 4 過小 | 在 `main.swift` 與命令列明確指定 `--max-active-paths=16`，避免 Beam Search 剪枝。 |
| 發音正確但觸發唔到 | 廣東話聲學音素未對齊 | WenetSpeech 聲學模型視角中，「星仔」對齊為 `sh ēng z ài @星仔`。檢查 `config/keywords.txt`。 |
| 門檻太嚴格 | 門檻大於 0.10 | 將 `--keywords-threshold` 調整為 `0.06`（實測最佳操作點，0 誤觸發）。 |
| 日誌完全無 `Started`，進程閃退 | 誤用了 `sherpa-onnx-keyword-spotter`（非 microphone 版） | 確保執行檔是 `sherpa-onnx-keyword-spotter-microphone`。 |
| 日誌有 `Started`，但說話日誌毫無反應 | 麥克風音訊為全靜音（macOS 權限未授權） | 檢查 `Info.plist` 中的 `NSMicrophoneUsageDescription`，或在系統設定重設權限。 |
| 每次啟動都重問麥克風權限 | Bundle 未進行 codesign 封裝，TCC 判定簽名損壞 | 在 `scripts/build_app.sh` 執行 `codesign --force --deep -s - StarListener.app` 密封簽名。 |
| 喚醒後圖標變 😵‍💫 且日誌顯示 `Local network prohibited` | macOS Sequoia+ 本地網絡權限未授權 | 至「系統設定 > 隱私權與安全性 > 本地網絡」將 `StarListener` 權限切換為開啟（ON），然後重啟 App。 |
| CPU 飆升至 100% | 子進程退出後 `readabilityHandler` 未被解除 | 檢查 `pipe.availableData.isEmpty` 時是否設 handler 為 `nil`。 |

---

## 🔬 進階聲學調校診斷法 (Phoneme Probing Technique)

如果你發現更換咗自訂喚醒詞，或者不同口音無法觸發，請依循以下已驗證嘅標準調校程序：

### 1. 錄製真人清晰音訊樣本
```bash
./scripts/record_sample.sh
# 或手動錄製 5 秒 16kHz 16-bit mono 音訊
/opt/homebrew/bin/ffmpeg -y -f avfoundation -i ":0" -t 5 -ar 16000 -ac 1 /tmp/star_sample.wav
```

### 2. 檢測錄音音量
```bash
/opt/homebrew/bin/ffmpeg -i /tmp/star_sample.wav -af "volumedetect" -vn -sn -dn -f null /dev/null 2>&1 | grep "max_volume"
```
* **標準值**：正常說話音量 `max_volume` 應在 **-15 dB 至 -6 dB** 之間。
* **異常**：若小於 -35 dB，代表麥克風收音不良或被系統靜音。

### 3. 單音素探針法 (Phoneme Probing)
若多字喚醒詞未觸發，可將單個字嘅可能拼音分解為 probe 檔案（如 `/tmp/probe.txt`）：
```text
sh ēng @星
s īng @星
x īng @星
z ài @仔
z ǎi @仔
```
然後透過離線二進制進行低門檻掃描：
```bash
bin/sherpa-onnx-keyword-spotter \
  --tokens=model/tokens.txt \
  --encoder=model/encoder.onnx \
  --decoder=model/decoder.onnx \
  --joiner=model/joiner.onnx \
  --keywords-file=/tmp/probe.txt \
  --keywords-threshold=0.01 \
  --keywords-score=2.0 \
  --max-active-paths=16 \
  /tmp/star_sample.wav
```
透過輸出的時間戳（Timestamps）與 Tokens，即可確切得知該聲學模型將你的發音識別為哪些音素序列，再將其合併寫入 `config/keywords.txt`。

---

## 🛠️ 未來更新與維護規範 (Mandatory Rules for Future Updates)

當任何 Agent 或開發者需要：
1. **修改喚醒詞 (Update Wake Words)**：
   * 修改 `config/keywords.txt`。
   * 確保每一行結尾有 `@喚醒詞名稱`。
   * 必須重啟 App：執行 `./stop.sh && ./start.sh`。
2. **切換語言模型 (Switch Language Models)**：
   * 放入 `model/` 後，必須確認該模型的建模單元（`bpe` 還是 `cjkchar` / `ppinyin`）。
   * 測試時必須手動在命令列先執行一次確認無崩潰，再整合進 Swift。
3. **代碼重構或審查 (Refactor / Code Review)**：
   * **絕不可**將 `stderr` 與 `stdout` 分開過濾。
   * **絕不可**將 `--max-active-paths` 降回 4。
   * **絕不可**引入 Python 依賴，維持純 POSIX Bash + 原生 Swift + Standalone Binary 的架構。
