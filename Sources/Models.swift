import Foundation
import AppKit
import Carbon
import ServiceManagement

// MARK: - Feature Kind

enum FeatureKind: String, CaseIterable, Codable, Identifiable {
    case translate = "translate"
    case explain = "explain"
    case summarize = "summarize"
    case followUp = "followUp"
    case screenshotOCR = "screenshotOCR"
    case screenshotTranslate = "screenshotTranslate"
    case screenshotAsk = "screenshotAsk"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .translate: return "划词翻译"
        case .explain: return "划词解释"
        case .summarize: return "划词总结"
        case .followUp: return "划词追问"
        case .screenshotOCR: return "截屏提取文字"
        case .screenshotTranslate: return "截屏 AI 翻译"
        case .screenshotAsk: return "截屏多模态提问"
        }
    }

    var shortName: String {
        switch self {
        case .translate: return "翻译"
        case .explain: return "解释"
        case .summarize: return "总结"
        case .followUp: return "追问"
        case .screenshotOCR: return "OCR"
        case .screenshotTranslate: return "译图"
        case .screenshotAsk: return "识图"
        }
    }

    var symbolName: String {
        switch self {
        case .translate: return "character.book.closed"
        case .explain: return "lightbulb"
        case .summarize: return "text.alignleft"
        case .followUp: return "bubble.left.and.bubble.right"
        case .screenshotOCR: return "text.viewfinder"
        case .screenshotTranslate: return "globe"
        case .screenshotAsk: return "sparkles.rectangle.stack"
        }
    }

    var isVisionCapable: Bool {
        switch self {
        case .screenshotOCR, .screenshotTranslate, .screenshotAsk:
            return true
        default:
            return false
        }
    }

    var defaultSystemPrompt: String {
        switch self {
        case .translate:
            return "你是一位精通中英文的专业翻译助手。请将用户选中的内容自然、准确地翻译：如果是外文则翻译为流畅的简体中文，如果是中文则翻译为地道的英文。只输出译文，不要多余寒暄。"
        case .explain:
            return "你是一位清晰易懂的知识讲解专家。请用简明扼要的中文解释用户选中的概念、术语或代码片段，必要时给出简短示例。"
        case .summarize:
            return "你是一位高效的内容总结助手。请用清晰的要点（Bullet Points）提炼用户选中内容的核心观点与关键结论。"
        case .followUp:
            return "你是一位专业、简洁的个人 AI 助手。请围绕用户选中的上下文回答用户的追问，回答应直接、有条理。"
        case .screenshotOCR:
            return "请准确提取图片中的所有文字内容，保持原有排版和段落结构，不要添加额外解释。"
        case .screenshotTranslate:
            return "请识别图片中的文字并将其准确翻译为自然流畅的简体中文（若原文已是中文则翻译为地道英文）。只输出清晰的译文。"
        case .screenshotAsk:
            return "你是一位多模态视觉 AI 助手。请结合用户提供的截图内容，准确、详细且有条理地回答用户的问题。"
        }
    }

    var chartColorHex: String {
        switch self {
        case .translate: return "#222326"
        case .explain: return "#34A853"
        case .summarize: return "#D9534F"
        case .followUp: return "#C59B5F"
        case .screenshotOCR: return "#4A78B8"
        case .screenshotTranslate: return "#7A63B8"
        case .screenshotAsk: return "#2D8A8A"
        }
    }
}

// MARK: - Selection Capsule Action Item

enum CapsuleActionItem: String, CaseIterable, Codable, Identifiable {
    case copy = "copy"
    case translate = "translate"
    case explain = "explain"
    case summarize = "summarize"
    case followUp = "followUp"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .copy: return "复制"
        case .translate: return "翻译"
        case .explain: return "解释"
        case .summarize: return "总结"
        case .followUp: return "追问"
        }
    }

    var displayName: String {
        switch self {
        case .copy: return "复制（支持网页强力复制）"
        case .translate: return "划词翻译"
        case .explain: return "划词解释"
        case .summarize: return "划词总结"
        case .followUp: return "划词追问"
        }
    }

    var symbolName: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .translate: return "character.book.closed"
        case .explain: return "lightbulb"
        case .summarize: return "text.alignleft"
        case .followUp: return "bubble.left.and.bubble.right"
        }
    }

    var featureKind: FeatureKind? {
        switch self {
        case .copy: return nil
        case .translate: return .translate
        case .explain: return .explain
        case .summarize: return .summarize
        case .followUp: return .followUp
        }
    }
}

