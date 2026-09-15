import Cocoa
import Carbon

class GlobalHotKey {
    static var onTrigger: (() -> Void)?
    
    static func register(config: StarConfig) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 1, id: 1)

        var modifierFlags: UInt32 = 0
        for mod in config.hotKeyModifiers {
            switch mod.lowercased() {
            case "command", "cmd": modifierFlags |= UInt32(cmdKey)
            case "option", "alt": modifierFlags |= UInt32(optionKey)
            case "control", "ctrl": modifierFlags |= UInt32(controlKey)
            case "shift": modifierFlags |= UInt32(shiftKey)
            default: break
            }
        }

        let keyCode = UInt32(config.hotKeyCode)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, _) -> OSStatus in
            GlobalHotKey.onTrigger?()
            return noErr
        }, 1, &eventType, nil, nil)
        
        RegisterEventHotKey(keyCode, modifierFlags, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        print("⌨️ Global HotKey registered (Key: \(config.hotKeyCode), Modifiers: \(config.hotKeyModifiers)).")
    }
}
