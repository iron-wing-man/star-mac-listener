import Cocoa
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var process: Process?
    var wakeCount = 0
    var countMenuItem: NSMenuItem!
    
    // Phase 2 components
    var starConfig: StarConfig!
    let captureService = AudioCaptureService()
    var apiClient: StarApiClient!
    let playbackService = AudioPlaybackService()
    
    var isBusy = false
    var cooldownEndTime: Date = Date.distantPast
    var currentActivity: NSObjectProtocol?
    
    var baseDir: String {
        return Bundle.main.bundleURL.deletingLastPathComponent().path
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon("☆")

        setupMenu()
        
        starConfig = StarConfig.load(from: "\(baseDir)/config")
        apiClient = StarApiClient(config: starConfig)
        
        playbackService.onPlaybackFinished = { [weak self] in
            self?.finishInteraction(success: true)
        }

        GlobalHotKey.onTrigger = { [weak self] in
            print("🚀 Triggered via Global Hotkey!")
            self?.onWakeWordDetected()
        }
        GlobalHotKey.register(config: starConfig)

        startKeywordSpotter()
    }

    func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "☆ Star Wakeword Listener (Phase 2)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "● 狀態：監聽中", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "🎯 喚醒詞：星仔 (或全域快捷鍵)", action: nil, keyEquivalent: ""))
        
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

    func updateStatusIcon(_ icon: String) {
        DispatchQueue.main.async {
            if let button = self.statusItem.button {
                button.title = icon
            }
        }
    }

    var resetWorkItem: DispatchWorkItem?
    var lastTriggerTime: Date = Date.distantPast

    func onWakeWordDetected() {
        DispatchQueue.main.async {
            let now = Date()
            
            // 1. 防抖、防忙碌、防剛播放完的自我喚醒冷卻 (1.5秒內忽略)
            if self.isBusy || now < self.cooldownEndTime || now.timeIntervalSince(self.lastTriggerTime) < 0.4 {
                return
            }
            self.lastTriggerTime = now
            self.isBusy = true
            
            self.wakeCount += 1
            self.countMenuItem.title = "📊 觸發統計：已成功喚醒 \(self.wakeCount) 次 (剛剛)"
            
            self.resetWorkItem?.cancel()
            
            self.currentActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "StarVoiceInteraction")

            self.updateStatusIcon("🎙️")
            NSSound(named: "Tink")?.play()

            // 等 Tink 提示音播完 (約 350ms) 先開始收音，避免錄入提示音干擾 STT 及聲紋
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self = self, self.isBusy else { return }
                self.startInteractionFlow()
            }
        }
    }

    func startInteractionFlow() {
        captureService.startRecording(config: starConfig) { [weak self] pcmData in
            guard let self = self else { return }
            
            self.updateStatusIcon("⏳")
            
            Task {
                do {
                    let msgId = try await self.apiClient.sendAudio(pcmData: pcmData)
                    let wavUrl = try await self.apiClient.pollStats(messageId: msgId)
                    let wavData = try await self.apiClient.downloadVoiceResult(url: wavUrl)
                    
                    DispatchQueue.main.async {
                        self.updateStatusIcon("🔊")
                        self.playbackService.play(wavData: wavData)
                    }
                } catch {
                    self.handleError(error)
                }
            }
        }
    }

    func handleError(_ error: Error) {
        DispatchQueue.main.async {
            let errorMsg = "❌ Interaction Error: \(error)\n"
            print(errorMsg)
            let logPath = "\(self.baseDir)/listener.log"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(errorMsg.data(using: .utf8)!)
                handle.closeFile()
            }

            self.updateStatusIcon("😣")
            
            let workItem = DispatchWorkItem { [weak self] in
                self?.finishInteraction(success: false)
            }
            self.resetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + self.starConfig.errorDisplaySec, execute: workItem)
        }
    }

    func finishInteraction(success: Bool) {
        DispatchQueue.main.async {
            self.updateStatusIcon("☆")
            if let activity = self.currentActivity {
                ProcessInfo.processInfo.endActivity(activity)
                self.currentActivity = nil
            }
            self.cooldownEndTime = Date().addingTimeInterval(1.5)
            self.isBusy = false
        }
    }

    // 專為廣東話「星仔」設計嘅全方位諧音與近音匹配器
    func isStarWakeWord(_ text: String) -> Bool {
        if text.contains("星仔") || text.contains("你好星仔") || text.contains("阿星") || text.contains("星哥") {
            return true
        }
        let variants = [
            "星子", "醒仔", "升仔", "聲仔", "勝仔", "新仔", "清仔", "先仔",
            "醒子", "升子", "聲子", "新子", "星指", "星之", "星際",
            "兄仔", "星球", "星计", "星計", "星系", "星记", "星記",
            "xingzai", "singzai", "xing zai", "sing zai"
        ]
        for variant in variants {
            if text.contains(variant) { return true }
        }
        if text.range(of: "[星醒升聲勝新兄][仔子指之球计計]", options: .regularExpression) != nil {
            return true
        }
        return false
    }

    func startKeywordSpotter() {
        let binPath = "\(baseDir)/bin/sherpa-onnx-keyword-spotter-microphone"
        let modelDir = "\(baseDir)/model"
        let keywordsPath = "\(baseDir)/config/keywords.txt"
        
        if !FileManager.default.fileExists(atPath: binPath) {
            print("Error: sherpa-onnx binary not found at \(binPath)")
            return
        }

        process = Process()
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
            "--num-threads=1"
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
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") && trimmed.contains("\"keyword\"") {
                    self?.onWakeWordDetected()
                } else if trimmed.contains("星仔") && !trimmed.contains("keywords_file") {
                    // Fallback for non-JSON output just in case
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
