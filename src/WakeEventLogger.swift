import Foundation

public struct WakeEventRecord: Codable {
    public let id: String
    public let timestamp: String
    public let keyword: String
    public let tokens: [String]
    public let tokenString: String
    public var feedback: String // "correct", "false_trigger", "unlabeled"

    public init(id: String = UUID().uuidString,
                timestamp: String = ISO8601DateFormatter().string(from: Date()),
                keyword: String,
                tokens: [String],
                feedback: String = "unlabeled") {
        self.id = id
        self.timestamp = timestamp
        self.keyword = keyword
        self.tokens = tokens
        self.tokenString = tokens.joined(separator: " ")
        self.feedback = feedback
    }
}

public final class WakeEventLogger: @unchecked Sendable {
    private let logFilePath: String
    private let lock = NSLock()
    private(set) var lastEvent: WakeEventRecord?

    public init(baseDir: String) {
        self.logFilePath = "\(baseDir)/config/wake_events.jsonl"
        ensureFileExists()
    }

    private func ensureFileExists() {
        if !FileManager.default.fileExists(atPath: logFilePath) {
            FileManager.default.createFile(atPath: logFilePath, contents: nil, attributes: nil)
        }
    }

    public func logWakeEvent(keyword: String, tokens: [String]) -> WakeEventRecord {
        lock.lock()
        defer { lock.unlock() }

        let record = WakeEventRecord(keyword: keyword, tokens: tokens, feedback: "unlabeled")
        self.lastEvent = record

        appendRecordToFile(record)
        return record
    }

    public func markLastEvent(feedback: String) {
        lock.lock()
        defer { lock.unlock() }

        guard var event = lastEvent else { return }
        event.feedback = feedback
        self.lastEvent = event

        // Update JSONL: Read all, update the specific ID, write back
        guard let content = try? String(contentsOfFile: logFilePath, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: .newlines)
        var updatedLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.contains("\"id\":\"\(event.id)\"") || trimmed.contains("\"id\": \"\(event.id)\"") {
                if let jsonData = try? JSONEncoder().encode(event),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    updatedLines.append(jsonStr)
                    continue
                }
            }
            updatedLines.append(trimmed)
        }

        let newContent = updatedLines.joined(separator: "\n") + "\n"
        try? newContent.write(toFile: logFilePath, atomically: true, encoding: .utf8)
        print("📝 [WakeEventLogger] Marked event \(event.id) (\(event.keyword): \(event.tokenString)) as '\(feedback)'")
    }

    private func appendRecordToFile(_ record: WakeEventRecord) {
        guard let jsonData = try? JSONEncoder().encode(record),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return
        }

        if let fileHandle = FileHandle(forWritingAtPath: logFilePath) {
            defer { fileHandle.closeFile() }
            fileHandle.seekToEndOfFile()
            if let lineData = (jsonStr + "\n").data(using: .utf8) {
                fileHandle.write(lineData)
            }
        }
    }
}
