import Foundation
import AppKit
import SwiftUI
import Carbon

// MARK: - Radial Menu ViewModel (ObservableObject, Zero @State)

final class RadialMenuViewModel: ObservableObject {
    @Published var slots: [RadialSlot]
    @Published var hoveredIndex: Int? = nil
    @Published var isVisible: Bool = false

    let ringRadius: CGFloat
    let cancelRadius: CGFloat = 38.0

    init(slots: [RadialSlot]) {
        self.slots = slots
        self.ringRadius = slots.count > 6 ? 124.0 : 108.0
    }
}

// MARK: - Radial Menu Manager (Hold-to-Show, Release-to-Trigger, Zero Idle Footprint)

final class RadialMenuManager {
    static let shared = RadialMenuManager()

    private var panel: NSPanel?
    private var vm: RadialMenuViewModel?
    private var centerScreenPoint: NSPoint = .zero
    private var isActive: Bool = false

    // Temporary monitors active ONLY while the radial menu is held open
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private init() {}

    func handleHotkeyPressed() {
        guard SettingsStore.shared.enableRadialMenu else { return }
        guard !isActive else { return }
        let slots = SettingsStore.shared.radialSlots
        guard !slots.isEmpty else {
            ToastHUD.shared.show("快捷轮盘暂无槽位，请先在设置中添加")
            return
        }

        isActive = true
        let viewModel = RadialMenuViewModel(slots: slots)
        self.vm = viewModel

        let panelSize: CGFloat = (viewModel.ringRadius + 78) * 2
        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let half = panelSize / 2
        let clampedX = max(bounds.minX + half + 6, min(mouseLoc.x, bounds.maxX - half - 6))
        let clampedY = max(bounds.minY + half + 6, min(mouseLoc.y, bounds.maxY - half - 6))
        self.centerScreenPoint = NSPoint(x: clampedX, y: clampedY)

        let frame = NSRect(x: clampedX - half, y: clampedY - half, width: panelSize, height: panelSize)
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false // Individual bubbles draw airy shadows inside transparent bounds
        p.ignoresMouseEvents = true // Never steals clicks or focus from foreground app
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let hosting = NSHostingView(rootView: RadialMenuCanvasView(vm: viewModel, panelSize: panelSize))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = hosting
        p.orderFrontRegardless()
        self.panel = p

        installTemporaryMonitors()

        // Smooth pop-in animation
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.20, dampingFraction: 0.78)) {
                viewModel.isVisible = true
            }
        }
    }

    func handleHotkeyReleased() {
        guard isActive else { return }
        let selectedSlot: RadialSlot?
        if let vm = vm, let idx = vm.hoveredIndex, idx >= 0 && idx < vm.slots.count {
            selectedSlot = vm.slots[idx]
        } else {
            selectedSlot = nil
        }

        dismissImmediately()

        if let slot = selectedSlot {
            execute(slot: slot)
        }
    }

    func cancelWithoutAction() {
        guard isActive else { return }
        dismissImmediately()
    }

    private func dismissImmediately() {
        isActive = false
        removeTemporaryMonitors()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        vm = nil
    }

    private func installTemporaryMonitors() {
        removeTemporaryMonitors()

        let mouseMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] _ in
            self?.updateHoverFromMouse()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            self?.updateHoverFromMouse()
            return event
        }

        // Allow Esc to cancel, and also trigger release if required modifiers are let go before main key
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleMonitorKeyEvent(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleMonitorKeyEvent(event)
            return event
        }
    }

    private func removeTemporaryMonitors() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
    }

    private func handleMonitorKeyEvent(_ event: NSEvent) {
        guard isActive else { return }
        if event.type == .keyDown && event.keyCode == 53 { // Escape cancels cleanly
            cancelWithoutAction()
            return
        }
        if event.type == .flagsChanged {
            let requiredMods = SettingsStore.shared.radialHotkey.modifiers
            if requiredMods != 0 {
                let currentMods = HotkeyConfig.carbonModifiers(from: event.modifierFlags)
                if (currentMods & requiredMods) != requiredMods {
                    // User released modifier key first -> trigger release cleanly
                    handleHotkeyReleased()
                }
            }
        }
    }

    private func updateHoverFromMouse() {
        guard isActive, let vm = vm, !vm.slots.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - centerScreenPoint.x
        let dy = mouse.y - centerScreenPoint.y
        let dist = hypot(dx, dy)

        let newIndex: Int?
        if dist < vm.cancelRadius {
            newIndex = nil
        } else {
            // Angle clockwise starting from 12 o'clock (+Y is up in macOS screen coordinates)
            var angle = atan2(dx, dy) // 0 at top, +pi/2 at right, pi at bottom, -pi/2 at left
            if angle < 0 { angle += 2 * .pi }
            let count = vm.slots.count
            let slice = (2 * .pi) / Double(count)
            let shifted = (angle + slice / 2).truncatingRemainder(dividingBy: 2 * .pi)
            newIndex = min(count - 1, max(0, Int(shifted / slice)))
        }

        if vm.hoveredIndex != newIndex {
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.12)) {
                    vm.hoveredIndex = newIndex
                }
            }
        }
    }

    private func execute(slot: RadialSlot) {
        switch slot.actionType {
        case .launchApp:
            let path = slot.appPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
                ToastHUD.shared.show("未找到应用：\(slot.title)")
                AppLogger.shared.warn("Radial slot app not found: \(path)")
                return
            }
            let url = URL(fileURLWithPath: path)
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
                if let error = error {
                    AppLogger.shared.error("Radial launch app failed (\(path)): \(error.localizedDescription)")
                }
            }

        case .sendShortcut:
            if !AXIsProcessTrusted() {
                PermissionManager.shared.refreshStatus()
                PermissionManager.shared.showGuideModal = true
                NotificationCenter.default.post(name: .luminaShowPermissionGuide, object: nil)
                return
            }
            let hotkey = slot.shortcut
            // Tiny 45ms delay so released trigger key events settle before synthesizing target shortcut
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) {
                Self.simulateShortcut(hotkey)
            }
        }
    }

    private static func simulateShortcut(_ hotkey: HotkeyConfig) {
        let source = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = []
        if (hotkey.modifiers & UInt32(cmdKey)) != 0 { flags.insert(.maskCommand) }
        if (hotkey.modifiers & UInt32(shiftKey)) != 0 { flags.insert(.maskShift) }
        if (hotkey.modifiers & UInt32(optionKey)) != 0 { flags.insert(.maskAlternate) }
        if (hotkey.modifiers & UInt32(controlKey)) != 0 { flags.insert(.maskControl) }

        let keyCode = CGKeyCode(hotkey.keyCode)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

// MARK: - Native Light Frosted Glass NSVisualEffectView Bridge

struct LightGlassBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Radial Slot Icon View (App Native Icon / Custom Image / SF Symbol)

struct RadialSlotIconView: View {
    let slot: RadialSlot
    let iconSize: CGFloat

    var body: some View {
        switch slot.iconType {
        case .appIcon:
            if !slot.appPath.isEmpty && FileManager.default.fileExists(atPath: slot.appPath) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: slot.appPath))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: iconSize * 0.62, weight: .medium))
                    .foregroundColor(Color(red: 0.16, green: 0.17, blue: 0.19))
            }

        case .customImage:
            if let img = SettingsStore.shared.loadCustomRadialIcon(filename: slot.customIconFilename) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.24, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: iconSize * 0.58, weight: .medium))
                    .foregroundColor(Color(red: 0.16, green: 0.17, blue: 0.19))
            }

        case .sfSymbol:
            let sym = slot.symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
            Image(systemName: sym.isEmpty ? "sparkle" : sym)
                .font(.system(size: iconSize * 0.62, weight: .medium))
                .foregroundColor(Color(red: 0.14, green: 0.15, blue: 0.17))
        }
    }
}

