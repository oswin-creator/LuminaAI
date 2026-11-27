import Foundation
import AppKit
import SwiftUI
import CryptoKit
import Carbon

// MARK: - Clipboard History Store (Disk-Backed Assets, Lightweight Metadata)

final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    @Published var items: [ClipboardHistoryItem] = []
    @Published var totalStorageBytes: Int64 = 0

    let metadataURL: URL
    let assetsDirURL: URL

    private var pollTimer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private let ioQueue = DispatchQueue(label: "com.lumina.ai.clipboard.io", qos: .utility)

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("LuminaAI", isDirectory: true)
        self.metadataURL = baseDir.appendingPathComponent("clipboard_history.json")
        self.assetsDirURL = baseDir.appendingPathComponent("clipboard_assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetsDirURL, withIntermediateDirectories: true)

        load()
        recalculateStorage()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePolicyChanged),
            name: .luminaClipboardPolicyDidChange,
            object: nil
        )
    }

    func startMonitoring() {
        stopMonitoring()
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        timer.tolerance = 0.25 // Allow macOS timer coalescing for ~0% idle CPU
        RunLoop.main.add(timer, forMode: .common)
        self.pollTimer = timer
        AppLogger.shared.info("ClipboardHistoryStore monitoring started")
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func handlePolicyChanged() {
        enforceRetentionPolicy()
    }

    private func pollPasteboard() {
        guard SettingsStore.shared.enableClipboardHistory else {
            lastChangeCount = NSPasteboard.general.changeCount
            return
        }
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // 1. Check Image first (PNG / TIFF)
        if let pngData = pb.data(forType: .png) {
            captureImage(rawData: pngData)
            return
        }
        if let tiffData = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiffData),
           let pngData = rep.representation(using: .png, properties: [:]) {
            captureImage(rawData: pngData)
            return
        }

        // 2. Check Rich Text (preserve BOTH raw HTML and RTF for 100% faithful preview & paste!)
        let rawPlain = pb.string(forType: .string) ?? ""
        let trimmedPlain = rawPlain.trimmingCharacters(in: .whitespacesAndNewlines)
        let rtfData = pb.data(forType: .rtf)
        let htmlData = pb.data(forType: .html)

        if (rtfData != nil || htmlData != nil) && !trimmedPlain.isEmpty {
            captureRichText(rtfData: rtfData, htmlData: htmlData, plainText: rawPlain)
            return
        }

        // 3. Plain Text
        if !trimmedPlain.isEmpty {
            capturePlainText(rawPlain)
        }
    }

    private func capturePlainText(_ text: String) {
        let hash = Self.sha256Hex(Data(("plain:" + text).utf8))
        if promoteIfDuplicate(hash: hash) { return }

        let item = ClipboardHistoryItem(
            id: UUID(),
            kind: .plainText,
            plainText: text,
            rtfFilename: nil,
            htmlFilename: nil,
            imageFilename: nil,
            thumbFilename: nil,
            contentHash: hash,
            byteSize: Int64(text.utf8.count),
            createdAt: Date()
        )
        insertAndPersist(item)
    }

    private func captureRichText(rtfData: Data?, htmlData: Data?, plainText: String) {
        var hashInput = Data("rich:".utf8)
        if let h = htmlData { hashInput.append(h) }
        if let r = rtfData { hashInput.append(r) }
        let hash = Self.sha256Hex(hashInput)
        if promoteIfDuplicate(hash: hash) { return }

        let id = UUID()
        var savedRTF: String? = nil
        var savedHTML: String? = nil
        var totalBytes = Int64(plainText.utf8.count)

        if let rtf = rtfData {
            let name = "\(id.uuidString).rtf"
            if (try? rtf.write(to: assetsDirURL.appendingPathComponent(name), options: .atomic)) != nil {
                savedRTF = name
                totalBytes += Int64(rtf.count)
            }
        }
        if let html = htmlData {
            let name = "\(id.uuidString).html"
            if (try? html.write(to: assetsDirURL.appendingPathComponent(name), options: .atomic)) != nil {
                savedHTML = name
                totalBytes += Int64(html.count)
            }
        }

        guard savedRTF != nil || savedHTML != nil else {
            capturePlainText(plainText)
            return
        }

        let item = ClipboardHistoryItem(
            id: id,
            kind: .richText,
            plainText: plainText,
            rtfFilename: savedRTF,
            htmlFilename: savedHTML,
            imageFilename: nil,
            thumbFilename: nil,
            contentHash: hash,
            byteSize: totalBytes,
            createdAt: Date()
        )
        insertAndPersist(item)
    }

    private func captureImage(rawData: Data) {
        let hash = Self.sha256Hex(rawData)
        if promoteIfDuplicate(hash: hash) { return }

        let id = UUID()
        let imgName = "\(id.uuidString).png"
        let thumbName = "\(id.uuidString)_thumb.jpg"
        let imgURL = assetsDirURL.appendingPathComponent(imgName)
        let thumbURL = assetsDirURL.appendingPathComponent(thumbName)

        var totalBytes = Int64(rawData.count)
        do {
            try rawData.write(to: imgURL, options: .atomic)
            if let thumbData = Self.makeThumbnailJPEG(from: rawData, maxDimension: 520) {
                try thumbData.write(to: thumbURL, options: .atomic)
                totalBytes += Int64(thumbData.count)
            }
        } catch {
            AppLogger.shared.error("Clipboard image write failed: \(error.localizedDescription)")
            return
        }

        let item = ClipboardHistoryItem(
            id: id,
            kind: .image,
            plainText: "",
            rtfFilename: nil,
            htmlFilename: nil,
            imageFilename: imgName,
            thumbFilename: FileManager.default.fileExists(atPath: thumbURL.path) ? thumbName : nil,
            contentHash: hash,
            byteSize: totalBytes,
            createdAt: Date()
        )
        insertAndPersist(item)
    }

    private func promoteIfDuplicate(hash: String) -> Bool {
        guard let idx = items.firstIndex(where: { $0.contentHash == hash }) else { return false }
        var existing = items.remove(at: idx)
        existing.createdAt = Date()
        items.insert(existing, at: 0)
        save()
        return true
    }

    private func insertAndPersist(_ item: ClipboardHistoryItem) {
        items.insert(item, at: 0)
        enforceRetentionPolicy()
    }

    func enforceRetentionPolicy() {
        let maxCount = min(500, max(20, SettingsStore.shared.clipboardMaxItems))
        let maxBytes = Int64(max(10, SettingsStore.shared.clipboardMaxStorageMB)) * 1024 * 1024

        while items.count > maxCount {
            if let removed = items.popLast() {
                deleteAssets(for: removed)
            }
        }

        var sum = items.reduce(Int64(0)) { $0 + $1.byteSize }
        while sum > maxBytes && items.count > 1 {
            if let removed = items.popLast() {
                sum -= removed.byteSize
                deleteAssets(for: removed)
            }
        }

        totalStorageBytes = sum
        save()
    }

    func deleteItem(id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let removed = items.remove(at: idx)
            deleteAssets(for: removed)
            recalculateStorage()
            save()
        }
    }

    func clearAll() {
        for item in items {
            deleteAssets(for: item)
        }
        items = []
        totalStorageBytes = 0
        // Also clean any orphaned files in assetsDirURL
        if let files = try? FileManager.default.contentsOfDirectory(at: assetsDirURL, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        save()
        AppLogger.shared.info("Cleared all clipboard history")
    }

    func pasteItem(_ item: ClipboardHistoryItem, forcePlainText: Bool? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .image:
            if let fname = item.imageFilename,
               let img = NSImage(contentsOf: assetsDirURL.appendingPathComponent(fname)) {
                pb.writeObjects([img])
            }
        case .plainText:
            pb.setString(item.plainText, forType: .string)
        case .richText:
            let usePlain: Bool
            if let override = forcePlainText {
                usePlain = override
            } else {
                usePlain = (SettingsStore.shared.clipboardDefaultPasteMode == .plainText)
            }
            if !usePlain {
                var wroteRich = false
                if let htmlName = item.htmlFilename,
                   let htmlData = try? Data(contentsOf: assetsDirURL.appendingPathComponent(htmlName)) {
                    pb.setData(htmlData, forType: .html)
                    wroteRich = true
                }
                if let rtfName = item.rtfFilename,
                   let rtfData = try? Data(contentsOf: assetsDirURL.appendingPathComponent(rtfName)) {
                    pb.setData(rtfData, forType: .rtf)
                    wroteRich = true
                }
                pb.setString(item.plainText, forType: .string)
                if !wroteRich {
                    pb.setString(item.plainText, forType: .string)
                }
            } else {
                pb.setString(item.plainText, forType: .string)
            }
        }

        // Sync changeCount so we don't duplicate our own write
        lastChangeCount = pb.changeCount
        _ = promoteIfDuplicate(hash: item.contentHash)

        // Simulate Cmd+V to foreground app without stealing focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) {
            Self.simulateCommandV()
        }
    }

    func loadThumbnail(for item: ClipboardHistoryItem) -> NSImage? {
        if let thumb = item.thumbFilename,
           let img = NSImage(contentsOf: assetsDirURL.appendingPathComponent(thumb)) {
            return img
        }
        if let full = item.imageFilename {
            return NSImage(contentsOf: assetsDirURL.appendingPathComponent(full))
        }
        return nil
    }

    /// Loads native NSAttributedString from preserved HTML or RTF, preserving colors, links, bold/italic,
    /// highlights, and inline images (NSTextAttachment), while clamping font sizes <= 15pt and inline images <= 36pt.
    func loadClampedRichNSAttributedString(for item: ClipboardHistoryItem) -> NSAttributedString? {
        guard item.kind == .richText else { return nil }

        var parsed: NSMutableAttributedString? = nil
        if let htmlName = item.htmlFilename,
           let htmlData = try? Data(contentsOf: assetsDirURL.appendingPathComponent(htmlName)) {
            parsed = try? NSMutableAttributedString(
                data: htmlData,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
        }
        if parsed == nil,
           let rtfName = item.rtfFilename,
           let rtfData = try? Data(contentsOf: assetsDirURL.appendingPathComponent(rtfName)) {
            parsed = try? NSMutableAttributedString(
                data: rtfData,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        }
        guard let nsAttr = parsed, nsAttr.length > 0 else { return nil }

        let fullRange = NSRange(location: 0, length: nsAttr.length)

        // 1. Clamp font sizes to 11.5...15pt while keeping bold/italic traits
        nsAttr.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            if let font = value as? NSFont {
                let clampedSize = min(max(font.pointSize, 11.5), 15.0)
                let traits = NSFontManager.shared.traits(of: font)
                let weight: NSFont.Weight = traits.contains(.boldFontMask) ? .semibold : .regular
                var replacement = NSFont.systemFont(ofSize: clampedSize, weight: weight)
                if traits.contains(.italicFontMask) {
                    replacement = NSFontManager.shared.convert(replacement, toHaveTrait: .italicFontMask)
                }
                nsAttr.addAttribute(.font, value: replacement, range: range)
            } else {
                nsAttr.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: range)
            }
        }

        // 2. Preserve real colors & blue links; only darken unreadable near-white text on light glass
        nsAttr.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
            if let color = value as? NSColor,
               let rgb = color.usingColorSpace(.deviceRGB) {
                let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
                if luminance > 0.86 {
                    nsAttr.addAttribute(.foregroundColor, value: NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.17, alpha: 1.0), range: range)
                }
            }
        }

        // 3. Make hyperlinks clearly recognizable in crisp Apple system blue
        nsAttr.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
            if value != nil {
                nsAttr.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
                nsAttr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }

        // 4. Scale down inline NSTextAttachment images cleanly so logos/icons fit nicely without exploding card height
        nsAttr.enumerateAttribute(.attachment, in: fullRange, options: []) { value, _, _ in
            if let att = value as? NSTextAttachment {
                let img = att.image ?? (att.fileWrapper?.regularFileContents.flatMap { NSImage(data: $0) })
                if let img = img {
                    let orig = img.size
                    if orig.width > 0 && orig.height > 0 {
                        let maxH: CGFloat = 34.0
                        let maxW: CGFloat = 180.0
                        let scale = min(1.0, min(maxH / orig.height, maxW / orig.width))
                        att.bounds = CGRect(x: 0, y: -4, width: orig.width * scale, height: orig.height * scale)
                    }
                }
            }
        }

        return nsAttr
    }

    private func deleteAssets(for item: ClipboardHistoryItem) {
        if let f = item.rtfFilename { try? FileManager.default.removeItem(at: assetsDirURL.appendingPathComponent(f)) }
        if let f = item.htmlFilename { try? FileManager.default.removeItem(at: assetsDirURL.appendingPathComponent(f)) }
        if let f = item.imageFilename { try? FileManager.default.removeItem(at: assetsDirURL.appendingPathComponent(f)) }
        if let f = item.thumbFilename { try? FileManager.default.removeItem(at: assetsDirURL.appendingPathComponent(f)) }
    }

    private func recalculateStorage() {
        totalStorageBytes = items.reduce(Int64(0)) { $0 + $1.byteSize }
    }

    private func load() {
        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder().decode([ClipboardHistoryItem].self, from: data) {
            self.items = decoded
        }
    }

    private func save() {
        let snapshot = items
        let url = metadataURL
        ioQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func makeThumbnailJPEG(from pngData: Data, maxDimension: CGFloat) -> Data? {
        guard let nsImg = NSImage(data: pngData) else { return nil }
        let orig = nsImg.size
        guard orig.width > 0 && orig.height > 0 else { return nil }
        let ratio = min(1.0, maxDimension / max(orig.width, orig.height))
        let target = NSSize(width: max(1, orig.width * ratio), height: max(1, orig.height * ratio))

        let thumb = NSImage(size: target)
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        nsImg.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1.0)
        thumb.unlockFocus()

        guard let tiff = thumb.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.78])
    }

    private static func simulateCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - Clipboard Popup ViewModel (ObservableObject, Zero @State)

