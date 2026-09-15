import Foundation
import AVFoundation

class AudioCaptureService {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pcmData = Data()
    
    private var isRecording = false
    private var speechStarted = false
    private var silenceStartTime: Date?
    private var recordStartTime: Date?
    
    func startRecording(config: StarConfig, onFinished: @escaping (Data) -> Void) {
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        
        // 目標格式：16kHz, Mono, 16-bit Int
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false) else {
            print("❌ Failed to create target format")
            return
        }
        
        converter = AVAudioConverter(from: hardwareFormat, to: targetFormat)
        
        isRecording = true
        speechStarted = false
        silenceStartTime = nil
        pcmData.removeAll()
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, time in
            guard let self = self, self.isRecording else { return }
            
            // 準確計算轉換後的 frame 數量，避免 buffer 溢出或不足
            let sampleRateRatio = 16000.0 / hardwareFormat.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * sampleRateRatio)) + 128
            guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            
            var error: NSError? = nil
            var isBufferConsumed = false
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if isBufferConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                isBufferConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            
            self.converter?.convert(to: targetBuffer, error: &error, withInputFrom: inputBlock)
            
            if let error = error {
                print("Audio conversion error: \(error)")
                return
            }
            
            let frameLength = Int(targetBuffer.frameLength)
            guard frameLength > 0, let channelData = targetBuffer.int16ChannelData?[0] else { return }
            
            // 計算 RMS
            var sum: Float = 0
            for i in 0..<frameLength {
                let sample = Float(channelData[i]) / 32767.0
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameLength))
            
            // 寫入 pcmData
            let bytes = UnsafeBufferPointer(start: channelData, count: frameLength)
            let data = Data(buffer: bytes)
            self.pcmData.append(data)
            
            let now = Date()
            guard let startTime = self.recordStartTime else { return }
            let elapsed = now.timeIntervalSince(startTime)
            
            // 靜音偵測邏輯
            if rms > config.silenceThresholdRms {
                self.speechStarted = true
                self.silenceStartTime = nil
            } else if self.speechStarted {
                if self.silenceStartTime == nil {
                    self.silenceStartTime = now
                }
            }
            
            var shouldStop = false
            if elapsed >= config.maxRecordSec {
                shouldStop = true
            } else if self.speechStarted && elapsed >= config.minRecordSec,
                      let silenceStart = self.silenceStartTime,
                      now.timeIntervalSince(silenceStart) >= config.silenceTimeoutSec {
                shouldStop = true
            }
            
            if shouldStop {
                self.isRecording = false
                self.stopRecording()
                let capturedData = self.pcmData
                onFinished(capturedData)
            }
        }
        
        engine.prepare()
        do {
            try engine.start()
            recordStartTime = Date()
            print("🎙️ Started audio capture (hardware: \(hardwareFormat.sampleRate)Hz, target: 16000Hz)")
        } catch {
            isRecording = false
            print("❌ Failed to start audio engine: \(error)")
        }
    }
    
    func stopRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        print("🛑 Stopped audio capture (captured \(pcmData.count) bytes, approx \(Double(pcmData.count) / 32000.0)s)")
    }
}
