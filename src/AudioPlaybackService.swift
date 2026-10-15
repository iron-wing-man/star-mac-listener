import Foundation
import AVFoundation

class AudioPlaybackService: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?
    var onPlaybackFinished: (() -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    
    func play(wavData: Data) {
        stopMeterTimer()
        do {
            player = try AVAudioPlayer(data: wavData)
            player?.delegate = self
            player?.isMeteringEnabled = true
            player?.play()
            startMeterTimer()
            print("🔊 Started playback")
        } catch {
            print("❌ Failed to initialize AVAudioPlayer: \(error)")
            onPlaybackFinished?()
        }
    }
    
    var isPlaying: Bool {
        return player?.isPlaying ?? false
    }

    func stop() {
        stopMeterTimer()
        if let player = player, player.isPlaying {
            player.stop()
            print("🛑 Audio playback stopped (barge-in)")
        }
        player = nil
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopMeterTimer()
        print("🔈 Playback finished (success: \(flag))")
        onPlaybackFinished?()
    }

    private func startMeterTimer() {
        let t = Timer(timeInterval: 0.033, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.player, p.isPlaying else { return }
            p.updateMeters()
            let avgPower = p.averagePower(forChannel: 0) // -160 .. 0 dB
            let normalized = max(0.0, min(1.0, (avgPower + 45.0) / 45.0))
            self.onAudioLevel?(normalized)
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
        onAudioLevel?(0.0)
    }
}
