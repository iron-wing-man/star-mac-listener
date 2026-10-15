import Cocoa
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, @unchecked Sendable {
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
    var iconAnimator: StellaIconAnimator!
    let earphoneMonitor = EarphoneMonitorService()
    let orbHud = VoiceOrbHudController()
    let bridgeManager = BridgeBarManager()

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
        starConfig = StarConfig.load(from: "\(baseDir)/config")
        apiClient = StarApiClient(config: starConfig)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        iconAnimator = StellaIconAnimator(statusItem: statusItem, baseDir: baseDir)

        captureService.onAudioLevel = { [weak self] level in
            self?.orbHud.updateAudioLevel(level)
        }

        playbackService.onAudioLevel = { [weak self] level in
            self?.orbHud.updateAudioLevel(level)
        }

        playbackService.onPlaybackFinished = { [weak self] in
            // 等喇叭殘響播完 (約 300ms) 先切入 👂 連續對話，避免殘響干擾 VAD
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self, !self.isPaused, self.isBusy else { return }
                self.startFollowUpListening()
            }
        }

        bridgeManager.onStatusUpdated = { [weak self] in
            self?.rebuildMenu()
        }
        bridgeManager.start()

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

        if starConfig.requireEarphoneForAutoWake {
            // Start in standby until JLab Flex is detected
            isPaused = true
            iconAnimator.stopSpinning()
            rebuildMenu()

            earphoneMonitor.onConnectionChanged = { [weak self] connected, deviceName in
                guard let self = self else { return }
                if connected {
                    print("🎧 Target earphone connected (\(deviceName ?? "JLab Flex")) -> Auto-resuming wakeword listener!")
                    self.resumeListening()
                } else {
                    print("📴 Target earphone disconnected -> Entering Standby (Mic OFF)!")
                    self.pauseListening()
                }
            }
            earphoneMonitor.start(targetNames: starConfig.targetEarphoneNames)
        } else {
            rebuildMenu()
            iconAnimator.startSpinning()
            startKeywordSpotter()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        bridgeManager.refreshEmulatorStatusAsync()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let headerTitle = "✦ Stella Voice & AGY Bridge"
        let topHeader = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        topHeader.isEnabled = false
        menu.addItem(topHeader)

        let earphoneTag: String
        if earphoneMonitor.isEarphoneConnected, let dev = earphoneMonitor.connectedDeviceName {
            earphoneTag = "🎧 \(dev)"
        } else {
            earphoneTag = "等待 JLab Flex"
        }

        let stateTitle = isPaused
            ? "⏸ 語音狀態：待命中 (\(earphoneTag) | 點擊手動喚醒)"
            : "● 語音狀態：監聽中 (\(earphoneTag) | 點擊暫停)"
        statusMenuItem = NSMenuItem(title: stateTitle, action: #selector(togglePause), keyEquivalent: "p")
        statusMenuItem.target = self
        menu.addItem(statusMenuItem)

        let wakeHint = NSMenuItem(title: "🎯 喚醒詞：Stella | 快捷鍵：Ctrl+Opt+Space", action: nil, keyEquivalent: "")
        wakeHint.isEnabled = false
        menu.addItem(wakeHint)

        countMenuItem = NSMenuItem(title: "📊 觸發統計：已成功喚醒 \(wakeCount) 次", action: nil, keyEquivalent: "")
        countMenuItem.isEnabled = false
        menu.addItem(countMenuItem)

        let testItem = NSMenuItem(title: "🔔 測試提示音 & 全息聲波光球", action: #selector(testSound), keyEquivalent: "t")
        testItem.target = self
        menu.addItem(testItem)

        let keywordsItem = NSMenuItem(title: "⚙️ 編輯喚醒詞 (keywords.txt)", action: #selector(openKeywords), keyEquivalent: "e")
        keywordsItem.target = self
        menu.addItem(keywordsItem)

        menu.addItem(NSMenuItem.separator())

        // Append all StarBridgeBar items (Bridge Status, Journalia, STAR Backlog, Dev Console, SonarQube)
        bridgeManager.appendBridgeMenuItems(to: menu)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "❌ 退出 StarListener & Bridge Helper", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

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
        guard !isPaused else {
            iconAnimator.stopSpinning()
            orbHud.hide()
            rebuildMenu()
            return
        }
        isPaused = true
        iconAnimator.stopSpinning()
        orbHud.hide()
        rebuildMenu()

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

        print("⏸ Listener paused (Standby), all audio/tasks stopped and background process terminated.")
    }

    func resumeListening() {
        guard isPaused else {
            iconAnimator.startSpinning()
            rebuildMenu()
            return
        }
        isPaused = false
        cooldownEndTime = Date.distantPast
        lastTriggerTime = Date.distantPast
        iconAnimator.startSpinning()
        rebuildMenu()
        print("▶️ Listener resumed, starting background sherpa-onnx process...")
        startKeywordSpotter()
    }

    @objc func testSound() {
        NSSound(named: "Tink")?.play()
        orbHud.show(mode: "hearing", caption: "HOLOGRAPHIC VOICE ORB READY")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self = self, !self.isBusy else { return }
            self.orbHud.hide()
        }
    }

    @objc func openKeywords() {
        let path = "\(baseDir)/config/keywords.txt"
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }

    @objc func quitApp() {
        process?.terminate()
        bridgeManager.stop()
        NSApplication.shared.terminate(nil)
    }

    private func isExternalTTSPlaying() -> Bool {
        let lockPath = starConfig.ttsLockFile
        guard !lockPath.isEmpty,
              let attrs = try? FileManager.default.attributesOfItem(atPath: lockPath),
              let modDate = attrs[.modificationDate] as? Date else {
            return false
        }
        return Date().timeIntervalSince(modDate) < 60.0
    }

    var resetWorkItem: DispatchWorkItem?
    var lastTriggerTime: Date = Date.distantPast

    func onWakeWordDetected() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isPaused else { return }
            let now = Date()

            // 1. 如果正喺度播緊聲（TTS 或異步 AGY 通知），嚴格禁止自我喚醒與打斷
            if self.playbackService.isPlaying || self.isExternalTTSPlaying() {
                print("🔇 Stella 播緊聲中，忽略喚醒詞避免打斷...")
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
            self.rebuildMenu()

            self.resetWorkItem?.cancel()

            self.currentActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "StarVoiceInteraction"
            )

            // 彈出 HUD 全息聲波光球！
            self.orbHud.show(mode: "hearing", caption: "WAKEWORD DETECTED // READY")
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
        orbHud.setMode("hearing", caption: "LISTENING... (SAY YOUR COMMAND)")
        captureService.startRecording(config: starConfig) { [weak self] pcmData in
            guard let self = self, self.isBusy, !self.isPaused else { return }

            if pcmData.isEmpty {
                print("⚠️ Initial recording returned empty audio, returning to idle.")
                self.finishInteraction(success: false)
                return
            }

            self.orbHud.setMode("waiting_agy", caption: "STELLA THINKING... (SPEAK TO APPEND)")
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
                    self.orbHud.setMode("playing", caption: "STELLA SPEAKING...")
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

    // 思考中微監聽：若用家喺 Stella 諗緊嗰陣繼續講嘢，自動錄低並送去後端 Cancel & Combine
    func startThinkingAppendListening() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isPaused, self.isBusy && !self.playbackService.isPlaying else { return }
            self.isAppendListening = true
            print("👂 Started Thinking Append Listener (waiting for follow-up speech)...")

            self.captureService.startRecording(
                config: self.starConfig,
                timeoutWithoutSpeechSec: 15.0,
                onSpeechStarted: { [weak self] in
                    print("🎙️ Speech detected during thinking! Capturing append chunk...")
                    self?.orbHud.setMode("hearing", caption: "APPENDING SPEECH...")
                }
            ) { [weak self] appendPcmData in
                guard let self = self, !self.isPaused else { return }
                self.isAppendListening = false

                if !appendPcmData.isEmpty {
                    print("🔀 Captured append chunk (\(appendPcmData.count) bytes), sending to /api/web_request...")
                    self.isAppendInFlight = true
                    self.orbHud.setMode("waiting_agy", caption: "MERGING APPENDED SPEECH...")
                    Task {
                        do {
                            _ = try await self.apiClient.sendAudio(pcmData: appendPcmData, isAppend: true)
                            print("✅ Append audio sent successfully!")
                            self.isAppendInFlight = false
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
            self.orbHud.setMode("followup", caption: "FOLLOW-UP READY (SPEAK NOW)...")
            self.isFollowUp = true
            self.isBusy = true
            print("👂 Entered Follow-up Mode (listening for \(self.starConfig.followUpListenSec)s without wake word)...")

            self.captureService.startRecording(
                config: self.starConfig,
                timeoutWithoutSpeechSec: self.starConfig.followUpListenSec,
                onSpeechStarted: { [weak self] in
                    guard let self = self, !self.isPaused else { return }
                    self.orbHud.setMode("hearing", caption: "LISTENING...")
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
                self.orbHud.setMode("waiting_agy", caption: "STELLA THINKING... (SPEAK TO APPEND)")
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
                self.orbHud.setMode("waiting_agy", caption: "NO SPEECH DETECTED")
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

            self.orbHud.setMode("waiting_agy", caption: "CONNECTION ERROR // RETRYING")

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
            self.orbHud.hide()
            if self.isPaused {
                self.iconAnimator.stopSpinning()
            } else {
                self.iconAnimator.startSpinning()
            }
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
        process?.terminate()
        process = nil

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
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil, attributes: nil)
        }
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
        bridgeManager.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
