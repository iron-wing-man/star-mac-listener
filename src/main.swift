import Cocoa
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var process: Process?
    var wakeCount = 0
    var countMenuItem: NSMenuItem!
    var statusMenuItem: NSMenuItem!
    var isPaused = false
    
    // Components
    var starConfig: StarConfig!
    let captureService = AudioCaptureService()
    var apiClient: StarApiClient!
    let playbackService = AudioPlaybackService()
    
    var isBusy = false
    var isFollowUp = false
    var isAppendListening = false
    var isAppendInFlight = false
    var followUpRetryCount = 0
    var currentInteractionTask: Task<Void, Never>?
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
            // 等喇叭殘響播完 (約 300ms) 先切入 👂 連續對話，避免殘響干擾 VAD
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, !self.isPaused, self.isBusy else { return }
                self.startFollowUpListening()
            }
        }

        GlobalHotKey.onTrigger = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                print("⌨️ Global HotKey pressed! (Current isPaused: \(self.isPaused))")
                if self.isPaused {
                    // Sleep -> Awake: 恢復監聽並直接開咪
                    self.resumeListening()
                    self.onWakeWordDetected()
                } else {
                    // Awake -> Sleep: 無論處於待命、錄音、等待抑或播放中，即刻全面停止並入睡
                    self.pauseListening()
                }
            }
        }
        GlobalHotKey.register(config: starConfig)

        startKeywordSpotter()
    }

    func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "☆ Star Wakeword Listener", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        statusMenuItem = NSMenuItem(title: "● 狀態：監聽中", action: #selector(togglePause), keyEquivalent: "p")
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem(title: "🎯 喚醒詞：Stella | 快捷鍵：休眠/喚醒", action: nil, keyEquivalent: ""))
        
        countMenuItem = NSMenuItem(title: "📊 觸發統計：已成功喚醒 0 次", action: nil, keyEquivalent: "")
        menu.addItem(countMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "🔔 測試提示音", action: #selector(testSound), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "⚙️ 編輯喚醒詞", action: #selector(openKeywords), keyEquivalent: "e"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "❌ 退出程式", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }
    
    @objc func togglePause() {
        if isPaused {
            resumeListening()
        } else {
            pauseListening()
        }
    }
    
    func pauseListening() {
        guard !isPaused else { return }
        isPaused = true
        statusMenuItem.title = "⏸ 狀態：已暫停 (點擊恢復)"
        updateStatusIcon("😴")
        
        // 1. 終止背景喚醒進程
        process?.terminate()
        process = nil
        
        // 2. 即時中斷當前所有音訊錄音
        captureService.stopRecording()
        
        // 3. 取消背景網絡請求與輪詢 Task
        currentInteractionTask?.cancel()
        currentInteractionTask = nil
        
        // 4. 停止音訊播放
        playbackService.stop()
        
        // 5. 取消重設或錯誤還原計時
        resetWorkItem?.cancel()
        resetWorkItem = nil
        
        // 6. 釋放系統防休眠 Assertion
        if let activity = currentActivity {
            ProcessInfo.processInfo.endActivity(activity)
            currentActivity = nil
        }
        
        // 7. 重設內部狀態旗標
        isBusy = false
        isFollowUp = false
        isAppendListening = false
        isAppendInFlight = false
        followUpRetryCount = 0
        
        print("⏸ Listener paused, all audio/tasks stopped and background process terminated.")
    }
    
    func resumeListening() {
        guard isPaused else { return }
        isPaused = false
        cooldownEndTime = Date.distantPast
        lastTriggerTime = Date.distantPast
        statusMenuItem.title = "● 狀態：監聽中 (點擊暫停)"
        updateStatusIcon("☆")
        print("▶️ Listener resumed, starting background process...")
        startKeywordSpotter()
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isPaused else { return }
            let now = Date()
            
            // 1. 如果正喺度播緊聲（TTS），嚴格禁止自我喚醒與打斷，確保星仔講完每一句話
            if self.playbackService.isPlaying {
                print("🔇 星仔播緊聲中，忽略喚醒詞避免打斷...")
                return
            }
            
            // 2. 如果處於 👂 連續對話或追加狀態，叫「Stella」則平順切換到新喚醒
            if self.isFollowUp || self.isAppendListening {
                self.stopThinkingAppendListening()
                self.captureService.stopRecording()
                self.isFollowUp = false
                self.isBusy = false
            }

            // 3. 防抖與冷卻
            if self.isBusy || now < self.cooldownEndTime || now.timeIntervalSince(self.lastTriggerTime) < 0.4 {
                return
            }
            self.lastTriggerTime = now
            self.isBusy = true
            self.followUpRetryCount = 0
            
            self.wakeCount += 1
            self.countMenuItem.title = "📊 觸發統計：已成功喚醒 \(self.wakeCount) 次 (剛剛)"
            
            self.resetWorkItem?.cancel()
            
            self.currentActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "StarVoiceInteraction")

            // 提示音播緊嗰陣顯示 ✨，避免用家提早講嘢被截頭；等提示音播完 (350ms) 正式開咪先轉 🎙️
            self.updateStatusIcon("✨")
            NSSound(named: "Tink")?.play()

            // 等 Tink 提示音播完 (約 350ms) 先開始收音，避免錄入提示音干擾 STT 及聲紋
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self = self, self.isBusy, !self.isPaused else { return }
                self.startInitialRecording()
            }
        }
    }

    func startInitialRecording() {
        guard !isPaused, isBusy else { return }
        self.updateStatusIcon("🎙️")
        captureService.startRecording(config: starConfig) { [weak self] pcmData in
            guard let self = self, self.isBusy, !self.isPaused else { return }
            
            if pcmData.isEmpty {
                print("⚠️ Initial recording returned empty audio, returning to idle.")
                self.finishInteraction(success: false)
                return
            }
            
            self.updateStatusIcon("⏳")
            self.executeInteraction(pcmData: pcmData, isFollowUpTurn: false)
        }
    }

    func executeInteraction(pcmData: Data, isFollowUpTurn: Bool) {
        currentInteractionTask?.cancel()
        currentInteractionTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                if Task.isCancelled || self.isPaused { return }
                // 1. 即時啟動思考中追加監聽 (不用等 sendAudio 網絡來回，零時間縫隙)
                self.startThinkingAppendListening()
                
                let msgId = try await self.apiClient.sendAudio(pcmData: pcmData)
                if Task.isCancelled || self.isPaused { return }
                
                // 250ms 高速輪詢
                var wavUrl = try await self.apiClient.pollStats(messageId: msgId)
                if Task.isCancelled || self.isPaused { return }
                
                // 2. 關鍵保護：如果用家正喺度講緊追加嘅嘢 (isSpeechActive)，絕對唔好中斷用家！
                while self.captureService.isSpeechActive {
                    if Task.isCancelled || self.isPaused { return }
                    print("🎙️ User is actively speaking append chunk, waiting for utterance to finish...")
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                
                // 若剛好在完成瞬間送出了追加，重新等待新合併回應
                if self.isAppendInFlight {
                    print("⏳ Append was sent in flight, re-polling for updated response...")
                    wavUrl = try await self.apiClient.pollStats(messageId: msgId)
                }
                if Task.isCancelled || self.isPaused { return }
                
                // 伺服器已完成且用家冇講緊嘢，關閉追加監聽並下載音訊
                self.stopThinkingAppendListening()
                let wavData = try await self.apiClient.downloadVoiceResult(url: wavUrl)
                if Task.isCancelled || self.isPaused { return }
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, !self.isPaused, self.isBusy else { return }
                    self.followUpRetryCount = 0
                    self.updateStatusIcon("🔊")
                    self.playbackService.play(wavData: wavData)
                }
            } catch {
                self.stopThinkingAppendListening()
                if Task.isCancelled || self.isPaused {
                    print("🛑 Interaction cancelled or listener paused, ignoring error.")
                    return
                }
                if let urlErr = error as? URLError, urlErr.code == .cancelled {
                    print("🛑 Network request cancelled.")
                    return
                }
                if error is CancellationError {
                    print("🛑 Task cancellation caught.")
                    return
                }
                self.handleError(error, isFollowUpTurn: isFollowUpTurn)
            }
        }
    }

    // 思考中微監聽：若用家喺星仔諗緊嗰陣繼續講嘢，自動錄低並送去後端 Cancel & Combine
    func startThinkingAppendListening() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isPaused, self.isBusy && !self.playbackService.isPlaying else { return }
            self.isAppendListening = true
            print("👂 Started Thinking Append Listener (waiting for follow-up speech)...")
            
            self.captureService.startRecording(
                config: self.starConfig,
                timeoutWithoutSpeechSec: 15.0,
                onSpeechStarted: {
                    print("🎙️ Speech detected during thinking! Capturing append chunk...")
                }
            ) { [weak self] appendPcmData in
                guard let self = self, !self.isPaused else { return }
                self.isAppendListening = false
                
                if !appendPcmData.isEmpty {
                    print("🔀 Captured append chunk (\(appendPcmData.count) bytes), sending to /api/web_request...")
                    self.isAppendInFlight = true
                    Task {
                        do {
                            _ = try await self.apiClient.sendAudio(pcmData: appendPcmData, isAppend: true)
                            print("✅ Append audio sent successfully!")
                            self.isAppendInFlight = false
                            // 若依然喺思考中，繼續支援下一段追加
                            if self.isBusy && !self.playbackService.isPlaying && !self.isPaused {
                                self.startThinkingAppendListening()
                            }
                        } catch {
                            self.isAppendInFlight = false
                            print("⚠️ Failed to send append audio: \(error)")
                        }
                    }
                }
            }
        }
    }

    func stopThinkingAppendListening() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isAppendListening = false
            if !self.playbackService.isPlaying && !self.isFollowUp && !self.captureService.isSpeechActive {
                self.captureService.stopRecording()
            }
        }
    }

    // 連續對話模式 (Follow-up Mode)：播完 TTS 後保持 👂 3.5 秒
    func startFollowUpListening() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isPaused, !self.playbackService.isPlaying else { return }
            self.updateStatusIcon("👂")
            self.isFollowUp = true
            self.isBusy = true
            print("👂 Entered Follow-up Mode (listening for \(self.starConfig.followUpListenSec)s without wake word)...")
            
            self.captureService.startRecording(
                config: self.starConfig,
                timeoutWithoutSpeechSec: self.starConfig.followUpListenSec,
                onSpeechStarted: { [weak self] in
                    guard let self = self, !self.isPaused else { return }
                    self.updateStatusIcon("🎙️")
                    print("🎙️ Follow-up speech detected! Recording...")
                }
            ) { [weak self] pcmData in
                guard let self = self, !self.isPaused, self.isFollowUp else { return }
                self.isFollowUp = false
                
                if pcmData.isEmpty {
                    print("👂 Follow-up timeout with silence, returning to idle.")
                    self.finishInteraction(success: true)
                    return
                }
                
                print("👂 Follow-up audio captured (\(pcmData.count) bytes), sending...")
                self.updateStatusIcon("⏳")
                self.executeInteraction(pcmData: pcmData, isFollowUpTurn: true)
            }
        }
    }

    func handleError(_ error: Error, isFollowUpTurn: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if case StarError.noSpeechDetected = error {
                let errorMsg = "⚠️ 伺服器未檢測到有效語音指令 (STT 回傳為空)，請在聽到提示音後清晰說出完整問題。\n"
                print(errorMsg)
                let logPath = "\(self.baseDir)/listener.log"
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(errorMsg.data(using: .utf8)!)
                    handle.closeFile()
                }
                self.updateStatusIcon("❓")
                self.resetWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    self?.finishInteraction(success: false)
                }
                self.resetWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
                return
            }

            var errorMsg = "❌ Interaction Error: \(error)\n"
            let errorString = "\(error)"
            if errorString.contains("Local network prohibited") || errorString.contains("offline") {
                errorMsg += "💡 [權限提示] 檢測到本地網絡連線受阻 (Local network prohibited)。請至 macOS「系統設定 > 隱私權與安全性 > 本地網絡」確保 StarListener 權限已開啟 (ON)。\n"
            }
            print(errorMsg)
            let logPath = "\(self.baseDir)/listener.log"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(errorMsg.data(using: .utf8)!)
                handle.closeFile()
            }

            self.updateStatusIcon("😵‍💫")
            
            // 專為連續對話設計嘅容錯續聽：若喺 👂 模式出錯，閃爍 😵‍💫 1 秒後自動重返 👂 模式
            if isFollowUpTurn && self.followUpRetryCount < 2 {
                self.followUpRetryCount += 1
                print("😵‍💫 Follow-up turn errored, retrying listening in 1.0s (attempt \(self.followUpRetryCount)/2)...")
                self.resetWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.startFollowUpListening()
                }
                self.resetWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
                return
            }

            // 一般初次喚醒出錯，顯示短暫 😵‍💫 後恢復休眠
            self.resetWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.finishInteraction(success: false)
            }
            self.resetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + self.starConfig.errorDisplaySec, execute: workItem)
        }
    }

    func finishInteraction(success: Bool) {
        DispatchQueue.main.async {
            self.updateStatusIcon(self.isPaused ? "😴" : "☆")
            self.isFollowUp = false
            self.isAppendListening = false
            self.followUpRetryCount = 0
            self.captureService.stopRecording()
            if let activity = self.currentActivity {
                ProcessInfo.processInfo.endActivity(activity)
                self.currentActivity = nil
            }
            self.cooldownEndTime = Date().addingTimeInterval(1.0)
            self.isBusy = false
        }
    }

    func isStellaWakeWord(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("stella")
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
                if trimmed.contains("\"keyword\"") && trimmed.lowercased().contains("stella") {
                    if let self = self, !self.isPaused {
                        self.onWakeWordDetected()
                    }
                } else if trimmed.contains("Stella") && !trimmed.contains("keywords_file") {
                    // Fallback for non-JSON output just in case
                    if let self = self, !self.isPaused {
                        self.onWakeWordDetected()
                    }
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