// MARK: - Bright Translucent Frosted Glass Bubble Ring View

struct RadialMenuCanvasView: View {
    @ObservedObject var vm: RadialMenuViewModel
    let panelSize: CGFloat

    var body: some View {
        let center = panelSize / 2
        let count = max(vm.slots.count, 1)

        ZStack {
            // Subtle luminous connecting halo ring
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.65), Color.white.opacity(0.20)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.2
                )
                .frame(width: vm.ringRadius * 2, height: vm.ringRadius * 2)
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)

            // Center Cancel / Active Preview Hub
            centerHubView
                .position(x: center, y: center)

            // Ring of bright translucent frosted glass bubbles
            ForEach(Array(vm.slots.enumerated()), id: \.element.id) { idx, slot in
                let angle = (2 * .pi * Double(idx)) / Double(count)
                let x = center + CGFloat(sin(angle)) * vm.ringRadius
                let y = center - CGFloat(cos(angle)) * vm.ringRadius
                let isHovered = (vm.hoveredIndex == idx)

                radialBubbleView(slot: slot, isHovered: isHovered)
                    .position(x: x, y: y)
            }
        }
        .frame(width: panelSize, height: panelSize)
        .scaleEffect(vm.isVisible ? 1.0 : 0.84)
        .opacity(vm.isVisible ? 1.0 : 0.0)
    }

    private var centerHubView: some View {
        let hoveredSlot: RadialSlot? = {
            if let idx = vm.hoveredIndex, idx >= 0 && idx < vm.slots.count {
                return vm.slots[idx]
            }
            return nil
        }()

        return ZStack {
            LightGlassBlurView()
                .clipShape(Circle())
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.72), Color.white.opacity(0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.95), Color.white.opacity(0.35)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.2
                )

            if let slot = hoveredSlot {
                VStack(spacing: 2) {
                    Text(slot.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.15))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                    Text(slot.actionType == .sendShortcut ? slot.shortcut.displayString : "打开")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(white: 0.42))
                }
            } else {
                VStack(spacing: 2) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(white: 0.42))
                    Text("取消")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(Color(white: 0.46))
                }
            }
        }
        .frame(width: 68, height: 68)
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
    }

    private func radialBubbleView(slot: RadialSlot, isHovered: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                LightGlassBlurView()
                    .clipShape(Circle())

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.88 : 0.68),
                                Color.white.opacity(isHovered ? 0.62 : 0.38)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.98),
                                isHovered ? Color(red: 0.22, green: 0.23, blue: 0.26).opacity(0.55) : Color.white.opacity(0.38)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isHovered ? 2.0 : 1.2
                    )

                RadialSlotIconView(slot: slot, iconSize: isHovered ? 34 : 30)
            }
            .frame(width: 62, height: 62)
            .shadow(
                color: Color.black.opacity(isHovered ? 0.18 : 0.11),
                radius: isHovered ? 16 : 10,
                x: 0,
                y: isHovered ? 6 : 3
            )

            Text(slot.title)
                .font(.system(size: 11, weight: isHovered ? .semibold : .medium))
                .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.15))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(isHovered ? 0.92 : 0.76))
                        .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.09), radius: 4, x: 0, y: 2)
                )
        }
        .scaleEffect(isHovered ? 1.15 : 1.0)
    }
}
