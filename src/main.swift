import Cocoa
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var process: Process?
    var wakeCount = 0
    var countMenuItem: NSMenuItem!
    
    // 獲取 App 的外層目錄 (即 ~/Developer/star/star-mac-listener)
    var baseDir: String {
        return Bundle.main.bundleURL.deletingLastPathComponent().path
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 初始化 Menu Bar 圖標 (平時待機使用低調精緻的 ☆)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "☆"
        }

        // 2. 建立下拉選單
        setupMenu()

        // 3. 啟動 Sherpa-ONNX 喚醒詞子進程
        startKeywordSpotter()
    }

    func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "☆ Star Wakeword Listener (Phase 1)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "● 狀態：監聽中", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "🎯 喚醒詞：星仔", action: nil, keyEquivalent: ""))
        
        countMenuItem = NSMenuItem(title: "📊 觸發統計：已成功喚醒 0 次", action: nil, keyEquivalent: "")
        menu.addItem(countMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "🔔 測試提示音", action: #selector(testSound), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "⚙️ 編輯喚醒詞", action: #selector(openKeywords), keyEquivalent: "e"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "❌ 退出程式", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func testSound() {
        NSSound(named: "Tink")?.play()
    }

    @objc func openKeywords() {
        let path = "\(baseDir)/config/keywords.txt"
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }

    @objc func quitApp() {
        process?.terminate()
        NSApplication.shared.terminate(nil)
    }

    var resetWorkItem: DispatchWorkItem?
    var lastTriggerTime: Date = Date.distantPast

    func onWakeWordDetected() {
        DispatchQueue.main.async {
            let now = Date()
            // 防抖：0.4 秒內嘅連續同一個事件過濾，避免重複響音
            if now.timeIntervalSince(self.lastTriggerTime) < 0.4 {
                return
            }
            self.lastTriggerTime = now

            self.wakeCount += 1
            self.countMenuItem.title = "📊 觸發統計：已成功喚醒 \(self.wakeCount) 次 (剛剛)"
            
            // 取消之前未完成嘅復原定時器
            self.resetWorkItem?.cancel()

            // 喚醒時：星星瞬間被點亮，變為璀璨發光的 🌟！
            if let button = self.statusItem.button {
                button.title = "🌟"
            }
            
            // 播放清脆提示音
            NSSound(named: "Tink")?.play()

            // 0.8 秒後快速恢復為待機狀態的 ☆
            let workItem = DispatchWorkItem { [weak self] in
                if let button = self?.statusItem.button {
                    button.title = "☆"
                }
            }
            self.resetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
        }
    }

    // 專為廣東話「星仔」設計嘅全方位諧音與近音匹配器
    func isStarWakeWord(_ text: String) -> Bool {
        // 1. 原生與前綴包含
        if text.contains("星仔") || text.contains("你好星仔") || text.contains("阿星") || text.contains("星哥") {
            return true
        }
        
        // 2. 廣東話近音字 / 諧音字（包含連續說話時模型轉錄偏差）
        let variants = [
            "星子", "醒仔", "升仔", "聲仔", "勝仔", "新仔", "清仔", "先仔",
            "醒子", "升子", "聲子", "新子", "星指", "星之", "星際",
            "兄仔", "星球", "星计", "星計", "星系", "星记", "星記",
            "xingzai", "singzai", "xing zai", "sing zai"
        ]
        for variant in variants {
            if text.contains(variant) {
                return true
            }
        }
        
        // 3. 正則模式：[星/醒/升/聲/勝/新/兄] + [仔/子/指/之/球/計]
        if text.range(of: "[星醒升聲勝新兄][仔子指之球计計]", options: .regularExpression) != nil {
            return true
        }
        
        return false
    }

    func startKeywordSpotter() {
        let binPath = "\(baseDir)/bin/sherpa-onnx-keyword-spotter-microphone"
        let modelDir = "\(baseDir)/model"
        let keywordsPath = "\(baseDir)/config/keywords.txt"
        
        // 檢查執行檔是否存在
        if !FileManager.default.fileExists(atPath: binPath) {
            print("Error: sherpa-onnx binary not found at \(binPath)")
            return
        }

        process = Process()
        
        // 使用 stdbuf -oL 強制 line buffering，解決 C++ stdout 延遲問題
        process?.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process?.arguments = [
            "stdbuf", "-oL",
            binPath,
            "--tokens=\(modelDir)/tokens.txt",
            "--encoder=\(modelDir)/encoder.onnx",
            "--decoder=\(modelDir)/decoder.onnx",
            "--joiner=\(modelDir)/joiner.onnx",
            "--keywords-file=\(keywordsPath)",
            "--keywords-score=2.0",
            "--keywords-threshold=0.06",
            "--max-active-paths=16",
            "--num-threads=1" // ⚡ 單線程運行，CPU 鎖定在 2%~3%，極致省電
        ]

        let pipe = Pipe()
        process?.standardOutput = pipe
        // -------------------------------------------------------------------------
        // ⚠️ CRITICAL ARCHITECTURE INVARIANT (DO NOT BREAK IN CODE REVIEW / REFACTOR):
        // Sherpa-ONNX writes its detection results ("keyword": "...") EXCLUSIVELY
        // to STDERR, NOT STDOUT! (See sherpa-onnx-keyword-spotter-microphone.cc & display.h)
        // Therefore, standardError MUST be redirected to the same pipe as standardOutput.
        // Separating or ignoring standardError will completely break keyword detection!
        // -------------------------------------------------------------------------
        process?.standardError = pipe

        let logPath = "\(baseDir)/listener.log"
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: nil)
        let logFileHandle = FileHandle(forWritingAtPath: logPath)

        let outHandle = pipe.fileHandleForReading
        outHandle.readabilityHandler = { [weak self] pipe in
            let data = pipe.availableData
            if data.isEmpty {
                outHandle.readabilityHandler = nil
                return
            }
            if let line = String(data: data, encoding: .utf8) {
                print(line, terminator: "")
                if let logFileHandle = logFileHandle {
                    logFileHandle.seekToEndOfFile()
                    if let logData = line.data(using: .utf8) {
                        logFileHandle.write(logData)
                    }
                }
                // 專用 KWS 輸出 JSON 格式包含 "keyword" 或命中 "星仔"
                if line.contains("\"keyword\"") || line.contains("星仔") || line.contains("keyword") {
                    self?.onWakeWordDetected()
                }
            }
        }

        do {
            try process?.run()
        } catch {
            print("Failed to start sherpa-onnx process: \(error)")
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        process?.terminate()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
