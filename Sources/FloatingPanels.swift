import Foundation
import AppKit
import SwiftUI

// MARK: - Toast HUD (Clean Capsule Shadow, Zero Rectangular Artifact)

final class ToastHUD {
    static let shared = ToastHUD()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    func show(_ message: String, duration: TimeInterval = 2.0) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.hideWorkItem?.cancel()
            self.panel?.orderOut(nil)

            let screen = NSScreen.main ?? NSScreen.screens.first
            guard let frame = screen?.visibleFrame else { return }

            let content = HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color(red: 0.30, green: 0.72, blue: 0.42))
                    .font(.system(size: 14))
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color(red: 0.14, green: 0.15, blue: 0.16).opacity(0.95))
                    .shadow(color: Color.black.opacity(0.22), radius: 10, x: 0, y: 4)
            )
            .padding(14)

            let hosting = NSHostingView(rootView: content)
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            let sz = hosting.fittingSize
            let width = min(max(sz.width, 160), 460)
            let height = max(sz.height, 64)

            let rect = NSRect(
                x: frame.midX - width / 2,
                y: frame.maxY - 96,
                width: width,
                height: height
            )

            let p = NSPanel(
                contentRect: rect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.ignoresMouseEvents = true
            p.hasShadow = false
            p.contentView = hosting
            p.alphaValue = 0
            p.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                p.animator().alphaValue = 1.0
            }
            self.panel = p

            let work = DispatchWorkItem { [weak self] in
                guard let panel = self?.panel else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.24
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    panel.orderOut(nil)
                })
            }
            self.hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }
}

// MARK: - Reply Panel ViewModel (ObservableObject, zero @State)

final class ReplyPanelViewModel: ObservableObject {
    @Published var feature: FeatureKind
    @Published var selectedContextText: String?
    @Published var imageData: Data?
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?
    @Published var isPinned: Bool = false
    @Published var copiedToastVisible: Bool = false
    /// Default collapsed for Thinking/Reasoning content
    @Published var showThinkingExpanded: Bool = false
    @Published var lastTokenSummary: String = ""

    @Published var sourceLang: TranslateLanguage
    @Published var targetLang: TranslateLanguage

    private var activeTask: Task<Void, Never>?

    init(feature: FeatureKind, selectedText: String?, imageData: Data?) {
        self.feature = feature
        self.selectedContextText = selectedText
        self.imageData = imageData
        self.sourceLang = SettingsStore.shared.translateSourceLang
        self.targetLang = SettingsStore.shared.translateTargetLang
    }

    var isTranslateFeature: Bool {
        feature == .translate || feature == .screenshotTranslate
    }

    var activeModelName: String {
        SettingsStore.shared.config(for: feature).modelName
    }

    func buildTranslationPrompt() -> String {
        let srcClause = sourceLang == .auto ? "自动检测原文语言" : "原文语言为\(sourceLang.rawValue)"
        let dstClause = "请翻译为自然流畅的\(targetLang.rawValue)"
        if feature == .screenshotTranslate {
            return "请识别图片中的文字（\(srcClause)），并\(dstClause)。只输出译文，不要多余解释。"
        } else {
            let content = selectedContextText ?? ""
            return "请将以下内容（\(srcClause)）\(dstClause)。只输出译文，不要多余解释：\n\n\(content)"
        }
    }

    func retranslateWithCurrentLanguages() {
        SettingsStore.shared.translateSourceLang = sourceLang
        SettingsStore.shared.translateTargetLang = targetLang
        messages.removeAll()
        sendPrompt(buildTranslationPrompt(), useFeature: feature, hideUserPromptInUI: true)
    }

