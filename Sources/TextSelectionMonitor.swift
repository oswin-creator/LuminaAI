import Foundation
import AppKit
import ApplicationServices

final class TextSelectionMonitor {
    static let shared = TextSelectionMonitor()

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var mouseDownLocation: NSPoint?
    private var lastTriggerTime: Date = .distantPast

    var onTextSelected: ((String, NSPoint) -> Void)?
    var onDismissRequested: (() -> Void)?

    private init() {}

    func start() {
        stop()
        // Intentionally omit .leftMouseDragged to avoid 60-120Hz background wakeups while dragging in other apps!
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleGlobalMouseEvent(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleLocalMouseDown(event)
            return event
        }
        AppLogger.shared.info("TextSelectionMonitor started (low-power mode)")
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
            onDismissRequested?()

        case .rightMouseDown:
            onDismissRequested?()

        case .leftMouseUp:
            let mouseLoc = NSEvent.mouseLocation
            let dragDist: CGFloat
            if let start = mouseDownLocation {
                dragDist = hypot(mouseLoc.x - start.x, mouseLoc.y - start.y)
            } else {
                dragDist = 0
            }
            let shouldCheck = (dragDist > 8) || (event.clickCount >= 2)
            mouseDownLocation = nil

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

    func readSelectedTextViaAccessibility() -> String? {
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

        // Secondary Accessibility extraction for complex web views: read selected range -> stringForRange
        var rangeObj: CFTypeRef?
        let rangeErr = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &rangeObj)
        if rangeErr == .success, let rangeVal = rangeObj {
            var rangedStrObj: CFTypeRef?
            let strErr = AXUIElementCopyParameterizedAttributeValue(
                focusedElement,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeVal,
                &rangedStrObj
            )
            if strErr == .success, let str = rangedStrObj as? String, !str.isEmpty {
                return str
            }
        }
        return nil
    }

    /// Smart Copy: tries native Cmd+C first; if webpage blocks copy (oncopy / preventDefault),
    /// forcibly writes the Accessibility-extracted text straight to the clipboard!
    func performSmartCopy(fallbackText: String, completion: @escaping (Bool) -> Void) {
        let pb = NSPasteboard.general
        let beforeCount = pb.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let cKeyCode: CGKeyCode = 8 // kVK_ANSI_C
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false) {
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let copiedByDefault = (pb.changeCount != beforeCount) &&
                !(pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

            if copiedByDefault {
                completion(false) // standard Cmd+C succeeded
            } else {
                // Webpage blocked default Cmd+C -> Force-copy via Accessibility text
                let axFresh = self.readSelectedTextViaAccessibility()?.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalText = (axFresh?.isEmpty == false ? axFresh! : fallbackText)
                pb.clearContents()
                pb.setString(finalText, forType: .string)
                completion(true) // force-copy succeeded
            }
        }
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
