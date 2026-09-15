import Foundation

struct StarConfig: Codable {
    var starHost: String = "192.168.4.33"
    var starPort: Int = 5001
    var clientId: String = "mac-listener"
    var minRecordSec: Double = 1.0
    var maxRecordSec: Double = 5.0
    var silenceTimeoutSec: Double = 0.8
    var silenceThresholdRms: Float = 0.015
    var errorDisplaySec: Double = 1.2
    var followUpListenSec: Double = 3.5
    var fastPollIntervalMs: Int = 250
    var hotKeyModifiers: [String] = ["control", "option"]
    var hotKeyCode: Int = 49

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