    func sendPrompt(_ prompt: String, useFeature: FeatureKind? = nil, hideUserPromptInUI: Bool = false) {
        let targetFeature = useFeature ?? feature
        self.feature = targetFeature
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || imageData != nil else { return }

        activeTask?.cancel()
        errorMessage = nil
        isStreaming = true

        let attachImage = messages.isEmpty ? imageData : nil
        let userMsg = ChatMessage(role: "user", text: trimmed, imageData: attachImage, isHiddenInUI: hideUserPromptInUI)
        messages.append(userMsg)
        let assistantMsg = ChatMessage(role: "assistant", text: "")
        messages.append(assistantMsg)
        let assistantIndex = messages.count - 1
        inputText = ""

        let historyForAPI = Array(messages.prefix(assistantIndex))
        activeTask = AIClient.shared.streamChat(
            feature: targetFeature,
            messages: historyForAPI,
            onThinkingChunk: { [weak self] chunk in
                guard let self = self, assistantIndex < self.messages.count else { return }
                self.messages[assistantIndex].reasoningText += chunk
            },
            onChunk: { [weak self] chunk in
                guard let self = self, assistantIndex < self.messages.count else { return }
                self.messages[assistantIndex].text += chunk
            },
            onComplete: { [weak self] result in
                guard let self = self else { return }
                self.isStreaming = false
                switch result {
                case .success(let tokens):
                    self.lastTokenSummary = "输入 \(tokens.inputTokens) · 输出 \(tokens.outputTokens) tokens"
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    if assistantIndex < self.messages.count && self.messages[assistantIndex].text.isEmpty {
                        self.messages.remove(at: assistantIndex)
                    }
                }
            }
        )
    }

    func setPrecomputedOCRResult(_ text: String) {
        messages = [
            ChatMessage(role: "assistant", text: text)
        ]
        lastTokenSummary = "本机 Vision OCR 离线识别"
    }

    func stopStreaming() {
        activeTask?.cancel()
        isStreaming = false
    }

    func copyLatestReply() {
        guard let latest = messages.last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latest, forType: .string)
        copiedToastVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copiedToastVisible = false
        }
    }
}

// MARK: - Floating Panel Controller

final class FloatingPanelController: NSObject, NSWindowDelegate {
    static let shared = FloatingPanelController()

    private var capsulePanel: NSPanel?
    private var replyPanel: KeyableFloatingPanel?
    private var replyVM: ReplyPanelViewModel?
    private var outsideClickGlobalMonitor: Any?
    private var outsideClickLocalMonitor: Any?

    private override init() {
        super.init()
    }

    func showSelectionCapsule(for text: String, near mousePoint: NSPoint) {
        dismissSelectionCapsule()

        let capsuleView = SelectionCapsuleView { [weak self] feature in
            self?.dismissSelectionCapsule()
            let autoSend = (feature != .followUp)
            let prompt: String?
            switch feature {
            case .translate: prompt = nil // built with selected source/target language
            case .explain: prompt = "请解释以下内容：\n\n\(text)"
            case .summarize: prompt = "请总结以下内容的核心要点：\n\n\(text)"
            case .followUp: prompt = nil
            default: prompt = text
            }
            self?.showReplyPanel(
                feature: feature,
                selectedText: text,
                imageData: nil,
                initialPrompt: prompt,
                autoSend: autoSend,
                near: mousePoint
            )
        }

        let hosting = NSHostingView(rootView: capsuleView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        let fitSize = hosting.fittingSize
        let width = max(fitSize.width, 326)
        let height = max(fitSize.height, 70)

        let screen = NSScreen.screens.first(where: { NSMouseInRect(mousePoint, $0.frame, false) }) ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = mousePoint.x - width / 2
        x = max(bounds.minX + 6, min(x, bounds.maxX - width - 6))
        var y = mousePoint.y + 8
        if y + height > bounds.maxY - 6 {
            y = mousePoint.y - height - 8
        }

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("LuminaSelectionCapsule")
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // Clean SwiftUI shadow inside transparent margin
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.contentView = hosting
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }

        self.capsulePanel = panel
    }

    func dismissSelectionCapsule() {
        capsulePanel?.orderOut(nil)
        capsulePanel = nil
    }

    func showOCRResultPanel(extractedText: String, imageData: Data?, near point: NSPoint) {
        let vm = ReplyPanelViewModel(feature: .screenshotOCR, selectedText: nil, imageData: imageData)
        vm.setPrecomputedOCRResult(extractedText)
        presentReplyPanel(vm: vm, near: point)
    }

