import Cocoa

class BridgeBarManager: NSObject {
    var onStatusUpdated: (() -> Void)?

    private(set) var isBridgeRunning = false
    private(set) var activeWorkspace = ""
    private(set) var isEmulatorRunning = false
    private(set) var runningEmulatorId = ""

    private var timer: Timer?
    private var pythonProcess: Process?

    func start() {
        ensureSonarTunnel()
        startAudioReceiver()
        checkBridgeHealth()

        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkBridgeHealth()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pythonProcess?.terminate()
        pythonProcess = nil
    }

    private func startAudioReceiver() {
        // Check if mac_audio_receiver.py is already running
        let checkTask = Process()
        checkTask.launchPath = "/usr/bin/pgrep"
        checkTask.arguments = ["-f", "mac_audio_receiver.py"]
        try? checkTask.run()
        checkTask.waitUntilExit()
        if checkTask.terminationStatus == 0 {
            return
        }

        let targetPath = NSHomeDirectory() + "/Developer/star/star-mac-bridge-bar/mac_audio_receiver.py"
        if FileManager.default.fileExists(atPath: targetPath) {
            DispatchQueue.global(qos: .background).async { [weak self] in
                let task = Process()
                task.launchPath = "/usr/bin/env"
                task.arguments = ["python3", targetPath]
                self?.pythonProcess = task
                try? task.run()
            }
        }
    }

