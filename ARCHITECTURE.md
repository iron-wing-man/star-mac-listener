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
* `sherpa-onnx-keyword-spotter-microphone`：專門支援 **Zipformer 3.3M 聲學換醒 (Transducer KWS)** 的二進制。
* 核心模型：`sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01` (Encoder / Decoder / Joiner)，CPU 佔用僅 ~2%–3%，記憶體 ~80MB。
* 執行檔路徑：`bin/sherpa-onnx-keyword-spotter-microphone`。
* 離線驗證檔路徑：`bin/sherpa-onnx-keyword-spotter`（用於對 wav 檔案進行單元測試與 tuning）。

---

### ③ 喚醒詞聲學映射與關鍵參數 (Cantonese Acoustic Mapping & Tuning)
* Zipformer Wenetspeech 3.3M 的詞表 `tokens.txt` 以聲母 (Initial) 與帶聲調韻母 (Toned Final) 建模。
* **廣東話聲學實測發現**：真人口語「星仔」(sing1 zai2) 在該聲學模型中被精確判定為：
  ```text
  sh ēng z ài @星仔
  n ǐ h ǎo sh ēng z ài @你好星仔
  ```
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

---

### ⑤ Line Buffering 與進程防假死 (Anti-Hung)
* C++ 二進制在 Pipe 環境下預設開啟 Block Buffering，因此啟動時必須透過 `stdbuf -oL` 強制行緩衝。
* Swift 的 `readabilityHandler` 必須檢測 `pipe.availableData.isEmpty`。當子進程退出時必須將 handler 設為 `nil`，否則會陷入 100% CPU 的死循環。
