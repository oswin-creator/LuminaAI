import Foundation
import AppKit
import ScreenCaptureKit
import Vision
import SwiftUI

// MARK: - Screenshot Action

enum ScreenshotAction {
    case copy
    case ocr
    case translate
    case ask
    case cancel
}

// MARK: - Screen Capture Manager

final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()

    private var overlayWindow: CaptureOverlayWindow?
    private var toolbarWindow: NSPanel?
    private var capturedFullImage: CGImage?
    private var activeScreen: NSScreen?

    private init() {}

    func beginInteractiveCapture() {
        PermissionManager.shared.refreshStatus()
        if !CGPreflightScreenCaptureAccess() {
            AppLogger.shared.warn("Screen capture requested without Screen Recording permission")
            PermissionManager.shared.showGuideModal = true
            NotificationCenter.default.post(name: .luminaShowPermissionGuide, object: nil)
            return
        }

        dismissOverlay()

        let mouseLoc = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
        guard let screen = targetScreen else { return }
        self.activeScreen = screen

        let screenFrame = screen.frame
        let scale = screen.backingScaleFactor
        let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value

        Task {
            do {
                let image = try await captureDisplayImage(screenNumber: screenNumber, frame: screenFrame, scale: scale)
                await MainActor.run {
                    guard let s = self.activeScreen else { return }
                    self.capturedFullImage = image
                    self.presentOverlay(on: s, frozenImage: image)
                }
            } catch {
                AppLogger.shared.error("ScreenCaptureKit failed: \(error.localizedDescription), trying screencapture fallback")
                if let fallbackImage = self.captureFallbackViaCLI(frame: screenFrame) {
                    await MainActor.run {
                        guard let s = self.activeScreen else { return }
                        self.capturedFullImage = fallbackImage
                        self.presentOverlay(on: s, frozenImage: fallbackImage)
                    }
                } else {
                    await MainActor.run {
                        ToastHUD.shared.show("截屏失败，请检查「屏幕录制」权限")
                    }
                }
            }
        }
    }

    private func captureDisplayImage(screenNumber: UInt32?, frame: NSRect, scale: CGFloat) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screenNumber }) ?? content.displays.first else {
            throw NSError(domain: "LuminaCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active display found"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(frame.width * scale)
        config.height = Int(frame.height * scale)
        config.showsCursor = false
        config.scalesToFit = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func captureFallbackViaCLI(frame: NSRect) -> CGImage? {
        let tmpPath = NSTemporaryDirectory() + "lumina_cap_\(UUID().uuidString).png"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-t", "png", "-R\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))", tmpPath]
        try? task.run()
        task.waitUntilExit()
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        guard let nsImg = NSImage(contentsOfFile: tmpPath) else { return nil }
        return nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func presentOverlay(on screen: NSScreen, frozenImage: CGImage) {
        // Use nonactivatingPanel so triggering screenshot does NOT raise the main dashboard window!
        let win = CaptureOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let canvasView = CaptureCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size), backgroundImage: frozenImage)
        canvasView.onSelectionCompleted = { [weak self] localRect in
            self?.showActionToolbar(for: localRect, on: screen)
        }
        canvasView.onSelectionChanged = { [weak self] in
            self?.toolbarWindow?.orderOut(nil)
        }
        canvasView.onCancel = { [weak self] in
            self?.dismissOverlay()
        }

        win.contentView = canvasView
        win.alphaValue = 0.0
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(canvasView)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 1.0
        }

        self.overlayWindow = win
    }

    private func showActionToolbar(for localRect: NSRect, on screen: NSScreen) {
        toolbarWindow?.orderOut(nil)

        let toolbarView = ScreenshotToolbarSwiftUIView { [weak self] action in
            self?.handleAction(action, localRect: localRect, screen: screen)
        }
        let hostingView = NSHostingView(rootView: toolbarView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        let fitSize = hostingView.fittingSize
        let toolbarWidth = max(fitSize.width, 460)
        let toolbarHeight = max(fitSize.height, 74)

        let screenRect = NSRect(
            x: screen.frame.origin.x + localRect.origin.x,
            y: screen.frame.origin.y + localRect.origin.y,
            width: localRect.width,
            height: localRect.height
        )

        var x = screenRect.midX - toolbarWidth / 2
        x = max(screen.frame.minX + 8, min(x, screen.frame.maxX - toolbarWidth - 8))

        var y = screenRect.minY - toolbarHeight + 4
        if y < screen.frame.minY + 8 {
            y = min(screenRect.maxY - 4, screen.frame.maxY - toolbarHeight - 8)
        }

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: toolbarWidth, height: toolbarHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // SwiftUI draws clean capsule shadow inside transparent padding
        panel.contentView = hostingView
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }

        self.toolbarWindow = panel
    }

    private func handleAction(_ action: ScreenshotAction, localRect: NSRect, screen: NSScreen) {
        guard action != .cancel else {
            dismissOverlay()
            return
        }

        guard let fullImage = capturedFullImage,
              let croppedCG = cropImage(fullImage, localRect: localRect, screenSize: screen.frame.size) else {
            dismissOverlay()
            ToastHUD.shared.show("裁剪截图失败")
            return
        }

        let nsImage = NSImage(cgImage: croppedCG, size: localRect.size)
        let jpegData = jpegDataFromCGImage(croppedCG, quality: 0.85)
        let anchorPoint = NSPoint(
            x: screen.frame.origin.x + localRect.midX,
            y: screen.frame.origin.y + localRect.midY
        )

        dismissOverlay()

        switch action {
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([nsImage])
            ToastHUD.shared.show("已复制截图到剪贴板")
            AppLogger.shared.info("Copied screenshot (\(Int(localRect.width))x\(Int(localRect.height)))")

        case .ocr:
            if SettingsStore.shared.useNativeVisionOCRFirst {
                performVisionOCR(on: croppedCG) { recognizedText in
                    DispatchQueue.main.async {
                        if recognizedText.isEmpty {
                            ToastHUD.shared.show("未识别到文字，尝试使用多模态 AI 识别")
                            if let data = jpegData {
                                FloatingPanelController.shared.showReplyPanel(
                                    feature: .screenshotOCR,
                                    selectedText: nil,
                                    imageData: data,
                                    initialPrompt: "请准确提取图片中的所有文字。",
                                    autoSend: true,
                                    near: anchorPoint
                                )
                            }
                        } else {
                            FloatingPanelController.shared.showOCRResultPanel(
                                extractedText: recognizedText,
                                imageData: jpegData,
                                near: anchorPoint
                            )
                        }
                    }
                }
            } else if let data = jpegData {
                FloatingPanelController.shared.showReplyPanel(
                    feature: .screenshotOCR,
                    selectedText: nil,
                    imageData: data,
                    initialPrompt: "请准确提取图片中的所有文字。",
                    autoSend: true,
                    near: anchorPoint
                )
            }

        case .translate:
            guard let data = jpegData else { return }
            FloatingPanelController.shared.showReplyPanel(
                feature: .screenshotTranslate,
                selectedText: nil,
                imageData: data,
                initialPrompt: nil, // Built dynamically using selected source/target language
                autoSend: true,
                near: anchorPoint
            )

        case .ask:
            guard let data = jpegData else { return }
            FloatingPanelController.shared.showReplyPanel(
                feature: .screenshotAsk,
                selectedText: nil,
                imageData: data,
                initialPrompt: nil,
                autoSend: false,
                near: anchorPoint
            )

        case .cancel:
            break
        }
    }

    private func cropImage(_ image: CGImage, localRect: NSRect, screenSize: NSSize) -> CGImage? {
        let scaleX = CGFloat(image.width) / screenSize.width
        let scaleY = CGFloat(image.height) / screenSize.height
        let cropX = localRect.origin.x * scaleX
        let cropY = (screenSize.height - localRect.origin.y - localRect.height) * scaleY
        let cropW = localRect.width * scaleX
        let cropH = localRect.height * scaleY
        let cgRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH).integral
        return image.cropping(to: cgRect)
    }

    private func jpegDataFromCGImage(_ cgImage: CGImage, quality: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private func performVisionOCR(on cgImage: CGImage, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest { req, error in
                if let error = error {
                    AppLogger.shared.error("Vision OCR error: \(error.localizedDescription)")
                    completion("")
                    return
                }
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                completion(lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                AppLogger.shared.error("Vision OCR handler failed: \(error.localizedDescription)")
                completion("")
            }
        }
    }

    func dismissOverlay() {
        toolbarWindow?.orderOut(nil)
        toolbarWindow = nil
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        capturedFullImage = nil
        NSCursor.arrow.set()
    }
}