    func showReplyPanel(
        feature: FeatureKind,
        selectedText: String?,
        imageData: Data?,
        initialPrompt: String?,
        autoSend: Bool,
        near point: NSPoint
    ) {
        let vm = ReplyPanelViewModel(feature: feature, selectedText: selectedText, imageData: imageData)
        presentReplyPanel(vm: vm, near: point)

        if autoSend {
            if vm.isTranslateFeature {
                vm.sendPrompt(vm.buildTranslationPrompt(), useFeature: feature, hideUserPromptInUI: true)
            } else if let prompt = initialPrompt {
                vm.sendPrompt(prompt, useFeature: feature, hideUserPromptInUI: true)
            }
        }
    }

    private func presentReplyPanel(vm: ReplyPanelViewModel, near point: NSPoint) {
        dismissReplyPanel()
        self.replyVM = vm

        let width: CGFloat = 500
        let height: CGFloat = 450
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = point.x - width / 2
        x = max(bounds.minX + 8, min(x, bounds.maxX - width - 8))
        var y = point.y - height - 8
        if y < bounds.minY + 8 {
            y = min(point.y + 8, bounds.maxY - height - 8)
        }

        // Native chromeless NSPanel: gives genuine macOS shadow, rounded corners,
        // wide 4-edge + 4-corner resize zones, and native macOS resize cursors everywhere,
        // while .nonactivatingPanel prevents raising the main dashboard window!
        let panel = KeyableFloatingPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("LuminaReplyPanel")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
        panel.isOpaque = true
        panel.hasShadow = true // Native macOS window shadow
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 360, height: 280)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let rootView = ReplyFloatingView(
            vm: vm,
            onTogglePin: { [weak panel] pinned in
                panel?.level = pinned ? .statusBar : .floating
            },
            onOpenSettings: { [weak self] in
                self?.dismissReplyPanel()
                NotificationCenter.default.post(name: .luminaOpenMainWindow, object: nil)
            },
            onClose: { [weak self] in
                self?.dismissReplyPanel()
            }
        )

        let hosting = NSHostingView(rootView: rootView)
        panel.contentView = hosting
        panel.alphaValue = 0
        // IMPORTANT: Do NOT call NSApp.activate() so the main dashboard window does not jump to front!
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }

        self.replyPanel = panel
        installOutsideClickMonitors()
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()

        // Global clicks in other apps
        outsideClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.handlePotentialOutsideClick()
        }

        // Local clicks in other LuminaAI windows (e.g. clicking main dashboard)
        outsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self = self,
               let panel = self.replyPanel,
               let vm = self.replyVM,
               !vm.isPinned,
               let clickedWin = event.window,
               clickedWin !== panel,
               clickedWin.level.rawValue < NSWindow.Level.popUpMenu.rawValue {
                self.dismissReplyPanel()
            }
            return event
        }
    }

    private func handlePotentialOutsideClick() {
        guard let panel = replyPanel, let vm = replyVM, !vm.isPinned else { return }
        let clickPoint = NSEvent.mouseLocation
        if !panel.frame.contains(clickPoint) {
            DispatchQueue.main.async { [weak self] in
                self?.dismissReplyPanel()
            }
        }
    }

    private func removeOutsideClickMonitors() {
        if let m = outsideClickGlobalMonitor {
            NSEvent.removeMonitor(m)
            outsideClickGlobalMonitor = nil
        }
        if let m = outsideClickLocalMonitor {
            NSEvent.removeMonitor(m)
            outsideClickLocalMonitor = nil
        }
    }

    func dismissReplyPanel() {
        removeOutsideClickMonitors()
        replyVM?.stopStreaming()
        replyPanel?.orderOut(nil)
        replyPanel = nil
    }
}

// MARK: - Native Chromeless Resizable Panel (100% Native macOS Resize & Shadow)

final class KeyableFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // Use native performDrag(with:) when dragging inside the top header bar (excluding right buttons)
        if event.type == .leftMouseDown {
            let pt = event.locationInWindow
            let headerRect = NSRect(x: 10, y: frame.height - 48, width: max(40, frame.width - 150), height: 40)
            if headerRect.contains(pt) {
                performDrag(with: event)
                return
            }
        }
        super.sendEvent(event)
    }
}

// MARK: - Selection Capsule View (Clean Shadow Margin, Zero Rectangular Corners)