final class ClipboardPopupViewModel: ObservableObject {
    @Published var filter: ClipboardFilterMode = .all {
        didSet { selectedIndex = 0 }
    }
    @Published var searchText: String = "" {
        didSet { selectedIndex = 0 }
    }
    @Published var selectedIndex: Int = 0
    @Published var hoveredItemID: UUID? = nil
    @Published var expandedItemIDs: Set<UUID> = []
    @Published var isPinned: Bool = false

    /// Ephemeral preview cache (automatically freed when popup closes & vm deallocates)
    private var richPreviewCache: [UUID: NSAttributedString] = [:]

    func cachedRichPreview(for item: ClipboardHistoryItem, store: ClipboardHistoryStore) -> NSAttributedString? {
        if let hit = richPreviewCache[item.id] {
            return hit
        }
        if let loaded = store.loadClampedRichNSAttributedString(for: item) {
            richPreviewCache[item.id] = loaded
            return loaded
        }
        return nil
    }

    func filteredItems(from all: [ClipboardHistoryItem]) -> [ClipboardHistoryItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.filter { item in
            switch filter {
            case .all: break
            case .text: if item.kind == .image { return false }
            case .image: if item.kind != .image { return false }
            }
            if !q.isEmpty {
                if item.kind == .image { return false }
                return item.plainText.lowercased().contains(q)
            }
            return true
        }
    }