struct CapsuleActionConfig: Codable, Equatable, Identifiable {
    var id: String { action.rawValue }
    var action: CapsuleActionItem
    var isEnabled: Bool

    static var defaultList: [CapsuleActionConfig] {
        [
            CapsuleActionConfig(action: .copy, isEnabled: true),
            CapsuleActionConfig(action: .translate, isEnabled: true),
            CapsuleActionConfig(action: .explain, isEnabled: true),
            CapsuleActionConfig(action: .summarize, isEnabled: true),
            CapsuleActionConfig(action: .followUp, isEnabled: true)
        ]
    }
}

// MARK: - Log Retention Period

enum LogRetentionPeriod: String, CaseIterable, Codable, Identifiable {
    case oneDay = "1天"
    case oneWeek = "1周"
    case oneMonth = "1个月"

    var id: String { rawValue }

    var timeInterval: TimeInterval {
        switch self {
        case .oneDay: return 24 * 3600
        case .oneWeek: return 7 * 24 * 3600
        case .oneMonth: return 30 * 24 * 3600
        }
    }
}

// MARK: - Translation Languages

enum TranslateLanguage: String, CaseIterable, Codable, Identifiable {
    case auto = "自动检测"
    case chinese = "中文"
    case english = "英文"
    case japanese = "日文"
    case korean = "韩文"
    case french = "法文"
    case german = "德文"
    case spanish = "西班牙文"

    var id: String { rawValue }

    static var sourceOptions: [TranslateLanguage] {
        allCases
    }

    static var targetOptions: [TranslateLanguage] {
        allCases.filter { $0 != .auto }
    }
}

// MARK: - Thinking Effort

enum ThinkingEffort: String, CaseIterable, Codable, Identifiable {
    case low = "low"
    case medium = "medium"
    case high = "high"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "低 (Low)"
        case .medium: return "中 (Medium)"
        case .high: return "高 (High)"
        }
    }
}

// MARK: - API Config

struct APIEndpointConfig: Codable, Equatable, Identifiable {
    var id: String { feature.rawValue }
    var feature: FeatureKind
    var providerName: String
    var baseURL: String
    var apiKey: String
    var modelName: String
    var systemPrompt: String
    var temperature: Double
    var enableThinking: Bool
    var thinkingEffort: ThinkingEffort
    /// Price per 1M input tokens (in selected currency)
    var inputPricePerMillion: Double
    /// Price per 1M output tokens (in selected currency)
    var outputPricePerMillion: Double
    var currencySymbol: String

    static func defaultConfig(for feature: FeatureKind) -> APIEndpointConfig {
        let isVision = feature.isVisionCapable
        return APIEndpointConfig(
            feature: feature,
            providerName: "火山方舟 · 豆包",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            apiKey: "",
            modelName: isVision ? "doubao-1-5-vision-pro-32k-250115" : "doubao-1-5-pro-32k-250115",
            systemPrompt: feature.defaultSystemPrompt,
            temperature: 0.3,
            enableThinking: false,
            thinkingEffort: .medium,
            inputPricePerMillion: isVision ? 3.0 : 0.8,
            outputPricePerMillion: isVision ? 9.0 : 2.0,
            currencySymbol: "¥"
        )
    }

    init(
        feature: FeatureKind,
        providerName: String,
        baseURL: String,
        apiKey: String,
        modelName: String,
        systemPrompt: String,
        temperature: Double,
        enableThinking: Bool = false,
        thinkingEffort: ThinkingEffort = .medium,
        inputPricePerMillion: Double,
        outputPricePerMillion: Double,
        currencySymbol: String
    ) {
        self.feature = feature
        self.providerName = providerName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.enableThinking = enableThinking
        self.thinkingEffort = thinkingEffort
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.currencySymbol = currencySymbol
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.feature = try c.decode(FeatureKind.self, forKey: .feature)
        self.providerName = try c.decode(String.self, forKey: .providerName)
        self.baseURL = try c.decode(String.self, forKey: .baseURL)
        self.apiKey = try c.decode(String.self, forKey: .apiKey)
        self.modelName = try c.decode(String.self, forKey: .modelName)
        self.systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        self.temperature = try c.decode(Double.self, forKey: .temperature)
        self.enableThinking = try c.decodeIfPresent(Bool.self, forKey: .enableThinking) ?? false
        self.thinkingEffort = try c.decodeIfPresent(ThinkingEffort.self, forKey: .thinkingEffort) ?? .medium
        self.inputPricePerMillion = try c.decode(Double.self, forKey: .inputPricePerMillion)
        self.outputPricePerMillion = try c.decode(Double.self, forKey: .outputPricePerMillion)
        self.currencySymbol = try c.decode(String.self, forKey: .currencySymbol)
    }

