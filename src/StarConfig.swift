import Foundation

struct StarConfig: Codable {
    var starHost: String = "192.168.4.33"
    var starPort: Int = 5001
    var clientId: String = "mac-listener"
    var minRecordSec: Double = 1.0
    var maxRecordSec: Double = 15.0
    var silenceTimeoutSec: Double = 1.5
    var silenceThresholdRms: Float = 0.015
    var errorDisplaySec: Double = 1.2
    var followUpListenSec: Double = 3.5
    var fastPollIntervalMs: Int = 250
    var hotKeyModifiers: [String] = ["control", "option"]
    var hotKeyCode: Int = 49
    var requireEarphoneForAutoWake: Bool = true
    var targetEarphoneNames: [String] = ["JLab Flex"]
    var ttsLockFile: String = "/tmp/star_mac_tts_playing.lock"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        starHost = try c.decodeIfPresent(String.self, forKey: .starHost) ?? "192.168.4.33"
        starPort = try c.decodeIfPresent(Int.self, forKey: .starPort) ?? 5001
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId) ?? "mac-listener"
        minRecordSec = try c.decodeIfPresent(Double.self, forKey: .minRecordSec) ?? 1.0
        maxRecordSec = try c.decodeIfPresent(Double.self, forKey: .maxRecordSec) ?? 15.0
        silenceTimeoutSec = try c.decodeIfPresent(Double.self, forKey: .silenceTimeoutSec) ?? 1.5
        silenceThresholdRms = try c.decodeIfPresent(Float.self, forKey: .silenceThresholdRms) ?? 0.015
        errorDisplaySec = try c.decodeIfPresent(Double.self, forKey: .errorDisplaySec) ?? 1.2
        followUpListenSec = try c.decodeIfPresent(Double.self, forKey: .followUpListenSec) ?? 3.5
        fastPollIntervalMs = try c.decodeIfPresent(Int.self, forKey: .fastPollIntervalMs) ?? 250
        hotKeyModifiers = try c.decodeIfPresent([String].self, forKey: .hotKeyModifiers) ?? ["control", "option"]
        hotKeyCode = try c.decodeIfPresent(Int.self, forKey: .hotKeyCode) ?? 49
        requireEarphoneForAutoWake = try c.decodeIfPresent(Bool.self, forKey: .requireEarphoneForAutoWake) ?? true
        targetEarphoneNames = try c.decodeIfPresent([String].self, forKey: .targetEarphoneNames) ?? ["JLab Flex"]
        ttsLockFile = try c.decodeIfPresent(String.self, forKey: .ttsLockFile) ?? "/tmp/star_mac_tts_playing.lock"
    }

    static func load(from directory: String) -> StarConfig {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(StarConfig.self, from: data) else {
            print("⚠️ 載入 config.json 失敗，使用預設設定")
            return StarConfig()
        }
        return config
    }
}