    func toggleExpanded(_ id: UUID) {
        if expandedItemIDs.contains(id) {
            expandedItemIDs.remove(id)
        } else {
            expandedItemIDs.insert(id)
        }
    }
}

// MARK: - Clipboard Floating Panel Controller

final class ClipboardPanelController {
    static let shared = ClipboardPanelController()

    private var panel: ClipboardFloatingPanel?
    private var vm: ClipboardPopupViewModel?
    private var previousFrontmostApp: NSRunningApplication?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var localKeyMonitor: Any?

    private init() {}

    func toggle() {
        if panel != nil {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        dismiss()

        // Remember the active foreground app so pinned mode can return keyboard focus before Cmd+V
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = front
        }

        let viewModel = ClipboardPopupViewModel()
        self.vm = viewModel

        let width: CGFloat = 436
        let height: CGFloat = 540
        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = mouseLoc.x - width / 2
        x = max(bounds.minX + 10, min(x, bounds.maxX - width - 10))
        var y = mouseLoc.y - height + 36
        if y < bounds.minY + 10 {
            y = min(mouseLoc.y + 12, bounds.maxY - height - 10)
        }
        y = max(bounds.minY + 10, min(y, bounds.maxY - height - 10))

        let p = ClipboardFloatingPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.identifier = NSUserInterfaceItemIdentifier("LuminaClipboardPanel")
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false // Clean SwiftUI shadow inside transparent outer padding
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let root = ClipboardPopupView(
            vm: viewModel,
            store: ClipboardHistoryStore.shared,
            settings: SettingsStore.shared,
            onPaste: { [weak self] item, forcePlain in
                guard let self = self else { return }
                let pinned = self.vm?.isPinned ?? false
                if !pinned {
                    self.dismiss()
                } else {
                    // Return keyboard focus to target app while keeping pinned panel floating on top
                    self.previousFrontmostApp?.activate(options: [])
                    self.panel?.orderFrontRegardless()
                }
                ClipboardHistoryStore.shared.pasteItem(item, forcePlainText: forcePlain)
            },
            onTogglePin: { [weak p] pinned in
                p?.level = pinned ? .statusBar : .floating
            },
            onClose: { [weak self] in
                self?.dismiss()
            }
        )

        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = hosting
        p.alphaValue = 0
        // Do NOT call NSApp.activate so foreground app keeps focus & main dashboard never pops up
        p.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1.0
        }

