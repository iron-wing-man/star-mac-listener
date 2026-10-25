import Cocoa
import WebKit

final class VoiceOrbPanel: NSPanel {
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }
}

final class VoiceOrbHudController: NSObject, WKNavigationDelegate {
    private var panel: VoiceOrbPanel!
    private var webView: WKWebView!
    private var isPageLoaded = false
    private var pendingJS: [String] = []
    private var hideWorkItem: DispatchWorkItem?
    private var lastLevelSentTime: TimeInterval = 0
    private(set) var isVisible = false

    override init() {
        super.init()
        setupPanel()
    }

    private func topRightRect() -> NSRect {
        let size = NSSize(width: 360, height: 360)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 16.0
        let origin = NSPoint(
            x: screenFrame.maxX - size.width - margin,
            y: screenFrame.maxY - size.height - margin
        )
        return NSRect(origin: origin, size: size)
    }

    private func setupPanel() {
        let rect = topRightRect()
        panel = VoiceOrbPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(origin: .zero, size: rect.size), configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        panel.contentView = webView
        webView.loadHTMLString(Self.orbHTML, baseURL: nil)
        panel.orderOut(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        for js in pendingJS {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        pendingJS.removeAll()
    }

    private func evalJS(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isPageLoaded {
                self.webView.evaluateJavaScript(js, completionHandler: nil)
            } else {
                self.pendingJS.append(js)
            }
        }
    }

    func show(mode: String, caption: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.hideWorkItem?.cancel()
            self.hideWorkItem = nil
            self.panel.setFrame(self.topRightRect(), display: false)
            if !self.isVisible {
                self.isVisible = true
                self.panel.alphaValue = 1.0
                self.panel.orderFrontRegardless()
            }
            let safeMode = mode.replacingOccurrences(of: "'", with: "")
            let safeCaption = caption.replacingOccurrences(of: "'", with: "\\'")
            self.evalJS("window.showVoiceOrb('\(safeMode)', '\(safeCaption)');")
        }
    }

    func setMode(_ mode: String, caption: String) {
        show(mode: mode, caption: caption)
    }