    /// Key used to group identical APIs in charts and pricing summaries
    var apiGroupKey: String {
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProvider.isEmpty && !trimmedModel.isEmpty {
            return "\(trimmedProvider) / \(trimmedModel)"
        }
        return trimmedModel.isEmpty ? feature.displayName : trimmedModel
    }

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Hotkey Config

struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey)

    /// Default: Option + Shift + A
    static let defaultScreenshot = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_A),
        modifiers: UInt32(optionKey | shiftKey)
    )

    var displayString: String {
        var parts: [String] = []
        if (modifiers & UInt32(controlKey)) != 0 { parts.append("⌃") }
        if (modifiers & UInt32(optionKey)) != 0 { parts.append("⌥") }
        if (modifiers & UInt32(shiftKey)) != 0 { parts.append("⇧") }
        if (modifiers & UInt32(cmdKey)) != 0 { parts.append("⌘") }
        parts.append(Self.keyCodeToString(keyCode))
        return parts.joined()
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    static func keyCodeToString(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key\(keyCode)"
        }
    }
}

// MARK: - Usage Record

struct UsageRecord: Codable, Identifiable {
    var id: UUID
    var timestamp: Date
    var feature: FeatureKind
    var providerName: String
    var modelName: String
    var inputTokens: Int
    var outputTokens: Int
    var estimatedCost: Double
    var currencySymbol: String
    var success: Bool
    var previewText: String

    var totalTokens: Int { inputTokens + outputTokens }
}

// MARK: - Chat Message

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String // "user" or "assistant"
    var text: String
    var reasoningText: String = ""
    var imageData: Data? = nil
    var isHiddenInUI: Bool = false
    let timestamp = Date()
}