        self.panel = p
        installTemporaryMonitors()
    }

    func dismiss() {
        removeTemporaryMonitors()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        vm = nil
    }

    private func installTemporaryMonitors() {
        removeTemporaryMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let p = self.panel, let vm = self.vm, !vm.isPinned else { return }
            let click = NSEvent.mouseLocation
            if !p.frame.insetBy(dx: 12, dy: 12).contains(click) {
                DispatchQueue.main.async { self.dismiss() }
            }
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self = self, let p = self.panel, let vm = self.vm, !vm.isPinned,
               let win = event.window, win !== p, win.level.rawValue < NSWindow.Level.popUpMenu.rawValue {
                self.dismiss()
            }
            return event
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, let vm = self.vm, self.panel != nil else { return event }
            let filtered = vm.filteredItems(from: ClipboardHistoryStore.shared.items)

            switch Int(event.keyCode) {
            case 53: // Esc
                self.dismiss()
                return nil
            case 125: // Down arrow
                if !filtered.isEmpty {
                    vm.selectedIndex = min(filtered.count - 1, vm.selectedIndex + 1)
                }
                return nil
            case 126: // Up arrow
                if !filtered.isEmpty {
                    vm.selectedIndex = max(0, vm.selectedIndex - 1)
                }
                return nil
            case 36, 76: // Return / Enter
                if !filtered.isEmpty && vm.selectedIndex < filtered.count {
                    let item = filtered[vm.selectedIndex]
                    let pinned = vm.isPinned
                    if !pinned {
                        self.dismiss()
                    } else {
                        self.previousFrontmostApp?.activate(options: [])
                        self.panel?.orderFrontRegardless()
                    }
                    ClipboardHistoryStore.shared.pasteItem(item, forcePlainText: nil)
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeTemporaryMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
    }
}

final class ClipboardFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // Allow dragging from the top bar area (excluding pin/close buttons)
        if event.type == .leftMouseDown {
            let pt = event.locationInWindow
            let dragZone = NSRect(x: 16, y: frame.height - 54, width: max(40, frame.width - 110), height: 34)
            if dragZone.contains(pt) {
                performDrag(with: event)
                return
            }
        }
        super.sendEvent(event)
    }
}

