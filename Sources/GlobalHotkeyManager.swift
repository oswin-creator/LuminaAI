import Foundation
import Carbon

final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var callback: (() -> Void)?
    private let signature: OSType = 0x4C4D4E41 // 'LMNA'

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyChanged(_:)),
            name: .luminaHotkeyDidChange,
            object: nil
        )
    }

    func start(onTrigger: @escaping () -> Void) {
        self.callback = onTrigger
        installEventHandlerIfNeeded()
        register(config: SettingsStore.shared.screenshotHotkey)
    }

    func stop() {
        unregister()
    }

    @objc private func handleHotkeyChanged(_ notification: Notification) {
        let config = (notification.object as? HotkeyConfig) ?? SettingsStore.shared.screenshotHotkey
        register(config: config)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            guard let eventRef = eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr && hotKeyID.id == 1 {
                DispatchQueue.main.async {
                    GlobalHotkeyManager.shared.callback?()
                }
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        if status != noErr {
            AppLogger.shared.error("Failed to install Carbon hotkey event handler (status: \(status))")
        }
    }

    func register(config: HotkeyConfig) {
        unregister()
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            AppLogger.shared.info("Registered global screenshot hotkey: \(config.displayString)")
        } else {
            AppLogger.shared.error("Failed to register global hotkey \(config.displayString) (status: \(status))")
        }
    }

    private func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }
}