struct SelectionCapsuleView: View {
    let onSelect: (FeatureKind) -> Void

    private let actions: [FeatureKind] = [.translate, .explain, .summarize, .followUp]

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.15, green: 0.16, blue: 0.18), Color(red: 0.28, green: 0.29, blue: 0.31)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(red: 0.92, green: 0.86, blue: 0.75))
                )
                .padding(.trailing, 2)

            ForEach(actions) { kind in
                Button(action: { onSelect(kind) }) {
                    HStack(spacing: 4) {
                        Image(systemName: kind.symbolName)
                            .font(.system(size: 11, weight: .medium))
                        Text(kind.shortName)
                            .font(.system(size: 12.5, weight: .medium))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.14))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.045)))
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(red: 0.97, green: 0.97, blue: 0.98))
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
        )
        .padding(14) // Transparent outer margin prevents any rectangular dark corners
    }
}

// MARK: - Floating Reply Window View

struct ReplyFloatingView: View {
    @ObservedObject var vm: ReplyPanelViewModel
    let onTogglePin: (Bool) -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar (dragged natively by KeyableFloatingPanel)
            HStack(spacing: 10) {
                    Circle()
                        .fill(Color(red: 0.15, green: 0.16, blue: 0.18))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: vm.feature.symbolName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(red: 0.93, green: 0.88, blue: 0.78))
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(vm.feature.displayName)
                            .font(.system(size: 13.5, weight: .semibold, design: .serif))
                            .foregroundColor(Color(red: 0.11, green: 0.12, blue: 0.13))
                        Text(vm.activeModelName)
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(white: 0.48))
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: { vm.copyLatestReply() }) {
                        HStack(spacing: 4) {
                            Image(systemName: vm.copiedToastVisible ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                            Text(vm.copiedToastVisible ? "已复制" : "复制")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundColor(vm.copiedToastVisible ? Color(red: 0.20, green: 0.65, blue: 0.32) : Color(red: 0.15, green: 0.16, blue: 0.18))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.05)))
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        vm.isPinned.toggle()
                        onTogglePin(vm.isPinned)
                    }) {
                        Image(systemName: vm.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 11.5))
                            .foregroundColor(vm.isPinned ? .white : Color(white: 0.35))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(vm.isPinned ? Color(red: 0.15, green: 0.16, blue: 0.18) : Color.black.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help(vm.isPinned ? "已固定（点击别处不会关闭）" : "固定浮窗（点击别处不自动关闭）")

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(white: 0.38))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.black.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Color(red: 0.93, green: 0.93, blue: 0.94))

                Divider().opacity(0.32)

                // Translation Source -> Target Language Selector Bar
                if vm.isTranslateFeature {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(
                            get: { vm.sourceLang },
                            set: { newVal in
                                vm.sourceLang = newVal
                                vm.retranslateWithCurrentLanguages()
                            }
                        )) {
                            ForEach(TranslateLanguage.sourceOptions) { lang in
                                Text(lang.rawValue).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 96)

                        Image(systemName: "arrow.right")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(Color(white: 0.45))

                        Picker("", selection: Binding(
                            get: { vm.targetLang },
                            set: { newVal in
                                vm.targetLang = newVal
                                vm.retranslateWithCurrentLanguages()
                            }
                        )) {
                            ForEach(TranslateLanguage.targetOptions) { lang in
                                Text(lang.rawValue).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 88)

                        Spacer()

                        Button(action: { vm.retranslateWithCurrentLanguages() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10.5))
                                Text("重译")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(Color(red: 0.16, green: 0.17, blue: 0.19))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.055)))
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isStreaming)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.95, green: 0.95, blue: 0.96))
                    Divider().opacity(0.25)
                }

                // Screenshot thumbnail preview (for screenshot features only; "选中原文" removed per user request)
                if let imgData = vm.imageData, let nsImage = NSImage(data: imgData) {
                    HStack(spacing: 10) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 68)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.08), lineWidth: 1))

                        VStack(alignment: .leading, spacing: 5) {
                            Text("已附带截图")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(Color(red: 0.16, green: 0.17, blue: 0.18))
                            if vm.messages.isEmpty && !vm.isTranslateFeature {
                                HStack(spacing: 5) {
                                    quickChip("解释内容") { vm.sendPrompt("请详细解释这张截图的内容。", hideUserPromptInUI: true) }
                                    quickChip("提取要点") { vm.sendPrompt("请提炼这张截图的关键要点。", hideUserPromptInUI: true) }
                                    quickChip("排查报错") { vm.sendPrompt("请分析截图中的报错或问题并给出解决建议。", hideUserPromptInUI: true) }
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color(red: 0.95, green: 0.95, blue: 0.96))
                    Divider().opacity(0.25)
                }

                // Messages area (hides auto-sent initial API prompt!)
                ScrollView {
                    VStack(alignment: .leading, spacing: 11) {
                        let visibleMessages = vm.messages.filter { !$0.isHiddenInUI }

                        if visibleMessages.isEmpty && !vm.isStreaming && vm.errorMessage == nil {
                            Text("在下方输入你想了解的问题，按回车发送。")
                                .font(.system(size: 13))
                                .foregroundColor(Color(white: 0.5))
                                .padding(.top, 24)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        ForEach(visibleMessages) { msg in
                            if msg.role == "user" {
                                HStack {
                                    Spacer(minLength: 40)
                                    Text(msg.text)
                                        .font(.system(size: 12.5))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color(red: 0.16, green: 0.17, blue: 0.19))
                                        )
                                        .textSelection(.enabled)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    if !msg.reasoningText.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Button(action: { vm.showThinkingExpanded.toggle() }) {
                                                HStack(spacing: 5) {
                                                    Image(systemName: "brain")
                                                        .font(.system(size: 10.5))
                                                    Text(vm.isStreaming && msg.text.isEmpty ? "深度思考中（点击展开）" : "深度思考过程")
                                                        .font(.system(size: 11, weight: .semibold))
                                                    Spacer()
                                                    Image(systemName: vm.showThinkingExpanded ? "chevron.up" : "chevron.down")
                                                        .font(.system(size: 10))
                                                }
                                                .foregroundColor(Color(white: 0.45))
                                            }
                                            .buttonStyle(.plain)

                                            if vm.showThinkingExpanded {
                                                Text(msg.reasoningText)
                                                    .font(.system(size: 11.5))
                                                    .foregroundColor(Color(white: 0.44))
                                                    .lineSpacing(3)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                        .padding(9)
                                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.035)))
                                    }

                                    if msg.text.isEmpty && vm.isStreaming {
                                        Text(msg.reasoningText.isEmpty ? "思考中..." : "正在生成回答...")
                                            .font(.system(size: 13.5))
                                            .foregroundColor(Color(white: 0.45))
                                    } else {
                                        MarkdownMessageView(markdown: msg.text)
                                    }
                                }
                                .padding(13)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color.white.opacity(0.92))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14)
                                                .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                        )
                                )
                            }
                        }

                        if let err = vm.errorMessage {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(Color(red: 0.85, green: 0.33, blue: 0.31))
                                    Text(err)
                                        .font(.system(size: 12.5))
                                        .foregroundColor(Color(red: 0.72, green: 0.22, blue: 0.20))
                                }
                                Button("前往设置配置 API") {
                                    onOpenSettings()
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color(red: 0.15, green: 0.16, blue: 0.18)))
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(red: 0.99, green: 0.93, blue: 0.93))
                            )
                        }
                    }
                    .padding(14)
                }

                // Footer status + follow-up input
                VStack(spacing: 7) {
                    if !vm.lastTokenSummary.isEmpty || vm.isStreaming {
                        HStack {
                            if vm.isStreaming {
                                ProgressView()
                                    .scaleEffect(0.55)
                                    .frame(width: 12, height: 12)
                                Text("流式输出中...")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(white: 0.45))
                            } else {
                                Text(vm.lastTokenSummary)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(Color(white: 0.5))
                            }
                            Spacer()
                            if vm.isStreaming {
                                Button("停止") { vm.stopStreaming() }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Color(red: 0.85, green: 0.33, blue: 0.31))
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    HStack(spacing: 8) {
                        TextField("继续追问或输入指令...", text: $vm.inputText, onCommit: {
                            sendFollowUp()
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.95))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08), lineWidth: 1))
                        )

                        Button(action: sendFollowUp) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(
                                    Circle().fill(
                                        vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? Color(white: 0.72)
                                        : Color(red: 0.15, green: 0.16, blue: 0.18)
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isStreaming)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .padding(.top, 6)
                .background(Color(red: 0.94, green: 0.94, blue: 0.95))
            }
            .background(Color(red: 0.96, green: 0.96, blue: 0.97))
            .ignoresSafeArea()
    }

    private func sendFollowUp() {
        let text = vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if vm.messages.isEmpty, let ctx = vm.selectedContextText, !ctx.isEmpty {
            vm.sendPrompt("针对以下内容：\n\"\(ctx)\"\n\n我的问题是：\(text)", useFeature: vm.feature == .screenshotAsk ? .screenshotAsk : .followUp, hideUserPromptInUI: false)
        } else {
            vm.sendPrompt(text, useFeature: vm.feature == .screenshotAsk ? .screenshotAsk : .followUp, hideUserPromptInUI: false)
        }
    }

    private func quickChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(red: 0.18, green: 0.19, blue: 0.20))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rich Markdown & Emoji Message Renderer (Zero @State)

