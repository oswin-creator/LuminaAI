import Foundation
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private let dashboardVM = DashboardViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.shared.info("LuminaAI launched")

        applyPresenceSettings()
        setupNotifications()
        setupMonitorsAndHotkeys()
        showMainWindow()

        PermissionManager.shared.checkOnLaunchAndPromptIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyManager.shared.stop()
        TextSelectionMonitor.shared.stop()
        AppLogger.shared.info("LuminaAI terminated")
    }

    // MARK: - Setup

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePresenceChange),
            name: .luminaPresenceDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTriggerScreenshot),
            name: .luminaTriggerScreenshot,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenMainWindow),
            name: .luminaOpenMainWindow,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowPermissionGuide),
            name: .luminaShowPermissionGuide,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyChanged),
            name: .luminaHotkeyDidChange,
            object: nil
        )
    }

    private func setupMonitorsAndHotkeys() {
        GlobalHotkeyManager.shared.start {
            ScreenCaptureManager.shared.beginInteractiveCapture()
        }

        TextSelectionMonitor.shared.onTextSelected = { selectedText, mouseLocation in
            FloatingPanelController.shared.showSelectionCapsule(for: selectedText, near: mouseLocation)
        }
        TextSelectionMonitor.shared.onDismissRequested = {
            FloatingPanelController.shared.dismissSelectionCapsule()
        }
        TextSelectionMonitor.shared.start()
    }

    // MARK: - Dock & Menu Bar Presence

    @objc private func handlePresenceChange() {
        applyPresenceSettings()
    }

    private func applyPresenceSettings() {
        let settings = SettingsStore.shared

        // Dock icon policy
        let desiredPolicy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != desiredPolicy {
            NSApp.setActivationPolicy(desiredPolicy)
        }

        // Menu bar status item
        if settings.showInMenuBar {
            if statusItem == nil {
                createStatusItem()
            } else {
                rebuildStatusMenu()
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let img = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "LuminaAI") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "✦"
            }
            button.toolTip = "LuminaAI — 轻量 AI 划词与截屏助手"
        }
        self.statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "打开 Lumina 控制台与设置", action: #selector(handleOpenMainWindow), keyEquivalent: ",")
        openItem.target = self
        menu.addItem(openItem)

        let captureTitle = "截屏提问 (\(SettingsStore.shared.screenshotHotkey.displayString))"
        let captureItem = NSMenuItem(title: captureTitle, action: #selector(handleTriggerScreenshot), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)

        let selToggle = NSMenuItem(
            title: SettingsStore.shared.enableTextSelectionPopup ? "✓ 全局划词弹窗（已开启）" : "全局划词弹窗（已关闭）",
            action: #selector(toggleSelectionFromMenu),
            keyEquivalent: ""
        )
        selToggle.target = self
        menu.addItem(selToggle)

        menu.addItem(NSMenuItem.separator())

        let permItem = NSMenuItem(title: "检查系统权限...", action: #selector(handleShowPermissionGuide), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        let logItem = NSMenuItem(title: "查看后台日志 (Finder)", action: #selector(openLogsFromMenu), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 LuminaAI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
    }

    // MARK: - Actions

    @objc private func handleTriggerScreenshot() {
        ScreenCaptureManager.shared.beginInteractiveCapture()
    }

    @objc private func handleOpenMainWindow() {
        showMainWindow()
    }

    @objc private func handleShowPermissionGuide() {
        PermissionManager.shared.refreshStatus()
        PermissionManager.shared.showGuideModal = true
        showMainWindow()
    }

    @objc private func handleHotkeyChanged() {
        rebuildStatusMenu()
    }

    @objc private func toggleSelectionFromMenu() {
        SettingsStore.shared.enableTextSelectionPopup.toggle()
        rebuildStatusMenu()
        ToastHUD.shared.show(SettingsStore.shared.enableTextSelectionPopup ? "已开启全局划词弹窗" : "已关闭全局划词弹窗")
    }

    @objc private func openLogsFromMenu() {
        AppLogger.shared.revealInFinder()
    }

    // MARK: - Main Dashboard Window

    func showMainWindow() {
        if mainWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1140, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "LuminaAI"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.isMovableByWindowBackground = false
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.center()

            let rootView = MainDashboardView(
                vm: dashboardVM,
                settings: SettingsStore.shared,
                usage: UsageStore.shared,
                permissions: PermissionManager.shared,
                logger: AppLogger.shared,
                updater: UpdateManager.shared
            )
            win.contentView = NSHostingView(rootView: rootView)
            self.mainWindow = win
        }

        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Release SwiftUI dashboard view hierarchy & GPU backing store while running silently in background
        sender.orderOut(nil)
        sender.contentView = nil
        mainWindow = nil
        return false
    }
}
