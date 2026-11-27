import Foundation
import Carbon

final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var screenshotHotKeyRef: EventHotKeyRef?
    private var radialHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var screenshotCallback: (() -> Void)?
    private var radialPressedCallback: (() -> Void)?
    private var radialReleasedCallback: (() -> Void)?

    private let signature: OSType = 0x4C4D4E41 // 'LMNA'

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenshotHotkeyChanged(_:)),
            name: .luminaHotkeyDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRadialHotkeyChanged(_:)),
            name: .luminaRadialHotkeyDidChange,
            object: nil
        )
    }

    func start(
        onScreenshot: @escaping () -> Void,
        onRadialPressed: @escaping () -> Void,
        onRadialReleased: @escaping () -> Void
    ) {
        self.screenshotCallback = onScreenshot
        self.radialPressedCallback = onRadialPressed
        self.radialReleasedCallback = onRadialReleased
        installEventHandlerIfNeeded()
        registerScreenshot(config: SettingsStore.shared.screenshotHotkey)
        registerRadial(config: SettingsStore.shared.radialHotkey)
    }

    func stop() {
        unregisterScreenshot()
        unregisterRadial()
    }

    @objc private func handleScreenshotHotkeyChanged(_ notification: Notification) {
        let config = (notification.object as? HotkeyConfig) ?? SettingsStore.shared.screenshotHotkey
        registerScreenshot(config: config)
    }

    @objc private func handleRadialHotkeyChanged(_ notification: Notification) {
        let config = (notification.object as? HotkeyConfig) ?? SettingsStore.shared.radialHotkey
        registerRadial(config: config)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let handler: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            guard let eventRef = eventRef else { return noErr }
            let eventKind = GetEventKind(eventRef)
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
            guard status == noErr else { return noErr }

            if hotKeyID.id == 1 && eventKind == UInt32(kEventHotKeyPressed) {
                DispatchQueue.main.async {
                    GlobalHotkeyManager.shared.screenshotCallback?()
                }
            } else if hotKeyID.id == 2 {
                if eventKind == UInt32(kEventHotKeyPressed) {
                    DispatchQueue.main.async {
                        GlobalHotkeyManager.shared.radialPressedCallback?()
                    }
                } else if eventKind == UInt32(kEventHotKeyReleased) {
                    DispatchQueue.main.async {
                        GlobalHotkeyManager.shared.radialReleasedCallback?()
                    }
                }
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandlerRef
        )
        if status != noErr {
            AppLogger.shared.error("Failed to install Carbon hotkey event handler (status: \(status))")
        }
    }

    func registerScreenshot(config: HotkeyConfig) {
        unregisterScreenshot()
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &screenshotHotKeyRef
        )
        if status == noErr {
            AppLogger.shared.info("Registered global screenshot hotkey: \(config.displayString)")
        } else {
            AppLogger.shared.error("Failed to register screenshot hotkey \(config.displayString) (status: \(status))")
        }
    }

    func registerRadial(config: HotkeyConfig) {
        unregisterRadial()
        let hotKeyID = EventHotKeyID(signature: signature, id: 2)
        let status = RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &radialHotKeyRef
        )
        if status == noErr {
            AppLogger.shared.info("Registered global radial menu hotkey: \(config.displayString)")
        } else {
            AppLogger.shared.error("Failed to register radial hotkey \(config.displayString) (status: \(status))")
        }
    }

    private func unregisterScreenshot() {
        if let ref = screenshotHotKeyRef {
            UnregisterEventHotKey(ref)
            screenshotHotKeyRef = nil
        }
    }

    private func unregisterRadial() {
        if let ref = radialHotKeyRef {
            UnregisterEventHotKey(ref)
            radialHotKeyRef = nil
        }
    }
}
