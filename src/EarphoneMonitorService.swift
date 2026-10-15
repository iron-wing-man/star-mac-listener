import Foundation
import CoreAudio

class EarphoneMonitorService {
    var targetNames: [String] = ["JLab Flex"]
    var onConnectionChanged: ((Bool, String?) -> Void)?

    private(set) var isEarphoneConnected: Bool = false
    private(set) var connectedDeviceName: String?
    private var debounceWorkItem: DispatchWorkItem?
    private let listenerQueue = DispatchQueue(label: "com.jasper.starlistener.coreaudio")

    func start(targetNames: [String]) {
        self.targetNames = targetNames
        let (connected, name) = checkTargetEarphonePresent()
        self.isEarphoneConnected = connected
        self.connectedDeviceName = name

        registerCoreAudioListeners()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onConnectionChanged?(self.isEarphoneConnected, self.connectedDeviceName)
        }
    }

    private func registerCoreAudioListeners() {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                listenerQueue
            ) { [weak self] _, _ in
                self?.scheduleCheck()
            }
        }
    }

    private func scheduleCheck() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.debounceWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let (connected, name) = self.checkTargetEarphonePresent()
                if connected != self.isEarphoneConnected || name != self.connectedDeviceName {
                    self.isEarphoneConnected = connected
                    self.connectedDeviceName = name
                    print("🎧 [EarphoneMonitor] Connection state changed: connected=\(connected), device=\(name ?? "none")")
                    self.onConnectionChanged?(connected, name)
                }
            }
            self.debounceWorkItem = item
            // 1.0s settle debounce so Bluetooth HFP/A2DP streams are ready in CoreAudio before starting sherpa-onnx
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
        }
    }

    func checkTargetEarphonePresent() -> (Bool, String?) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let statusSize = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        guard statusSize == noErr, dataSize > 0 else {
            return (false, nil)
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        let statusData = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard statusData == noErr else {
            return (false, nil)
        }

        for id in deviceIDs {
            if let deviceName = getDeviceName(deviceID: id) {
                for target in targetNames {
                    if deviceName.localizedCaseInsensitiveContains(target) {
                        return (true, deviceName)
                    }
                }
            }
        }
        return (false, nil)
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            return AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &dataSize, ptr)
        }
        guard status == noErr else { return nil }
        return name as String
    }
}