struct MarkdownMessageView: View {
    let markdown: String

    private enum Block: Identifiable {
        case text(id: Int, content: String)
        case code(id: Int, language: String, code: String)

        var id: Int {
            switch self {
            case .text(let id, _): return id
            case .code(let id, _, _): return id
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        let lines = markdown.components(separatedBy: "\n")
        var inCode = false
        var codeLang = ""
        var buffer: [String] = []
        var nextID = 0

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    result.append(.code(id: nextID, language: codeLang, code: buffer.joined(separator: "\n")))
                    nextID += 1
                    buffer.removeAll()
                    codeLang = ""
                    inCode = false
                } else {
                    if !buffer.isEmpty {
                        result.append(.text(id: nextID, content: buffer.joined(separator: "\n")))
                        nextID += 1
                        buffer.removeAll()
                    }
                    codeLang = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else {
                buffer.append(line)
            }
        }
        if !buffer.isEmpty {
            if inCode {
                result.append(.code(id: nextID, language: codeLang, code: buffer.joined(separator: "\n")))
            } else {
                result.append(.text(id: nextID, content: buffer.joined(separator: "\n")))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .code(_, let lang, let code):
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(lang.isEmpty ? "代码" : lang)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(Color(white: 0.48))
                            Spacer()
                            Button("复制代码") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                                ToastHUD.shared.show("已复制代码")
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(Color(white: 0.35))
                            .buttonStyle(.plain)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color(red: 0.14, green: 0.15, blue: 0.18))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.045))
                    )

