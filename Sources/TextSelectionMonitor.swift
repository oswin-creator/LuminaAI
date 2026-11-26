import Foundation
import AppKit
import ApplicationServices

final class TextSelectionMonitor {
    static let shared = TextSelectionMonitor()

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var mouseDownLocation: NSPoint?
    private var isDragging = false
    private var lastTriggerTime: Date = .distantPast

    var onTextSelected: ((String, NSPoint) -> Void)?
    var onDismissRequested: (() -> Void)?

    private init() {}

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleGlobalMouseEvent(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleLocalMouseDown(event)
            return event
        }
        AppLogger.shared.info("TextSelectionMonitor started")
    }

    func stop() {
        if let m = globalMouseMonitor {
            NSEvent.removeMonitor(m)
            globalMouseMonitor = nil
        }
        if let m = localMouseMonitor {
            NSEvent.removeMonitor(m)
            localMouseMonitor = nil
        }
    }

    private func handleLocalMouseDown(_ event: NSEvent) {
        // If user clicks inside our own non-capsule window (like main dashboard), dismiss the capsule
        if let win = event.window, win.identifier?.rawValue != "LuminaSelectionCapsule" {
            onDismissRequested?()
        }
    }

    private func handleGlobalMouseEvent(_ event: NSEvent) {
        guard SettingsStore.shared.enableTextSelectionPopup else { return }

        switch event.type {
        case .leftMouseDown:
            mouseDownLocation = NSEvent.mouseLocation
            isDragging = false
            // Dismiss existing capsule if clicking elsewhere
            onDismissRequested?()

        case .rightMouseDown:
            onDismissRequested?()

        case .leftMouseDragged:
            if let start = mouseDownLocation {
                let current = NSEvent.mouseLocation
                let dist = hypot(current.x - start.x, current.y - start.y)
                if dist > 8 {
                    isDragging = true
                }
            }

        case .leftMouseUp:
            let mouseLoc = NSEvent.mouseLocation
            let shouldCheck = isDragging || event.clickCount >= 2
            mouseDownLocation = nil
            isDragging = false

            guard shouldCheck else { return }
            guard Date().timeIntervalSince(lastTriggerTime) > 0.25 else { return }

            if !AXIsProcessTrusted() {
                PermissionManager.shared.refreshStatus()
                return
            }

            // Slight delay so target app finishes updating its selection state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.extractAndTrigger(at: mouseLoc)
            }

        default:
            break
        }
    }

    private func extractAndTrigger(at screenPoint: NSPoint) {
        if let axText = readSelectedTextViaAccessibility(),
           !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastTriggerTime = Date()
            onTextSelected?(axText.trimmingCharacters(in: .whitespacesAndNewlines), screenPoint)
            return
        }

        if SettingsStore.shared.useClipboardFallbackForSelection {
            readSelectedTextViaClipboardFallback { [weak self] text in
                guard let self = self,
                      let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return }
                self.lastTriggerTime = Date()
                self.onTextSelected?(text, screenPoint)
            }
        }
    }

    private func readSelectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObj: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedObj)
        guard focusErr == .success, let focused = focusedObj else { return nil }

        let focusedElement = focused as! AXUIElement
        var selectedTextObj: CFTypeRef?
        let textErr = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &selectedTextObj)
        if textErr == .success, let str = selectedTextObj as? String, !str.isEmpty {
            return str
        }
        return nil
    }

    private func readSelectedTextViaClipboardFallback(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let previousChangeCount = pb.changeCount
        let previousString = pb.string(forType: .string)

        // Synthesize Cmd+C
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKeyCode: CGKeyCode = 8 // kVK_ANSI_C
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false) else {
            completion(nil)
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            let newCount = pb.changeCount
            guard newCount != previousChangeCount else {
                completion(nil)
                return
            }
            let copied = pb.string(forType: .string)
            // Restore previous string clipboard if there was one
            if let prev = previousString {
                pb.clearContents()
                pb.setString(prev, forType: .string)
            }
            completion(copied)
        }
    }
}