// MARK: - App Settings Store

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var showInDock: Bool {
        didSet { save() }
    }
    @Published var showInMenuBar: Bool {
        didSet { save() }
    }
    @Published var launchAtLogin: Bool = false
    @Published var enableTextSelectionPopup: Bool {
        didSet { save() }
    }
    @Published var useClipboardFallbackForSelection: Bool {
        didSet { save() }
    }
    @Published var useNativeVisionOCRFirst: Bool {
        didSet { save() }
    }
    @Published var screenshotHotkey: HotkeyConfig {
        didSet {
            save()
            NotificationCenter.default.post(name: .luminaHotkeyDidChange, object: screenshotHotkey)
        }
    }
    @Published var translateSourceLang: TranslateLanguage {
        didSet { save() }
    }
    @Published var translateTargetLang: TranslateLanguage {
        didSet { save() }
    }
    @Published var logRetentionPeriod: LogRetentionPeriod {
        didSet {
            save()
            AppLogger.shared.pruneNow()
        }
    }
    @Published var logMaxLines: Int {
        didSet {
            save()
            AppLogger.shared.pruneNow()
        }
    }
    @Published var githubRepo: String {
        didSet { save() }
    }
    @Published var capsuleActions: [CapsuleActionConfig] {
        didSet { save() }
    }
    @Published var apiConfigs: [FeatureKind: APIEndpointConfig] {
        didSet { save() }
    }

    private let settingsURL: URL

    private struct PersistedSettings: Codable {
        var showInDock: Bool
        var showInMenuBar: Bool
        var enableTextSelectionPopup: Bool
        var useClipboardFallbackForSelection: Bool
        var useNativeVisionOCRFirst: Bool
        var screenshotHotkey: HotkeyConfig
        var translateSourceLang: TranslateLanguage?
        var translateTargetLang: TranslateLanguage?
        var logRetentionPeriod: LogRetentionPeriod?
        var logMaxLines: Int?
        var githubRepo: String?
        var capsuleActions: [CapsuleActionConfig]?
        var apiConfigs: [String: APIEndpointConfig]
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LuminaAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.settingsURL = dir.appendingPathComponent("settings.json")

        var defaults: [FeatureKind: APIEndpointConfig] = [:]
        for kind in FeatureKind.allCases {
            defaults[kind] = APIEndpointConfig.defaultConfig(for: kind)
        }

        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? JSONDecoder().decode(PersistedSettings.self, from: data) {
            self.showInDock = decoded.showInDock
            self.showInMenuBar = decoded.showInMenuBar
            self.enableTextSelectionPopup = decoded.enableTextSelectionPopup
            self.useClipboardFallbackForSelection = decoded.useClipboardFallbackForSelection
            self.useNativeVisionOCRFirst = decoded.useNativeVisionOCRFirst
            self.screenshotHotkey = decoded.screenshotHotkey
            self.translateSourceLang = decoded.translateSourceLang ?? .auto
            self.translateTargetLang = decoded.translateTargetLang ?? .chinese
            self.logRetentionPeriod = decoded.logRetentionPeriod ?? .oneWeek
            self.logMaxLines = decoded.logMaxLines ?? 500
            let savedRepo = decoded.githubRepo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.githubRepo = savedRepo.isEmpty ? "oswin-creator/LuminaAI" : savedRepo
            self.capsuleActions = Self.normalizedCapsuleActions(decoded.capsuleActions)
            for (raw, cfg) in decoded.apiConfigs {
                if let kind = FeatureKind(rawValue: raw) {
                    defaults[kind] = cfg
                }
            }
            self.apiConfigs = defaults
        } else {
            self.showInDock = true
            self.showInMenuBar = true
            self.enableTextSelectionPopup = true
            self.useClipboardFallbackForSelection = true
            self.useNativeVisionOCRFirst = true
            self.screenshotHotkey = .defaultScreenshot
            self.translateSourceLang = .auto
            self.translateTargetLang = .chinese
            self.logRetentionPeriod = .oneWeek
            self.logMaxLines = 500
            self.githubRepo = "oswin-creator/LuminaAI"
            self.capsuleActions = CapsuleActionConfig.defaultList
            self.apiConfigs = defaults
        }
        self.launchAtLogin = Self.isLaunchAtLoginEnabled()
    }

    func config(for feature: FeatureKind) -> APIEndpointConfig {
        apiConfigs[feature] ?? APIEndpointConfig.defaultConfig(for: feature)
    }

    func updateConfig(_ config: APIEndpointConfig) {
        apiConfigs[config.feature] = config
    }

    /// Copy API credentials & endpoint from one feature to target features
    func copyAPIConfig(
        from source: FeatureKind,
        to targets: [FeatureKind],
        includeModel: Bool,
        includePricing: Bool,
        includeThinking: Bool = false
    ) {
        let src = config(for: source)
        var updated = apiConfigs
        for target in targets where target != source {
            var dst = updated[target] ?? APIEndpointConfig.defaultConfig(for: target)
            dst.providerName = src.providerName
            dst.baseURL = src.baseURL
            dst.apiKey = src.apiKey
            if includeModel {
                dst.modelName = src.modelName
            }
            if includePricing {
                dst.inputPricePerMillion = src.inputPricePerMillion
                dst.outputPricePerMillion = src.outputPricePerMillion
                dst.currencySymbol = src.currencySymbol
            }
            if includeThinking {
                dst.enableThinking = src.enableThinking
                dst.thinkingEffort = src.thinkingEffort
            }
            updated[target] = dst
        }
        apiConfigs = updated
        AppLogger.shared.info("Copied API config from \(source.displayName) to \(targets.count) feature(s)")
    }

    func resetSystemPrompt(for feature: FeatureKind) {
        var cfg = config(for: feature)
        cfg.systemPrompt = feature.defaultSystemPrompt
        apiConfigs[feature] = cfg
    }

    func updatePricing(for feature: FeatureKind, inputPrice: Double, outputPrice: Double, currency: String) {
        var cfg = config(for: feature)
        cfg.inputPricePerMillion = max(0, inputPrice)
        cfg.outputPricePerMillion = max(0, outputPrice)
        cfg.currencySymbol = currency.isEmpty ? "¥" : currency
        apiConfigs[feature] = cfg
    }

    var enabledCapsuleActions: [CapsuleActionItem] {
        let enabled = capsuleActions.filter(\.isEnabled).map(\.action)
        return enabled.isEmpty ? [.copy] : enabled
    }

    func toggleCapsuleAction(_ action: CapsuleActionItem, enabled: Bool) {
        var list = capsuleActions
        guard let idx = list.firstIndex(where: { $0.action == action }) else { return }
        if !enabled && list.filter(\.isEnabled).count <= 1 {
            ToastHUD.shared.show("胶囊中至少需要保留 1 个功能")
            return
        }
        list[idx].isEnabled = enabled
        capsuleActions = list
    }

    func moveCapsuleAction(at index: Int, offset: Int) {
        let target = index + offset
        guard index >= 0, index < capsuleActions.count, target >= 0, target < capsuleActions.count else { return }
        var list = capsuleActions
        let item = list.remove(at: index)
        list.insert(item, at: target)
        capsuleActions = list
    }

    func resetCapsuleActions() {
        capsuleActions = CapsuleActionConfig.defaultList
    }

    private static func normalizedCapsuleActions(_ saved: [CapsuleActionConfig]?) -> [CapsuleActionConfig] {
        guard var list = saved, !list.isEmpty else {
            return CapsuleActionConfig.defaultList
        }
        let existing = Set(list.map(\.action))
        for item in CapsuleActionConfig.defaultList where !existing.contains(item.action) {
            list.append(item)
        }
        return list
    }

    func applyPresenceChange(dock: Bool, menuBar: Bool) {
        // Ensure at least one entry point stays visible
        if !dock && !menuBar {
            showInMenuBar = true
            showInDock = false
        } else {
            showInDock = dock
            showInMenuBar = menuBar
        }
        NotificationCenter.default.post(name: .luminaPresenceDidChange, object: nil)
    }

    private static var launchAgentPlistURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LaunchAgents/com.lumina.ai.assistant.plist")
    }

    static func isLaunchAtLoginEnabled() -> Bool {
        if SMAppService.mainApp.status == .enabled {
            return true
        }
        return FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            do {
                try SMAppService.mainApp.register()
                try? FileManager.default.removeItem(at: Self.launchAgentPlistURL)
                launchAtLogin = true
                ToastHUD.shared.show("已开启开机自动启动")
                AppLogger.shared.info("Enabled Launch at Login via SMAppService")
                return
            } catch {
                // Fallback to user LaunchAgent plist so it works from any folder (e.g. Documents)
                let appPath = Bundle.main.bundlePath
                let plist: [String: Any] = [
                    "Label": "com.lumina.ai.assistant",
                    "ProgramArguments": ["/usr/bin/open", "-a", appPath],
                    "RunAtLoad": true
                ]
                let dir = Self.launchAgentPlistURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                    do {
                        try data.write(to: Self.launchAgentPlistURL, options: .atomic)
                        launchAtLogin = true
                        ToastHUD.shared.show("已开启开机自动启动")
                        AppLogger.shared.info("Enabled Launch at Login via LaunchAgent plist")
                        return
                    } catch {
                        AppLogger.shared.error("LaunchAgent write failed: \(error.localizedDescription)")
                    }
                }
                launchAtLogin = false
                ToastHUD.shared.show("开启开机启动失败，请将应用移至「应用程序」文件夹后重试")
            }
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: Self.launchAgentPlistURL)
            launchAtLogin = false
            ToastHUD.shared.show("已关闭开机自动启动")
            AppLogger.shared.info("Disabled Launch at Login")
        }
    }

    private func save() {
        var encodedMap: [String: APIEndpointConfig] = [:]
        for (k, v) in apiConfigs {
            encodedMap[k.rawValue] = v
        }
        let persisted = PersistedSettings(
            showInDock: showInDock,
            showInMenuBar: showInMenuBar,
            enableTextSelectionPopup: enableTextSelectionPopup,
            useClipboardFallbackForSelection: useClipboardFallbackForSelection,
            useNativeVisionOCRFirst: useNativeVisionOCRFirst,
            screenshotHotkey: screenshotHotkey,
            translateSourceLang: translateSourceLang,
            translateTargetLang: translateTargetLang,
            logRetentionPeriod: logRetentionPeriod,
            logMaxLines: logMaxLines,
            githubRepo: githubRepo,
            capsuleActions: capsuleActions,
            apiConfigs: encodedMap
        )
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }
}

extension Notification.Name {
    static let luminaPresenceDidChange = Notification.Name("luminaPresenceDidChange")
    static let luminaHotkeyDidChange = Notification.Name("luminaHotkeyDidChange")
    static let luminaTriggerScreenshot = Notification.Name("luminaTriggerScreenshot")
    static let luminaOpenMainWindow = Notification.Name("luminaOpenMainWindow")
    static let luminaShowPermissionGuide = Notification.Name("luminaShowPermissionGuide")
}