// MARK: - Capture Overlay Panel & Clean Crosshair Canvas

final class CaptureOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum CaptureDragMode {
    case none
    case creating(anchor: NSPoint)
    case moving(startMouse: NSPoint, initialRect: NSRect)
    case resizing(edge: CaptureResizeEdge, startMouse: NSPoint, initialRect: NSRect)
}

enum CaptureResizeEdge {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
}

final class CaptureCanvasView: NSView {
    private let backgroundImage: CGImage
    private let blackCrosshairCursor: NSCursor
    private var currentSelection: NSRect = .zero
    private var dragMode: CaptureDragMode = .none
    private var selectionLocked = false
    private var pulsePhase: CGFloat = 0
    private var animTimer: Timer?
    private var trackingArea: NSTrackingArea?

    var onSelectionCompleted: ((NSRect) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onCancel: (() -> Void)?

    init(frame: NSRect, backgroundImage: CGImage) {
        self.backgroundImage = backgroundImage
        self.blackCrosshairCursor = Self.makeBlackCrosshairCursor()
        super.init(frame: frame)
        self.wantsLayer = true

        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pulsePhase += 0.12
            if self.pulsePhase > .pi * 2 { self.pulsePhase -= .pi * 2 }
            if self.currentSelection.width > 1 {
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        animTimer?.invalidate()
        NSCursor.arrow.set()
    }

    /// Clean, refined small black crosshair (+) with crisp 1px white outline so it reads on any background
    private static func makeBlackCrosshairCursor() -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let img = NSImage(size: size)
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            let c: CGFloat = 12.0
            let arm: CGFloat = 8.0

            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(3.4)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: c - arm, y: c))
            ctx.addLine(to: CGPoint(x: c + arm, y: c))
            ctx.move(to: CGPoint(x: c, y: c - arm))
            ctx.addLine(to: CGPoint(x: c, y: c + arm))
            ctx.strokePath()