// MARK: - Minimalist Light-Glass Clipboard Popup UI

struct ClipboardPopupView: View {
    @ObservedObject var vm: ClipboardPopupViewModel
    @ObservedObject var store: ClipboardHistoryStore
    @ObservedObject var settings: SettingsStore
    let onPaste: (ClipboardHistoryItem, Bool?) -> Void
    let onTogglePin: (Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        let visibleItems = vm.filteredItems(from: store.items)

        VStack(spacing: 0) {
            // Minimalist Top Header
            HStack(spacing: 8) {
                Text("剪贴板历史")
                    .font(.system(size: 13.5, weight: .semibold, design: .serif))
                    .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.14))

                Spacer()

                Button(action: {
                    vm.isPinned.toggle()
                    onTogglePin(vm.isPinned)
                }) {
                    Image(systemName: vm.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundColor(vm.isPinned ? .white : Color(white: 0.36))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(vm.isPinned ? Color(red: 0.18, green: 0.19, blue: 0.21) : Color.black.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help(vm.isPinned ? "已固定" : "固定窗口")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Color(white: 0.38))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.black.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 9)

            // Search + Restrained Glass Segmented Filter
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(white: 0.48))
                    TextField("搜索文本...", text: $vm.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.14))
                    if !vm.searchText.isEmpty {
                        Button(action: { vm.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Color(white: 0.55))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.68))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 0.8))
                )

                // Restrained monochrome glass filter (NO colorful pills)
                HStack(spacing: 2) {
                    ForEach(ClipboardFilterMode.allCases) { mode in
                        let active = (vm.filter == mode)
                        Button(action: { vm.filter = mode }) {
                            Text(mode.rawValue)
                                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                                .foregroundColor(active ? Color(red: 0.12, green: 0.13, blue: 0.14) : Color(white: 0.46))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(active ? Color.white.opacity(0.88) : Color.clear)
                                        .shadow(color: active ? Color.black.opacity(0.06) : Color.clear, radius: 2, x: 0, y: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.black.opacity(0.045))
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider().opacity(0.22)

            // Scrollable Card List
            if visibleItems.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 22))
                        .foregroundColor(Color(white: 0.56))
                    Text(vm.searchText.isEmpty ? "暂无剪贴板记录" : "未找到匹配内容")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(white: 0.50))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { idx, item in
                            clipboardCard(item: item, isSelected: idx == vm.selectedIndex)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(
            ZStack {
                LightGlassBlurView()
                Color.white.opacity(0.56)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.95), Color.white.opacity(0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.1
                )
        )
        .shadow(color: Color.black.opacity(0.16), radius: 16, x: 0, y: 8)
        .padding(14)
    }

    private func clipboardCard(item: ClipboardHistoryItem, isSelected: Bool) -> some View {
        let isHovered = (vm.hoveredItemID == item.id)
        let isHighlighted = isHovered || isSelected
        let isExpanded = vm.expandedItemIDs.contains(item.id)
        let needsFoldToggle = (item.kind != .image) && (
            item.plainText.components(separatedBy: .newlines).count > 4 || item.plainText.count > 135
        )
        let altModeIsPlain = (settings.clipboardDefaultPasteMode == .richText)
        let altModeLabel = altModeIsPlain ? "粘贴为纯文本" : "粘贴为富文本"

        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                switch item.kind {
                case .image:
                    if let thumb = store.loadThumbnail(for: item) {
                        Image(nsImage: thumb)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 132, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    } else {
                        Text("图片资源不可用")
                            .font(.system(size: 12))
                            .foregroundColor(Color(white: 0.5))
                    }

                case .richText:
                    if let richNSAttr = vm.cachedRichPreview(for: item, store: store) {
                        NativeRichTextPreview(attributedString: richNSAttr, maxLines: isExpanded ? 0 : 4)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .frame(maxHeight: (!isExpanded && needsFoldToggle) ? 82 : nil, alignment: .top)
                            .clipped()
                    } else {
                        Text(item.plainText)
                            .font(.system(size: 13))
                            .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.14))
                            .lineLimit(isExpanded ? nil : 4)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .plainText:
                    Text(item.plainText)
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.14))
                        .lineLimit(isExpanded ? nil : 4)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if needsFoldToggle {
                    HStack {
                        Spacer()
                        Button(action: { vm.toggleExpanded(item.id) }) {
                            Text(isExpanded ? "收起" : "展开")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(white: 0.44))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.black.opacity(0.045)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isHighlighted ? 0.86 : 0.58))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                isHighlighted ? Color.black.opacity(0.14) : Color.white.opacity(0.75),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(isHighlighted ? 0.06 : 0.025), radius: isHighlighted ? 6 : 3, x: 0, y: 2)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onPaste(item, nil)
            }

            // Hover-only one-off Rich/Plain paste toggle for rich-text items (hidden at rest!)
            if item.kind == .richText && isHovered {
                Button(action: {
                    onPaste(item, altModeIsPlain)
                }) {
                    Text(altModeLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Color(red: 0.16, green: 0.17, blue: 0.19))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.92))
                                .overlay(Capsule().stroke(Color.black.opacity(0.10), lineWidth: 0.8))
                                .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
                        )
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("单次以\(altModeLabel)粘贴")
            }
        }
        .onHover { hovering in
            if hovering {
                vm.hoveredItemID = item.id
            } else if vm.hoveredItemID == item.id {
                vm.hoveredItemID = nil
            }
        }
    }
}

// MARK: - Native AppKit Rich Text Preview (Renders Colors, Links, Highlights & Inline NSTextAttachment Images)

struct NativeRichTextPreview: NSViewRepresentable {
    let attributedString: NSAttributedString
    let maxLines: Int

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBezeled = false
        field.allowsEditingTextAttributes = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.attributedStringValue = attributedString
        nsView.maximumNumberOfLines = maxLines
        nsView.preferredMaxLayoutWidth = 356
    }
}
