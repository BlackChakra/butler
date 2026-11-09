import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// A system-wide shortcut that needs no permissions. Option + Command + B calls Butler to the notch.
enum Hotkey {
    nonisolated(unsafe) static var onPress: (() -> Void)?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        onPress = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Hotkey.onPress?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4254_4C52), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

/// Launch at login, so reminders still arrive after a restart.
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSLog("Butler login item: \(error.localizedDescription)") }
    }
}
