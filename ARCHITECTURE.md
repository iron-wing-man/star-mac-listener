# StarListener Architecture & Invariants (核心架構與不可變設計)

> ⚠️ **CRITICAL WARNING TO ALL DEVELOPERS & AI AGENTS:**
> 本文檔記錄了此專案底層最核心的技術決策與設計陷阱。**在進行任何 Code Review、重構或更新時，絕對不可破壞（Break）以下的不變量（Invariants）！**

---

## 1. 核心不變量 (Critical Invariants)

### ① 語音辨識輸出在 `STDERR`，絕對不可與管道分離
* **源碼依據**：`sherpa-onnx` 的官方設計（參見 `sherpa-onnx-keyword-spotter-microphone.cc` 及 `display.h`）：
  ```cpp
  const auto r = spotter.GetResult(s.get());
  if (!r.keyword.empty()) {
      display.Print(keyword_index, r.AsJsonString()); // 內部透過 fprintf(stderr, ...)
      fflush(stderr);                                 // 明確 flush stderr
  }
  ```
* **鐵律**：在 Swift (`src/main.swift`) 中，**必須**將 `process.standardError` 導向與 `standardOutput` 相同的 Pipe：
  ```swift
  process?.standardOutput = pipe
  process?.standardError = pipe // ⚠️ 絕對不可分開或移除！所有命中喚醒詞的 JSON 都由此進入！
  ```
* **Code Review 警告**：審查代碼時，千萬不要誤以為「stderr 只是錯誤輸出而應該忽略」！一旦分離或丟棄 stderr，上層 App 將完全無法接收喚醒事件。

---

### ② 語音串流引擎與極低功耗架構
* `sherpa-onnx-keyword-spotter-microphone`：專門支援 **Zipformer 3M 中英雙語聲學換醒 (Transducer KWS)** 的二進制。
* 核心模型：`sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20` (Encoder / Decoder / Joiner)，原生支援 CMU 英語音素與拼音，CPU 佔用僅 ~2%–3%，記憶體 ~80MB。
* 執行檔路徑：`bin/sherpa-onnx-keyword-spotter-microphone`。
* 離線驗證檔路徑：`bin/sherpa-onnx-keyword-spotter`（用於對 wav 檔案進行單元測試與 tuning）。

---

### ③ 喚醒詞聲學映射與關鍵參數 (Stella & HK Accent Acoustic Tuning)
* Zipformer zh-en 3M 的詞表 `tokens.txt` 同時支援 ARPAbet 英語音素與中文帶調拼音。
* **香港口音 (Hong Kong Accent) 實測聲學特性與對齊**：
  * **標準發音**：`S T EH1 L AH0 @Stella`
  * **港式開口韻尾**：廣東話母語者常將尾音 "-la" 讀成類似「啦」(laa)，對齊為 `S T EH1 L AA0 @Stella`、`S T EH0 L AA0 @Stella`。
  * **港式雙元音化**：部分發音會將 "Ste-" 讀成偏 /ey/（類似 Stay-la / S-tei-la），對齊為 `S T EY1 L AH0 @Stella`、`S T EY1 L AA0 @Stella`。
  * **送氣弱化**：在 /s/ 後的 /t/ 常發成不送氣清音（類似 [d]），對齊為 `S D EH1 L AH0 @Stella`、`S D EH0 L AA0 @Stella`。
  * **插音現象**：部分語速會出現弱化的插音 /i/（類似 S-i-te-la），對齊為 `S IH0 T EH1 L AH0 @Stella`、`S IH0 D EH1 L AH0 @Stella`。
  * **常用問候語組合**：涵蓋 `Hello Stella` (`HH AH0 L OW1 ...`)、`Hi Stella` (`HH AY1 ...`)、`Hey Stella` (`HH EY1 ...`)。
  * **⚠️ keywords.txt 格式鐵律**：絕對**不可**在 `keywords.txt` 中加入 `#` 開頭的注釋行！因為 sherpa-onnx 引擎將 `#` 視為單詞自訂門檻（Threshold Specifier，如 `#0.35`），有 `#` 注釋會導致整份詞表解析失敗。
* **關鍵參數 (Critical Flags)**：
  * `--max-active-paths=16`：**絕對不可保留預設值 4！** 當 `keywords.txt` 擁有多個發音規則時，預設值 4 會在 Beam Search 階段過早剪枝 (Pruning)，導致喚醒詞被漏檢。
  * `--keywords-threshold=0.06`：模型最佳觸發門檻（實測在 0.05~0.08 之間具備 100% 召回率且在一般音訊庫零誤觸發）。
  * `--keywords-score=2.0`：聲學候選加權分。

---

### ④ macOS 麥克風權限 (TCC)
* 即使執行檔是 C++ 二進制，外層包裝的 Swift App 必須在其 `Info.plist` 明確宣告：
  ```xml
  <key>NSMicrophoneUsageDescription</key>
  <string>需要使用麥克風來監聽語音喚醒詞。</string>
  ```
* 若遺漏，macOS CoreAudio 會在底層返回全 0 的靜音數據（Silence），導致程式表面正常運行卻永遠聽不到聲音。
* **App Bundle 必須進行代碼簽名 (Code Signing)**：在 `scripts/build_app.sh` 必須包含 `codesign --force --deep -s - StarListener.app`。若未封裝簽名，macOS TCC 系統會判定 Bundle 資源簽名不完整（`code has no resources but signature indicates they must be present`），導致每次啟動 App 都會強制重新彈出詢問麥克風權限的對話框，無法永久記住授權。

---

### ⑤ Line Buffering 與進程防假死 (Anti-Hung)
* C++ 二進制在 Pipe 環境下預設開啟 Block Buffering，因此啟動時必須透過 `stdbuf -oL` 強制行緩衝。
* Swift 的 `readabilityHandler` 必須檢測 `pipe.availableData.isEmpty`。當子進程退出時必須將 handler 設為 `nil`，否則會陷入 100% CPU 的死循環。

---

### ⑥ macOS 本地網絡隱私權限 (Local Network Privacy)
* 在 macOS Sequoia (15.0+) 起，所有打包為 App Bundle 的程式連線至 RFC 1918 私有網段（如 `192.168.x.x`）時，會受到 macOS 本地網絡隱私審查。
* `Info.plist` 中必須保留 `NSLocalNetworkUsageDescription`。
* 由於 App 屬於無 Dock 圖標的 Menu Bar 守護進程（`LSUIElement=true`），系統可能無法主動呈現彈窗。若日誌出現 `Local network prohibited` 或 `NSURLErrorDomain Code=-1009`，必須至 macOS「系統設定 > 隱私權與安全性 > 本地網絡」手動將 `StarListener` 切換為開啟（ON）。
