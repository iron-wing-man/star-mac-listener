import Foundation

enum StarError: Error {
    case networkError(String)
    case unrecognizedSpeaker
    case pipelineFailed
    case noSpeechDetected
    case timeout
    case badResponse
}

class StarApiClient {
    let config: StarConfig
    private let session = URLSession.shared
    
    init(config: StarConfig) {
        self.config = config
    }
    
    func sendAudio(pcmData: Data, isAppend: Bool = false, isBargeIn: Bool = false) async throws -> Int {
        guard let url = URL(string: "http://\(config.starHost):\(config.starPort)/api/web_request") else {
            throw StarError.networkError("Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.clientId, forHTTPHeaderField: "X-Response-IP")
        if isAppend {
            request.setValue("append", forHTTPHeaderField: "X-Action")
        }
        if isBargeIn {
            request.setValue("true", forHTTPHeaderField: "X-Barge-In")
        }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = pcmData
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StarError.badResponse
        }
        
        if httpResponse.statusCode == 401 {
            throw StarError.unrecognizedSpeaker
        }
        
        if httpResponse.statusCode != 200 && httpResponse.statusCode != 202 {
            throw StarError.networkError("Server returned \(httpResponse.statusCode)")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let id = json["id"] as? Int else {
            throw StarError.badResponse
        }
        
        let status = json["status"] as? String ?? "ok"
        print("✅ POST /api/web_request success (status: \(status)), id: \(id)")
        return id
    }
    
    func pollStats(messageId: Int) async throws -> URL {
        guard let url = URL(string: "http://\(config.starHost):\(config.starPort)/api/web_request_stats?id=\(messageId)") else {
            throw StarError.networkError("Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.setValue(config.clientId, forHTTPHeaderField: "X-Response-IP")
        request.setValue(config.clientId, forHTTPHeaderField: "X-Real-IP")
        
        let intervalMs = config.fastPollIntervalMs > 0 ? config.fastPollIntervalMs : 250
        let maxAttempts = (45 * 1000) / intervalMs
        var lastStatus = ""
        
        for i in 1...maxAttempts {
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let status = json["status"] as? String {
                    
                    if status == "completed" {
                        guard let voiceUrlString = json["voice_result_url"] as? String,
                              let voiceUrl = URL(string: "http://\(config.starHost):\(config.starPort)\(voiceUrlString)") else {
                            throw StarError.badResponse
                        }
                        print("✅ Poll finished: completed (\(i)/\(maxAttempts))")
                        return voiceUrl
                    } else if status == "ignored" {
                        print("⚠️ Request ignored by server (no speech / empty STT transcript)")
                        throw StarError.noSpeechDetected
                    } else if status == "failed" {
                        print("❌ Request failed")
                        throw StarError.pipelineFailed
                    }
                    if status != lastStatus || i % 4 == 0 {
                        print("⏳ Polling... status: \(status)")
                        lastStatus = status
                    }
                }
            }
            
            try await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }
        
        throw StarError.timeout
    }
    
    func downloadVoiceResult(url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw StarError.badResponse
        }
        print("✅ Downloaded voice result (\(data.count) bytes)")
        return data
    }
}