    func updateAudioLevel(_ normalizedLevel: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelSentTime >= 0.033 else { return } // Throttle to ~30fps
        lastLevelSentTime = now
        let clamped = max(0.0, min(1.0, normalizedLevel))
        evalJS(String(format: "window.updateOrbLevel(%.3f);", clamped))
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isVisible else { return }
            self.isVisible = false
            self.evalJS("window.hideVoiceOrb();")
            self.hideWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self = self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
            self.hideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.48, execute: item)
        }
    }

    private static let orbHTML = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="UTF-8">
    <style>
    :root {
      --stella-cyan: #89CFF0;
      --stella-pink: #f43f5e;
      --stella-pink-glow: rgba(244, 63, 94, 0.4);
      --stella-cyan-glow: rgba(137, 207, 240, 0.4);
      --border-cyan: rgba(137, 207, 240, 0.28);
      --font-mono: "SF Mono", "Fira Code", Menlo, Monaco, Consolas, monospace;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body {
      width: 100%;
      height: 100%;
      background: transparent !important;
      overflow: hidden;
      user-select: none;
      -webkit-user-select: none;
    }
    .central-voice-orb {
      position: absolute;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%) scale(0.55);
      width: 340px;
      height: 340px;
      display: flex;
      align-items: center;
      justify-content: center;
      pointer-events: none;
      opacity: 0;
      transition: opacity 0.42s cubic-bezier(0.16, 1, 0.3, 1), transform 0.48s cubic-bezier(0.16, 1, 0.3, 1);
    }
    .central-voice-orb.active {
      opacity: 1;
      transform: translate(-50%, -50%) scale(1);
    }
    .central-voice-orb.hidden {
      opacity: 0;
      transform: translate(-50%, -50%) scale(0.5);
    }
    .orb-backdrop-glow {
      position: absolute;
      width: 280px;
      height: 280px;
      border-radius: 50%;
      background: radial-gradient(circle, rgba(16, 185, 129, 0.22) 0%, rgba(137, 207, 240, 0.12) 45%, transparent 70%);
      animation: orb-glow-pulse 3s infinite ease-in-out;
      filter: blur(8px);
    }
    .central-voice-orb.playing .orb-backdrop-glow {
      background: radial-gradient(circle, rgba(244, 63, 94, 0.32) 0%, rgba(137, 207, 240, 0.22) 45%, transparent 70%);
      animation: orb-glow-pulse-intense 1s infinite alternate ease-in-out;
    }
    @keyframes orb-glow-pulse {
      0%, 100% { transform: scale(0.92); opacity: 0.65; }
      50% { transform: scale(1.12); opacity: 0.98; }
    }
    @keyframes orb-glow-pulse-intense {
      0% { transform: scale(1); opacity: 0.75; }
      100% { transform: scale(1.25); opacity: 1; }
    }
    #orb-wave-canvas {
      position: absolute;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
    }
    .orb-center-core {
      position: absolute;
      width: 80px;
      height: 80px;
      border-radius: 50%;
      background: rgba(6, 17, 33, 0.88);
      border: 1.5px solid var(--border-cyan);
      box-shadow: 0 0 25px rgba(137, 207, 240, 0.35), inset 0 0 15px rgba(16, 185, 129, 0.2);
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 2px;
      backdrop-filter: blur(10px);
      -webkit-backdrop-filter: blur(10px);
      transition: all 0.3s ease;
    }
    .central-voice-orb.playing .orb-center-core {
      border-color: var(--stella-pink);
      box-shadow: 0 0 35px var(--stella-pink-glow), inset 0 0 20px rgba(244, 63, 94, 0.3);
    }
    .orb-icon {
      font-size: 1.1rem;
      color: var(--stella-pink);
      text-shadow: 0 0 10px var(--stella-pink-glow);
      animation: star-spin 6s linear infinite;
    }
    @keyframes star-spin {
      0% { transform: rotate(0deg); }
      100% { transform: rotate(360deg); }
    }
    .orb-status-text {
      font-family: var(--font-mono);
      font-size: 0.58rem;
      font-weight: 800;
      letter-spacing: 0.1em;
      color: #10b981;
      text-shadow: 0 0 8px rgba(16, 185, 129, 0.5);
    }
    .central-voice-orb.playing .orb-status-text {
      color: var(--stella-pink);
      text-shadow: 0 0 8px var(--stella-pink-glow);
    }
    .orb-ripple {
      position: absolute;
      border-radius: 50%;
      border: 1px dashed rgba(137, 207, 240, 0.32);
      pointer-events: none;
    }
    .orb-ripple.ring-1 {
      width: 190px;
      height: 190px;
      animation: orb-ripple-anim 4s infinite linear;
    }
    .orb-ripple.ring-2 {
      width: 250px;
      height: 250px;
      animation: orb-ripple-anim 6s infinite reverse linear;
    }
    @keyframes orb-ripple-anim {
      0% { transform: rotate(0deg); opacity: 0.4; }
      50% { opacity: 0.82; }
      100% { transform: rotate(360deg); opacity: 0.4; }
    }
    .orb-hud-caption {
      position: absolute;
      bottom: 12px;
      left: 50%;
      transform: translateX(-50%);
      font-family: var(--font-mono);
      font-size: 0.72rem;
      font-weight: 800;
      letter-spacing: 0.14em;
      color: var(--stella-cyan);
      background: rgba(6, 17, 33, 0.9);
      border: 1px solid var(--border-cyan);
      padding: 5px 16px;
      border-radius: 9999px;
      box-shadow: 0 0 16px rgba(137, 207, 240, 0.35);
      white-space: nowrap;
      animation: caption-pulse 2.2s infinite ease-in-out;
    }
    @keyframes caption-pulse {
      0%, 100% { opacity: 0.8; transform: translateX(-50%) scale(1); }
      50% { opacity: 1; transform: translateX(-50%) scale(1.03); }
    }
    </style>
    </head>
    <body>
      <div id="central-voice-orb" class="central-voice-orb hidden">
        <div class="orb-backdrop-glow"></div>
        <canvas id="orb-wave-canvas" width="400" height="400"></canvas>
        <div class="orb-center-core">
          <span class="orb-icon">✦</span>
          <span class="orb-status-text" id="orb-status-text"></span>
        </div>
        <div class="orb-ripple ring-1"></div>
        <div class="orb-ripple ring-2"></div>
        <div class="orb-hud-caption" id="orb-hud-caption" style="display: none;"></div>
      </div>
      <script>
      const orbContainer = document.getElementById("central-voice-orb");
      const orbCanvas = document.getElementById("orb-wave-canvas");
      const orbCtx = orbCanvas.getContext("2d");
      const orbStatusText = document.getElementById("orb-status-text");
      const orbHudCaption = document.getElementById("orb-hud-caption");

      let orbMode = "hearing";
      let isOrbVisible = false;
      let orbAnimFrame = null;
      let audioLevel = 0.0;
      let smoothedLevel = 0.0;

      window.updateOrbLevel = function(lvl) {
        audioLevel = Math.max(0, Math.min(1, lvl));
      };

      window.showVoiceOrb = function(mode, caption) {
        orbMode = mode || "hearing";
        orbContainer.classList.remove("hidden");
        orbContainer.classList.add("active");
        if (orbMode === "playing") {
          orbContainer.classList.add("playing");
          orbStatusText.textContent = "STELLA";
        } else if (orbMode === "waiting_agy") {
          orbContainer.classList.remove("playing");
          orbStatusText.textContent = "AGY SYNC";
        } else if (orbMode === "followup") {
          orbContainer.classList.remove("playing");
          orbStatusText.textContent = "FOLLOW-UP";
        } else {
          orbContainer.classList.remove("playing");
          orbStatusText.textContent = "";
        }
        if (caption && caption.length > 0 && !caption.includes("LISTENING")) {
          orbHudCaption.style.display = "block";
          orbHudCaption.textContent = caption;
        } else {
          orbHudCaption.style.display = "none";
          orbHudCaption.textContent = "";
        }
        isOrbVisible = true;
        if (!orbAnimFrame) {
          orbAnimFrame = requestAnimationFrame(renderVoiceOrb);
        }
      };

      window.hideVoiceOrb = function() {
        orbContainer.classList.remove("active");
        orbContainer.classList.add("hidden");
        isOrbVisible = false;
        audioLevel = 0;
        if (orbAnimFrame) {
          cancelAnimationFrame(orbAnimFrame);
          orbAnimFrame = null;
        }
      };

      function renderVoiceOrb() {
        if (!isOrbVisible) return;
        smoothedLevel = smoothedLevel * 0.72 + audioLevel * 0.28;
        const width = orbCanvas.width;
        const height = orbCanvas.height;
        const cx = width / 2;
        const cy = height / 2;
        const now = performance.now() / 1000;

        orbCtx.clearRect(0, 0, width, height);
        const numRays = 72;
        const baseRadius = 66;

        for (let i = 0; i < numRays; i++) {
          const angle = (i / numRays) * Math.PI * 2 - Math.PI / 2;
          let waveHeight = 0;
          const harmonic = Math.abs(Math.sin(now * 6.5 + i * 0.42)) * 0.7 + Math.abs(Math.cos(now * 4.2 - i * 0.28)) * 0.3;

          if (orbMode === "waiting_agy") {
            const breath = Math.sin(now * 2.8 + (i / numRays) * Math.PI * 4);
            const ripple = Math.cos(now * 1.8 - (i / numRays) * Math.PI * 6);
            waveHeight = 9 + breath * 8 + ripple * 5 + smoothedLevel * 38 * harmonic;
          } else if (orbMode === "playing") {
            const h1 = Math.sin(now * 8 + i * 0.45);
            const h2 = Math.cos(now * 5.2 - i * 0.3);
            waveHeight = 16 + smoothedLevel * 52 * harmonic + Math.abs(h1 * 22) + Math.abs(h2 * 12);
          } else {
            // hearing / followup
            const breath = Math.sin(now * 3.0 + i * 0.2) * 4.5;
            waveHeight = 9 + smoothedLevel * 56 * harmonic + breath;
          }

          const rInner = baseRadius;
          const rOuter = baseRadius + Math.max(4, waveHeight);
          const x1 = cx + Math.cos(angle) * rInner;
          const y1 = cy + Math.sin(angle) * rInner;
          const x2 = cx + Math.cos(angle) * rOuter;
          const y2 = cy + Math.sin(angle) * rOuter;

          const grad = orbCtx.createLinearGradient(x1, y1, x2, y2);
          if (orbMode === "playing") {
            grad.addColorStop(0, "rgba(244, 63, 94, 0.4)");
            grad.addColorStop(0.5, "rgba(244, 63, 94, 0.9)");
            grad.addColorStop(1, "rgba(137, 207, 240, 1)");
            orbCtx.lineWidth = 3.5;
          } else if (orbMode === "waiting_agy") {
            grad.addColorStop(0, "rgba(137, 207, 240, 0.3)");
            grad.addColorStop(0.6, "rgba(192, 132, 252, 0.85)");
            grad.addColorStop(1, "rgba(137, 207, 240, 1)");
            orbCtx.lineWidth = 2.6;
          } else {
            grad.addColorStop(0, "rgba(16, 185, 129, 0.3)");
            grad.addColorStop(0.6, "rgba(16, 185, 129, 0.85)");
            grad.addColorStop(1, "rgba(137, 207, 240, 0.95)");
            orbCtx.lineWidth = 2.8;
          }

          orbCtx.strokeStyle = grad;
          orbCtx.lineCap = "round";
          orbCtx.beginPath();
          orbCtx.moveTo(x1, y1);
          orbCtx.lineTo(x2, y2);
          orbCtx.stroke();
        }

        // Smooth Outer Connecting Energy Ring
        orbCtx.beginPath();
        for (let i = 0; i <= numRays; i++) {
          const angle = (i / numRays) * Math.PI * 2 - Math.PI / 2;
          const harmonic = Math.abs(Math.sin(now * 6.5 + i * 0.42));
          let waveHeight = 0;
          if (orbMode === "waiting_agy") {
            waveHeight = 9 + Math.sin(now * 2.5 + (i / numRays) * Math.PI * 4) * 7 + smoothedLevel * 32 * harmonic;
          } else if (orbMode === "playing") {
            waveHeight = 18 + smoothedLevel * 44 * harmonic + Math.abs(Math.sin(now * 8 + i * 0.45) * 24);
          } else {
            waveHeight = 9 + smoothedLevel * 50 * harmonic + Math.sin(now * 3.0 + i * 0.2) * 4;
          }
          const r = baseRadius + Math.max(4, waveHeight);
          const x = cx + Math.cos(angle) * r;
          const y = cy + Math.sin(angle) * r;
          if (i === 0) orbCtx.moveTo(x, y);
          else orbCtx.lineTo(x, y);
        }
        orbCtx.closePath();
        orbCtx.strokeStyle = orbMode === "playing"
          ? "rgba(244, 63, 94, 0.6)"
          : (orbMode === "waiting_agy" ? "rgba(192, 132, 252, 0.5)" : "rgba(137, 207, 240, 0.45)");
        orbCtx.lineWidth = 1.5;
        orbCtx.stroke();

        orbAnimFrame = requestAnimationFrame(renderVoiceOrb);
      }
      </script>
    </body>
    </html>
    """
}