            ctx.setStrokeColor(NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor)
            ctx.setLineWidth(1.6)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: c - arm, y: c))
            ctx.addLine(to: CGPoint(x: c + arm, y: c))
            ctx.move(to: CGPoint(x: c, y: c - arm))
            ctx.addLine(to: CGPoint(x: c, y: c + arm))
            ctx.strokePath()
        }
        img.unlockFocus()
        return NSCursor(image: img, hotSpot: NSPoint(x: 12, y: 12))
    }

    private func hitTestResizeEdge(at pt: NSPoint) -> CaptureResizeEdge? {
        guard selectionLocked, currentSelection.width >= 12, currentSelection.height >= 12 else { return nil }
        let r = currentSelection
        let cornerTol: CGFloat = 12
        let edgeTol: CGFloat = 8

        let nearLeft = abs(pt.x - r.minX) <= cornerTol
        let nearRight = abs(pt.x - r.maxX) <= cornerTol
        let nearBottom = abs(pt.y - r.minY) <= cornerTol
        let nearTop = abs(pt.y - r.maxY) <= cornerTol

        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }

        if abs(pt.x - r.minX) <= edgeTol && pt.y >= r.minY && pt.y <= r.maxY { return .left }
        if abs(pt.x - r.maxX) <= edgeTol && pt.y >= r.minY && pt.y <= r.maxY { return .right }
        if abs(pt.y - r.maxY) <= edgeTol && pt.x >= r.minX && pt.x <= r.maxX { return .top }
        if abs(pt.y - r.minY) <= edgeTol && pt.x >= r.minX && pt.x <= r.maxX { return .bottom }
        return nil
    }

    private func updateCursor(for pt: NSPoint) {
        if !selectionLocked {
            blackCrosshairCursor.set()
            return
        }
        if let edge = hitTestResizeEdge(at: pt) {
            switch edge {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            case .topLeft, .topRight, .bottomLeft, .bottomRight: NSCursor.crosshair.set()
            }
        } else if currentSelection.contains(pt) {
            NSCursor.openHand.set()
        } else {
            blackCrosshairCursor.set()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .cursorUpdate, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        updateCursor(for: loc)
    }

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        updateCursor(for: loc)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        onSelectionChanged?()

        if selectionLocked {
            if let edge = hitTestResizeEdge(at: loc) {
                dragMode = .resizing(edge: edge, startMouse: loc, initialRect: currentSelection)
                return
            } else if currentSelection.contains(loc) {
                dragMode = .moving(startMouse: loc, initialRect: currentSelection)
                NSCursor.closedHand.set()
                return
            }
        }

        // Start a fresh selection
        selectionLocked = false
        currentSelection = NSRect(origin: loc, size: .zero)
        dragMode = .creating(anchor: loc)
        blackCrosshairCursor.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let clampedX = max(bounds.minX, min(loc.x, bounds.maxX))
        let clampedY = max(bounds.minY, min(loc.y, bounds.maxY))
        let clamped = NSPoint(x: clampedX, y: clampedY)

        switch dragMode {
        case .creating(let anchor):
            let minX = min(anchor.x, clamped.x)
            let minY = min(anchor.y, clamped.y)
            currentSelection = NSRect(x: minX, y: minY, width: abs(clamped.x - anchor.x), height: abs(clamped.y - anchor.y))

        case .moving(let startMouse, let initialRect):
            let dx = clamped.x - startMouse.x
            let dy = clamped.y - startMouse.y
            var newX = initialRect.origin.x + dx
            var newY = initialRect.origin.y + dy
            newX = max(bounds.minX, min(newX, bounds.maxX - initialRect.width))
            newY = max(bounds.minY, min(newY, bounds.maxY - initialRect.height))
            currentSelection = NSRect(x: newX, y: newY, width: initialRect.width, height: initialRect.height)

        case .resizing(let edge, let startMouse, let r):
            let dx = clamped.x - startMouse.x
            let dy = clamped.y - startMouse.y
            var minX = r.minX
            var maxX = r.maxX
            var minY = r.minY
            var maxY = r.maxY
            let minDim: CGFloat = 20

            switch edge {
            case .left: minX = min(maxX - minDim, max(bounds.minX, r.minX + dx))
            case .right: maxX = max(minX + minDim, min(bounds.maxX, r.maxX + dx))
            case .bottom: minY = min(maxY - minDim, max(bounds.minY, r.minY + dy))
            case .top: maxY = max(minY + minDim, min(bounds.maxY, r.maxY + dy))
            case .topLeft:
                minX = min(maxX - minDim, max(bounds.minX, r.minX + dx))
                maxY = max(minY + minDim, min(bounds.maxY, r.maxY + dy))
            case .topRight:
                maxX = max(minX + minDim, min(bounds.maxX, r.maxX + dx))
                maxY = max(minY + minDim, min(bounds.maxY, r.maxY + dy))
            case .bottomLeft:
                minX = min(maxX - minDim, max(bounds.minX, r.minX + dx))
                minY = min(maxY - minDim, max(bounds.minY, r.minY + dy))
            case .bottomRight:
                maxX = max(minX + minDim, min(bounds.maxX, r.maxX + dx))
                minY = min(maxY - minDim, max(bounds.minY, r.minY + dy))
            }
            currentSelection = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        dragMode = .none

        if currentSelection.width >= 12 && currentSelection.height >= 12 {
            selectionLocked = true
            updateCursor(for: loc)
            onSelectionCompleted?(currentSelection)
        } else {
            currentSelection = .zero
            selectionLocked = false
            blackCrosshairCursor.set()
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.draw(backgroundImage, in: bounds)

        ctx.saveGState()
        let overlayPath = CGMutablePath()
        overlayPath.addRect(bounds)
        if currentSelection.width > 1 && currentSelection.height > 1 {
            overlayPath.addRoundedRect(in: currentSelection, cornerWidth: 4, cornerHeight: 4)
        }
        ctx.addPath(overlayPath)
        ctx.setFillColor(NSColor(calibratedWhite: 0.06, alpha: 0.45).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        drawEdgeVignette(in: ctx)

        if currentSelection.width > 1 && currentSelection.height > 1 {
            drawSelectionFrame(in: ctx, rect: currentSelection)
        }
    }

    private func drawEdgeVignette(in ctx: CGContext) {
        ctx.saveGState()
        let colors = [
            NSColor.clear.cgColor,
            NSColor(calibratedWhite: 0.02, alpha: 0.30).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.64, 1.0]) {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = hypot(bounds.width, bounds.height) * 0.56
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: radius * 0.4, endCenter: center, endRadius: radius, options: .drawsAfterEndLocation)
        }
        ctx.restoreGState()
    }

    private func drawSelectionFrame(in ctx: CGContext, rect: NSRect) {
        ctx.saveGState()
        let glowAlpha = 0.80 + 0.16 * sin(pulsePhase)

        let borderPath = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(borderPath)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.94, green: 0.91, blue: 0.84, alpha: glowAlpha).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()

        if case .creating = dragMode, rect.width > 80 && rect.height > 80 {
            ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.16).cgColor)
            ctx.setLineWidth(0.75)
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3.0
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * CGFloat(i) / 3.0
                ctx.move(to: CGPoint(x: rect.minX, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            ctx.strokePath()
        }

        let cornerLen: CGFloat = min(13, min(rect.width, rect.height) * 0.24)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2.4)
        ctx.setLineCap(.round)

        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)
        ]
        for (pt, dx, dy) in corners {
            ctx.move(to: CGPoint(x: pt.x + dx * cornerLen, y: pt.y))
            ctx.addLine(to: pt)
            ctx.addLine(to: CGPoint(x: pt.x, y: pt.y + dy * cornerLen))
        }
        ctx.strokePath()

        // Draw subtle draggable handle dots on 4 corners & 4 edge midpoints when locked
        if selectionLocked {
            let handlePts: [CGPoint] = [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.midX, y: rect.minY),
                CGPoint(x: rect.midX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.midY),
                CGPoint(x: rect.maxX, y: rect.midY)
            ]
            for hp in handlePts {
                let dotRect = CGRect(x: hp.x - 3.5, y: hp.y - 3.5, width: 7, height: 7)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: dotRect)
                ctx.setStrokeColor(NSColor(calibratedWhite: 0.14, alpha: 0.85).cgColor)
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: dotRect)
            }
        }

        let label = selectionLocked ? "\(Int(rect.width)) × \(Int(rect.height)) · 可拖动调整" : "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 10
        let padY: CGFloat = 4
        let badgeW = textSize.width + padX * 2
        let badgeH = textSize.height + padY * 2
        let badgeY = min(rect.maxY + 8, bounds.maxY - badgeH - 8)
        let badgeRect = NSRect(x: rect.minX, y: badgeY, width: badgeW, height: badgeH)

        let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: badgeH / 2, cornerHeight: badgeH / 2, transform: nil)
        ctx.addPath(badgePath)
        ctx.setFillColor(NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.15, alpha: 0.88).cgColor)
        ctx.fillPath()

        (label as NSString).draw(
            at: NSPoint(x: badgeRect.minX + padX, y: badgeRect.minY + padY),
            withAttributes: attrs
        )
        ctx.restoreGState()
    }
}