    private func ensureSonarTunnel() {
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", "nc -z 127.0.0.1 9000 || ssh -f -N -L 9000:localhost:9000 star-main"]
            try? task.run()
        }
    }

    func refreshEmulatorStatusAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let emuStatus = self.checkEmulatorRunning()
            DispatchQueue.main.async {
                if self.isEmulatorRunning != emuStatus.running || self.runningEmulatorId != emuStatus.id {
                    self.isEmulatorRunning = emuStatus.running
                    self.runningEmulatorId = emuStatus.id
                    self.onStatusUpdated?()
                }
            }
        }
    }

    func appendBridgeMenuItems(to menu: NSMenu) {
        let headerItem = NSMenuItem(title: "star-agy-bridge (Mac)", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        let bridgeTitle = isBridgeRunning ? "Status: 🟢 Running (:5005)" : "Status: 🔴 Stopped (:5005)"
        let statusItemMenu = NSMenuItem(title: bridgeTitle, action: nil, keyEquivalent: "")
        statusItemMenu.isEnabled = false
        menu.addItem(statusItemMenu)

        if !activeWorkspace.isEmpty {
            let wsShort = (activeWorkspace as NSString).lastPathComponent
            let wsItem = NSMenuItem(title: "Workspace: \(wsShort)", action: nil, keyEquivalent: "")
            wsItem.toolTip = activeWorkspace
            wsItem.isEnabled = false
            menu.addItem(wsItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Journalia Submenu
        let journaliaItem = NSMenuItem(title: "Journalia", action: nil, keyEquivalent: "")
        let journaliaMenu = NSMenu()

        let regressionItem = NSMenuItem(title: "🚀 Run Core Journey Regression", action: #selector(runJournaliaRegression), keyEquivalent: "")
        regressionItem.target = self
        journaliaMenu.addItem(regressionItem)

        let uiTestItem = NSMenuItem(title: "🧪 Run UI Closed-Loop Test", action: #selector(runJournaliaUiTest), keyEquivalent: "")
        uiTestItem.target = self
        journaliaMenu.addItem(uiTestItem)

        let unitTestItem = NSMenuItem(title: "🧪 Run JVM Unit Tests", action: #selector(runJournaliaUnitTest), keyEquivalent: "u")
        unitTestItem.target = self
        journaliaMenu.addItem(unitTestItem)

        journaliaMenu.addItem(NSMenuItem.separator())

        let emuStatusTitle = isEmulatorRunning
            ? "📱 Emulator: 🟢 Running (\(runningEmulatorId))"
            : "📱 Emulator: ⚪️ Stopped (0 MB RAM)"
        let emuStatusItem = NSMenuItem(title: emuStatusTitle, action: nil, keyEquivalent: "")
        emuStatusItem.isEnabled = false
        journaliaMenu.addItem(emuStatusItem)

        if isEmulatorRunning {
            let stopEmuItem = NSMenuItem(title: "⏹ Stop Emulator (Free RAM)", action: #selector(stopJournaliaEmulator), keyEquivalent: "")
            stopEmuItem.target = self
            journaliaMenu.addItem(stopEmuItem)
        } else {
            let startHeadlessItem = NSMenuItem(title: "▶️ Start Emulator (Headless)", action: #selector(startJournaliaEmulatorHeadless), keyEquivalent: "")
            startHeadlessItem.target = self
            journaliaMenu.addItem(startHeadlessItem)

            let startGuiItem = NSMenuItem(title: "▶️ Start Emulator (GUI)", action: #selector(startJournaliaEmulatorGui), keyEquivalent: "")
            startGuiItem.target = self
            journaliaMenu.addItem(startGuiItem)
        }

        journaliaMenu.addItem(NSMenuItem.separator())

        let phoneItem = NSMenuItem(title: "📱 Install Dev App to Phone", action: #selector(installJournaliaPhone), keyEquivalent: "")
        phoneItem.target = self
        journaliaMenu.addItem(phoneItem)

        let emuItem = NSMenuItem(title: "📱 Install Dev App to Emulator", action: #selector(installJournaliaEmulator), keyEquivalent: "")
        emuItem.target = self
        journaliaMenu.addItem(emuItem)

        journaliaMenu.addItem(NSMenuItem.separator())

        let deployBackendItem = NSMenuItem(title: "☁️ Deploy Backend to star-main", action: #selector(deployJournaliaBackend), keyEquivalent: "d")
        deployBackendItem.target = self
        journaliaMenu.addItem(deployBackendItem)

        let stardbTestItem = NSMenuItem(title: "🗄 Test Backend DB Sync", action: #selector(runJournaliaStarDbSync), keyEquivalent: "")
        stardbTestItem.target = self
        journaliaMenu.addItem(stardbTestItem)

        journaliaMenu.addItem(NSMenuItem.separator())

        let openTerminalItem = NSMenuItem(title: "📂 Open in Terminal", action: #selector(openJournaliaTerminal), keyEquivalent: "")
        openTerminalItem.target = self
        journaliaMenu.addItem(openTerminalItem)

        journaliaItem.submenu = journaliaMenu
        menu.addItem(journaliaItem)

        // STAR Backlog Submenu
        let backlogItem = NSMenuItem(title: "STAR Backlog", action: nil, keyEquivalent: "")
        let backlogMenu = NSMenu()

        let refineItem = NSMenuItem(title: "⚡️ Refine Backlogs (AGY Pro)", action: #selector(runBacklogRefinement), keyEquivalent: "")
        refineItem.target = self
        backlogMenu.addItem(refineItem)

        let listBacklogItem = NSMenuItem(title: "📋 View Pending Backlogs (DB)", action: #selector(viewPendingBacklogs), keyEquivalent: "")
        listBacklogItem.target = self
        backlogMenu.addItem(listBacklogItem)

        menu.setSubmenu(backlogMenu, for: backlogItem)
        menu.addItem(backlogItem)

        menu.addItem(NSMenuItem.separator())

        let openWebItem = NSMenuItem(title: "Open STAR Dev Console...", action: #selector(openWebDev), keyEquivalent: "o")
        openWebItem.target = self
        menu.addItem(openWebItem)

        let openSonarItem = NSMenuItem(title: "📊 Open SonarQube Dashboard...", action: #selector(openSonarQube), keyEquivalent: "")
        openSonarItem.target = self
        menu.addItem(openSonarItem)

        menu.addItem(NSMenuItem.separator())

        let restartItem = NSMenuItem(title: "Restart Bridge", action: #selector(restartBridge), keyEquivalent: "r")
        restartItem.target = self
        menu.addItem(restartItem)

        let stopItem = NSMenuItem(title: "Stop Bridge & Quit", action: #selector(stopBridgeAndQuit), keyEquivalent: "s")
        stopItem.target = self
        menu.addItem(stopItem)
    }

    // MARK: - Actions

    private func getJournaliaDir() -> String {
        return NSHomeDirectory() + "/Developer/Journalia"
    }

    private func getStarComponentsDir() -> String {
        return NSHomeDirectory() + "/Developer/star/starship"
    }

    private func runInTerminal(command: String) {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\"\ntell application \"Terminal\" to activate"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }

    private func notify(title: String, message: String) {
        let script = "display notification \"\(message)\" with title \"\(title)\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }

    @objc func runJournaliaRegression() {
        let dir = getJournaliaDir()
        runInTerminal(command: "cd \(dir) && ./core_journey_regression/run_e2e_regression.sh --gui")
    }

    @objc func runJournaliaUiTest() {
        let dir = getJournaliaDir()
        runInTerminal(command: "cd \(dir) && ./scripts/test_ui_closed_loop.sh")
    }

    @objc func runJournaliaUnitTest() {
        let dir = getJournaliaDir()
        runInTerminal(command: "cd \(dir)/android && ./gradlew :app:testDebugUnitTest")
    }

    @objc func installJournaliaPhone() {
        let dir = getJournaliaDir()
        runInTerminal(command: "cd \(dir) && ./scripts/install_apk.sh --phone --dev")
    }

    @objc func installJournaliaEmulator() {
        let dir = getJournaliaDir()
        runInTerminal(command: "cd \(dir) && ./scripts/install_apk.sh --emulator --dev")
    }

    @objc func startJournaliaEmulatorHeadless() {
        let dir = getJournaliaDir()
        runInTerminal(command: "cd \(dir) && ./scripts/emulator.sh start")
        notify(title: "Journalia", message: "正在啟動 Android 模擬器 (Headless)...")
    }

    @objc func startJournaliaEmulatorGui() {
        let dir = getJournaliaDir()
        runInTerminal(command: "cd \(dir) && ./scripts/emulator.sh start --gui")
        notify(title: "Journalia", message: "正在啟動 Android 模擬器 (GUI)...")
    }

    @objc func stopJournaliaEmulator() {
        let dir = getJournaliaDir()
        notify(title: "Journalia", message: "正在關閉 Android 模擬器...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let task = Process()
            task.launchPath = "/bin/bash"
            var env = ProcessInfo.processInfo.environment
            let extraPath = "/opt/homebrew/bin:/opt/homebrew/share/android-commandlinetools/platform-tools:/opt/homebrew/share/android-commandlinetools/emulator:/usr/local/bin"
            env["PATH"] = "\(extraPath):\(env["PATH"] ?? "/usr/bin:/bin")"
            task.environment = env
            task.arguments = [dir + "/scripts/emulator.sh", "stop"]
            try? task.run()
            task.waitUntilExit()

            let emuStatus = self.checkEmulatorRunning()
            DispatchQueue.main.async {
                self.isEmulatorRunning = emuStatus.running
                self.runningEmulatorId = emuStatus.id
                self.onStatusUpdated?()
                if !emuStatus.running {
                    self.notify(title: "Journalia", message: "模擬器已成功關閉，已釋放記憶體！")
                }
            }
        }
    }

    @objc func deployJournaliaBackend() {
        let dir = getJournaliaDir()
        runInTerminal(command: "cd \(dir) && ./scripts/deploy_star_main.sh")
    }

    @objc func runJournaliaStarDbSync() {
        let dir = getJournaliaDir()
        runInTerminal(command: "cd \(dir) && ./scripts/test_e2e_stardb_lifecycle.sh")
    }

    @objc func openJournaliaTerminal() {
        let dir = getJournaliaDir()
        runInTerminal(command: "cd \(dir)")
    }

    @objc func openWebDev() {
        if let url = URL(string: "http://star-main.tail7d0b73.ts.net/dev/") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openSonarQube() {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", "nc -z 127.0.0.1 9000 || ssh -f -N -L 9000:localhost:9000 star-main"]
            try? task.run()
            task.waitUntilExit()

            DispatchQueue.main.async {
                if let url = URL(string: "http://localhost:9000") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @objc func runBacklogRefinement() {
        let repoPath = getStarComponentsDir()
        let scriptPath = repoPath + "/.agents/skills/star-backlog/scripts/auto-refine.sh"
        notify(title: "STAR Backlog", message: "Launching AGY Nightly Backlog Refinement...")
        runInTerminal(command: "cd \"\(repoPath)\" && bash \"\(scriptPath)\"")
    }

    @objc func viewPendingBacklogs() {
        let repoPath = getStarComponentsDir()
        let scriptPath = repoPath + "/.agents/skills/star-backlog/scripts/backlog.sh"
        runInTerminal(command: "cd \"\(repoPath)\" && bash \"\(scriptPath)\" list")
    }

    @objc func restartBridge() {
        let task = Process()
        task.launchPath = "/bin/bash"
        let script = getStarComponentsDir() + "/scripts/mac_bridge.sh"
        task.arguments = [script, "restart"]
        try? task.run()
    }

    @objc func stopBridgeAndQuit() {
        let task = Process()
        task.launchPath = "/bin/bash"
        let script = getStarComponentsDir() + "/scripts/mac_bridge.sh"
        task.arguments = [script, "stop"]
        try? task.run()
        task.waitUntilExit()
        NSApp.terminate(nil)
    }

    func checkEmulatorRunning() -> (running: Bool, id: String) {
        let task = Process()
        task.launchPath = "/bin/bash"
        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/opt/homebrew/share/android-commandlinetools/platform-tools:/usr/local/bin"
        env["PATH"] = "\(extraPath):\(env["PATH"] ?? "/usr/bin:/bin")"
        task.environment = env
        task.arguments = ["-c", "adb devices 2>/dev/null | grep -E '^emulator-[0-9]+[[:space:]]+device' | awk '{print $1}' | head -n 1"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                return (true, output)
            }
        } catch {
            return (false, "")
        }
        return (false, "")
    }

    func checkBridgeHealth() {
        guard let url = URL(string: "http://127.0.0.1:5005/api/dev/status") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self else { return }
            var running = false
            var ws = ""

            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200, let data = data {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String, status == "ok" {
                    running = true
                    ws = json["active_workspace"] as? String ?? ""
                }
            }

            let emuStatus = self.checkEmulatorRunning()

            DispatchQueue.main.async {
                let changed = (self.isBridgeRunning != running) ||
                              (self.activeWorkspace != ws) ||
                              (self.isEmulatorRunning != emuStatus.running) ||
                              (self.runningEmulatorId != emuStatus.id)
                self.isBridgeRunning = running
                self.activeWorkspace = ws
                self.isEmulatorRunning = emuStatus.running
                self.runningEmulatorId = emuStatus.id
                if changed {
                    self.onStatusUpdated?()
                }
            }
        }.resume()
    }
}
