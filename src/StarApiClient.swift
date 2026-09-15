import Foundation

enum StarError: Error {
    case networkError(String)
    case unrecognizedSpeaker
    case pipelineFailed
    case timeout
    case badResponse
}

class StarApiClient {
    let config: StarConfig
    private let session = URLSession.shared
    
    init(config: StarConfig) {
        self.config = config
    }
    
    func sendAudio(pcmData: Data) async throws -> Int {
        guard let url = URL(string: "http://\(config.starHost):\(config.starPort)/web_request") else {
            throw StarError.networkError("Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.clientId, forHTTPHeaderField: "X-Response-IP")
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
        
        print("✅ POST /web_request success, id: \(id)")
        return id
    }
    
    func pollStats(messageId: Int) async throws -> URL {
        guard let url = URL(string: "http://\(config.starHost):\(config.starPort)/web_request_stats?id=\(messageId)") else {
            throw StarError.networkError("Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.setValue(config.clientId, forHTTPHeaderField: "X-Response-IP") // Needs X-Real-IP or X-Response-IP depending on how backend reads it. Wait, the backend uses X-Real-IP or request.client.host, but for web_request_stats it uses X-Real-IP. Actually we should set X-Real-IP if it expects that, but the backend uses `sender_ip = request.headers.get("X-Real-IP", request.client.host)`. So we don't strictly need it if we are on the same network, but let's set it.
        request.setValue(config.clientId, forHTTPHeaderField: "X-Real-IP")
        
        let maxAttempts = 30 // 45 seconds total (1.5s * 30)
        
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
                    } else if status == "failed" || status == "ignored" {
                        print("❌ Request \(status)")
                        throw StarError.pipelineFailed
                    }
                    // status is "processing" or "requested" or "idle", continue polling
                    print("⏳ Polling... status: \(status)")
                }
            }
            
            try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
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
