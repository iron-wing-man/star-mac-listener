import Foundation
import AVFoundation

class AudioPlaybackService: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onPlaybackFinished: (() -> Void)?
    
    func play(wavData: Data) {
        do {
            player = try AVAudioPlayer(data: wavData)
            player?.delegate = self
            player?.play()
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
        if let player = player, player.isPlaying {
            player.stop()
            print("🛑 Audio playback stopped (barge-in)")
        }
        player = nil
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("🔈 Playback finished (success: \(flag))")
        onPlaybackFinished?()
    }
}