// MARK: - Screenshot Floating Action Toolbar (Generous Shadow Padding, Zero Truncation)

struct ScreenshotToolbarSwiftUIView: View {
    let onAction: (ScreenshotAction) -> Void

    var body: some View {
        HStack(spacing: 6) {
            toolbarButton(title: "复制", symbol: "doc.on.doc", accent: false) {
                onAction(.copy)
            }
            Divider().frame(height: 18).opacity(0.22)
            toolbarButton(title: "提取文字", symbol: "text.viewfinder", accent: false) {
                onAction(.ocr)
            }
            toolbarButton(title: "AI 翻译", symbol: "globe", accent: false) {
                onAction(.translate)
            }
            toolbarButton(title: "AI 提问", symbol: "sparkles", accent: true) {
                onAction(.ask)
            }
            Divider().frame(height: 18).opacity(0.22)
            Button(action: { onAction(.cancel) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color(white: 0.35))
                    .frame(width: 28, height: 28)
                    .background(Color.black.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color(red: 0.97, green: 0.97, blue: 0.98))
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.20), radius: 10, x: 0, y: 4)
        )
        .padding(14) // Transparent outer margin so shadow never clips to a dark rectangle
    }

    private func toolbarButton(title: String, symbol: String, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(accent ? .white : Color(red: 0.12, green: 0.13, blue: 0.14))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    accent
                    ? LinearGradient(colors: [Color(red: 0.15, green: 0.16, blue: 0.18), Color(red: 0.24, green: 0.25, blue: 0.27)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    : LinearGradient(colors: [Color.black.opacity(0.045), Color.black.opacity(0.045)], startPoint: .top, endPoint: .bottom)
                )
            )
        }
        .buttonStyle(.plain)
    }
}
