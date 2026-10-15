import Cocoa

class StellaIconAnimator {
    private weak var statusItem: NSStatusItem?
    private var frames: [NSImage] = []
    private var timer: Timer?
    private var currentStep = 0
    private(set) var isSpinning = false

    // 24 frames per full 360° rotation (~33ms/frame = 0.8s spin) + 15 ticks (~0.5s) pause at 0°
    private let totalFrames = 24
    private let pauseTicks = 15
    private let tickInterval: TimeInterval = 0.033

    init(statusItem: NSStatusItem, baseDir: String) {
        self.statusItem = statusItem
        loadAndGenerateFrames(baseDir: baseDir)
        applyStaticIcon()
    }

    private func loadAndGenerateFrames(baseDir: String) {
        let possiblePaths = [
            Bundle.main.resourcePath.map { "\($0)/stella_colored_vector.svg" } ?? "",
            "\(baseDir)/assets/stella_colored_vector.svg",
            NSHomeDirectory() + "/Developer/star/star-mac-bridge-bar/stella_colored_vector.svg",
            NSHomeDirectory() + "/Developer/star/starship/stella_colored_vector.svg"
        ]

        var baseImage: NSImage?
        for path in possiblePaths where !path.isEmpty {
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                baseImage = img
                break
            }
        }

        guard let sourceImage = baseImage else {
            return
        }

        let size = NSSize(width: 18, height: 18)
        frames.removeAll()

        for i in 0..<totalFrames {
            let angleDegrees = -CGFloat(i) * (360.0 / CGFloat(totalFrames))
            let rotated = NSImage(size: size, flipped: false) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.saveGState()
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: angleDegrees * .pi / 180.0)
                ctx.translateBy(x: -rect.midX, y: -rect.midY)
                sourceImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                ctx.restoreGState()
                return true
            }
            rotated.isTemplate = true
            frames.append(rotated)
        }
    }

    func startSpinning() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isSpinning { return }
            self.isSpinning = true
            self.currentStep = 0
            self.timer?.invalidate()

            guard !self.frames.isEmpty else {
                self.statusItem?.button?.title = "☆"
                return
            }

            self.statusItem?.button?.title = ""
            self.statusItem?.button?.imagePosition = .imageOnly
            self.statusItem?.button?.image = self.frames[0]

            let t = Timer(timeInterval: self.tickInterval, repeats: true) { [weak self] _ in
                guard let self = self, self.isSpinning else { return }
                let cycleLength = self.totalFrames + self.pauseTicks
                self.currentStep = (self.currentStep + 1) % cycleLength
                let frameIndex = self.currentStep < self.totalFrames ? self.currentStep : 0
                self.statusItem?.button?.image = self.frames[frameIndex]
            }
            RunLoop.main.add(t, forMode: .common)
            self.timer = t
        }
    }

    func stopSpinning() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isSpinning = false
            self.timer?.invalidate()
            self.timer = nil
            self.currentStep = 0
            self.applyStaticIcon()
        }
    }

    private func applyStaticIcon() {
        guard let button = statusItem?.button else { return }
        if let first = frames.first {
            button.image = first
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.image = nil
            button.title = "😴"
        }
    }
}