                case .text(_, let content):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(content.components(separatedBy: "\n").enumerated()), id: \.offset) { _, rawLine in
                            renderRichLine(rawLine)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderRichLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 3)
        } else if trimmed.hasPrefix("### ") {
            inlineMarkdownText(String(trimmed.dropFirst(4)), size: 14, weight: .semibold)
                .padding(.top, 2)
        } else if trimmed.hasPrefix("## ") {
            inlineMarkdownText(String(trimmed.dropFirst(3)), size: 15, weight: .bold)
                .padding(.top, 3)
        } else if trimmed.hasPrefix("# ") {
            inlineMarkdownText(String(trimmed.dropFirst(2)), size: 16, weight: .bold)
                .padding(.top, 4)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(Color(red: 0.25, green: 0.26, blue: 0.28))
                inlineMarkdownText(String(trimmed.dropFirst(2)), size: 13.5, weight: .regular)
            }
        } else {
            inlineMarkdownText(line, size: 13.5, weight: .regular)
        }
    }

    private func inlineMarkdownText(_ raw: String, size: CGFloat, weight: Font.Weight) -> some View {
        let attr: AttributedString
        if let parsed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            attr = parsed
        } else {
            attr = AttributedString(raw)
        }
        return Text(attr)
            .font(.system(size: size, weight: weight))
            .lineSpacing(4)
            .foregroundColor(Color(red: 0.12, green: 0.13, blue: 0.14))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
