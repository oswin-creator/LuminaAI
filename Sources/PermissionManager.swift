import Foundation
import AppKit
import ApplicationServices

final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published var hasAccessibility: Bool = false
    @Published var hasScreenRecording: Bool = false
    @Published var showGuideModal: Bool = false

    private var pollTimer: Timer?

    private init() {
        refreshStatus()
    }

    var allGranted: Bool {
        hasAccessibility && hasScreenRecording
    }

    func refreshStatus() {
        let ax = AXIsProcessTrusted()
        let sr = CGPreflightScreenCaptureAccess()
        DispatchQueue.main.async {
            self.hasAccessibility = ax
            self.hasScreenRecording = sr
        }
    }

    func checkOnLaunchAndPromptIfNeeded() {
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !self.hasAccessibility || !self.hasScreenRecording {
                AppLogger.shared.warn("Missing system permissions on launch: Accessibility=\(self.hasAccessibility), ScreenRecording=\(self.hasScreenRecording)")
                self.showGuideModal = true
                NotificationCenter.default.post(name: .luminaShowPermissionGuide, object: nil)
            }
        }
    }

    func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        hasAccessibility = granted
        AppLogger.shared.info("Requested Accessibility permission prompt. Current state: \(granted)")
        startTemporaryPolling()
    }

    func requestScreenRecordingPrompt() {
        let granted = CGRequestScreenCaptureAccess()
        hasScreenRecording = granted
        AppLogger.shared.info("Requested Screen Recording permission prompt. Current state: \(granted)")
        startTemporaryPolling()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startTemporaryPolling()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        startTemporaryPolling()
    }

    private func startTemporaryPolling() {
        pollTimer?.invalidate()
        var ticks = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.refreshStatus()
            ticks += 1
            if self.allGranted || ticks >= 30 {
                timer.invalidate()
            }
        }
    }
}
