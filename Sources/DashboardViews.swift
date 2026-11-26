import SwiftUI
import AppKit
import Carbon

// MARK: - Navigation Tab

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "概览"
    case apiConfig = "API 配置"
    case selection = "划词"
    case screenshot = "截屏"
    case appearance = "外观权限"
    case logs = "日志"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .apiConfig: return "cpu"
        case .selection: return "text.cursor"
        case .screenshot: return "viewfinder"
        case .appearance: return "slider.horizontal.3"
        case .logs: return "doc.text.magnifyingglass"
        }
    }
}

// MARK: - Dashboard ViewModel (ObservableObject, ZERO @State)

final class DashboardViewModel: ObservableObject {
    @Published var selectedTab: DashboardTab = .overview
    @Published var metricMode: UsageMetricMode = .calls
    @Published var selectedDayIndex: Int = 6 // Today (last of 7 days)
    @Published var visibleFeatures: Set<FeatureKind> = Set(FeatureKind.allCases)

    // API Config Editor State
    @Published var editingFeature: FeatureKind = .translate
    @Published var showAPIKeyPlaintext: Bool = false
    @Published var copyIncludeModel: Bool = true
    @Published var copyIncludePricing: Bool = true
    @Published var copyIncludeThinking: Bool = true
    @Published var copyTargetFeature: FeatureKind = .explain
    @Published var copyFeedbackMessage: String = ""

    // Pricing Editor State on Overview
    @Published var pricingFeature: FeatureKind = .translate
    @Published var pricingInputText: String = "0.8"
    @Published var pricingOutputText: String = "2.0"
    @Published var pricingCurrency: String = "¥"

    // Hotkey Recorder State
    @Published var isRecordingHotkey: Bool = false
    @Published var recordingPreviewModifiers: String = ""
    private var hotkeyMonitor: Any?
    private var flagsMonitor: Any?

    init() {
        syncPricingFields(for: .translate)
    }

    func selectPricingFeature(_ feature: FeatureKind) {
        pricingFeature = feature
        syncPricingFields(for: feature)
    }

    func syncPricingFields(for feature: FeatureKind) {
        let cfg = SettingsStore.shared.config(for: feature)
        pricingInputText = String(format: "%.2f", cfg.inputPricePerMillion)
        pricingOutputText = String(format: "%.2f", cfg.outputPricePerMillion)
        pricingCurrency = cfg.currencySymbol
    }

    func savePricingFields() {
        let inVal = Double(pricingInputText.trimmingCharacters(in: .whitespaces)) ?? 0
        let outVal = Double(pricingOutputText.trimmingCharacters(in: .whitespaces)) ?? 0
        SettingsStore.shared.updatePricing(
            for: pricingFeature,
            inputPrice: inVal,
            outputPrice: outVal,
            currency: pricingCurrency
        )
        ToastHUD.shared.show("已更新「\(pricingFeature.shortName)」单价并重算费用")
    }

    func toggleFeatureInChart(_ feature: FeatureKind) {
        if visibleFeatures.contains(feature) {
            if visibleFeatures.count > 1 {
                visibleFeatures.remove(feature)
            }
        } else {
            visibleFeatures.insert(feature)
        }
    }

    func startHotkeyRecording() {
        stopHotkeyRecording()
        isRecordingHotkey = true
        recordingPreviewModifiers = ""

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            let mods = HotkeyConfig.carbonModifiers(from: event.modifierFlags)
            var parts: [String] = []
            if (mods & UInt32(controlKey)) != 0 { parts.append("⌃") }
            if (mods & UInt32(optionKey)) != 0 { parts.append("⌥") }
            if (mods & UInt32(shiftKey)) != 0 { parts.append("⇧") }
            if (mods & UInt32(cmdKey)) != 0 { parts.append("⌘") }
            self.recordingPreviewModifiers = parts.joined()
            return event
        }

        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 { // Esc cancels
                self.stopHotkeyRecording()
                return nil
            }
            // Allow ANY combination of 0, 1, 2, 3, or 4 modifiers + any key!
            let mods = HotkeyConfig.carbonModifiers(from: event.modifierFlags)
            let newHotkey = HotkeyConfig(keyCode: UInt32(event.keyCode), modifiers: mods)
            SettingsStore.shared.screenshotHotkey = newHotkey
            self.stopHotkeyRecording()
            ToastHUD.shared.show("截屏快捷键已更新为 \(newHotkey.displayString)")
            return nil
        }
    }

    func stopHotkeyRecording() {
        isRecordingHotkey = false
        recordingPreviewModifiers = ""
        if let m = hotkeyMonitor {
            NSEvent.removeMonitor(m)
            hotkeyMonitor = nil
        }
        if let f = flagsMonitor {
            NSEvent.removeMonitor(f)
            flagsMonitor = nil
        }
    }

    func greetingString() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "早上好，Lumina"
        case 12..<18: return "下午好，Lumina"
        default: return "晚上好，Lumina"
        }
    }

    func formattedTodayDate() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "EEEE, yyyy年M月d日"
        return df.string(from: Date())
    }
}

// MARK: - Main Dashboard Root View

struct MainDashboardView: View {
    @ObservedObject var vm: DashboardViewModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var usage: UsageStore
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var logger: AppLogger
    @ObservedObject var updater: UpdateManager

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebarView
                    .frame(width: 236)
                    .background(LuminaTheme.sidebarBg)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        topBarView
                        switch vm.selectedTab {
                        case .overview:
                            overviewContent
                        case .apiConfig:
                            apiConfigContent
                        case .selection:
                            selectionSettingsContent
                        case .screenshot:
                            screenshotSettingsContent
                        case .appearance:
                            appearanceAndPermissionContent
                        case .logs:
                            logsContent
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 36)
                }
                .background(LuminaTheme.canvasBg)
            }

            if permissions.showGuideModal {
                permissionGuideOverlay
            }

            if updater.showUpdateSheet {
                updateModalOverlay
            }
        }
        .frame(minWidth: 1020, minHeight: 680)
        .background(LuminaTheme.canvasBg)
    }

    // MARK: - Sidebar (ZIXO 2x3 Bento Nav + Quick Controls + Status Card)

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Wordmark header
            HStack {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LuminaTheme.activeTileGradient)
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: "sparkle")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(LuminaTheme.champagneLight)
                        )
                    Text("LUMINA")
                        .font(.system(size: 16, weight: .bold, design: .serif))
                        .tracking(1.5)
                        .foregroundColor(LuminaTheme.textPrimary)
                }
                Spacer()
                Circle()
                    .fill(permissions.allGranted ? LuminaTheme.emerald : LuminaTheme.coral)
                    .frame(width: 8, height: 8)
                    .help(permissions.allGranted ? "系统权限已就绪" : "缺少辅助功能或屏幕录制权限")
            }
            .padding(.top, 6)

            // 2x3 Navigation Bento Grid
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(DashboardTab.allCases) { tab in
                    let isSelected = (vm.selectedTab == tab)
                    Button(action: { vm.selectedTab = tab }) {
                        VStack(spacing: 7) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 15, weight: .medium))
                            Text(tab.rawValue)
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundColor(isSelected ? .white : LuminaTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 62)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isSelected ? LuminaTheme.activeTileGradient : LinearGradient(colors: [Color(hex: "#F6F6F7"), Color(hex: "#F6F6F7")], startPoint: .top, endPoint: .bottom))
                                .shadow(color: Color.black.opacity(isSelected ? 0.14 : 0.03), radius: 6, x: 0, y: 3)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Stacked Quick Controls (ZIXO Card Controls)
            VStack(alignment: .leading, spacing: 6) {
                Text("快捷操作")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(LuminaTheme.textSecondary)
                    .padding(.leading, 4)

                sidebarControlRow(icon: "camera.viewfinder", title: "立即截屏提问", badge: settings.screenshotHotkey.displayString) {
                    NotificationCenter.default.post(name: .luminaTriggerScreenshot, object: nil)
                }
                sidebarControlRow(icon: "text.bubble", title: "测试划词浮窗", badge: nil) {
                    FloatingPanelController.shared.showSelectionCapsule(
                        for: "LuminaAI 是一款原生轻量的 macOS 桌面 AI 助手，支持全局划词与多模态截屏提问。",
                        near: NSEvent.mouseLocation
                    )
                }
                sidebarControlRow(icon: "hand.raised", title: "检查系统权限", badge: permissions.allGranted ? "正常" : "待授权") {
                    permissions.refreshStatus()
                    permissions.showGuideModal = true
                }
                sidebarControlRow(icon: "folder", title: "打开日志目录", badge: nil) {
                    logger.revealInFinder()
                }
            }

            Spacer()

            // Bottom Champagne Status Card (ZIXO Pro Promo style)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("默认引擎")
                        .font(.system(size: 12, weight: .bold, design: .serif))
                        .foregroundColor(LuminaTheme.textPrimary)
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundColor(LuminaTheme.charcoalDark)
                }
                Text(settings.config(for: .translate).providerName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(LuminaTheme.textPrimary)
                Text("支持为每个划词/截屏功能独立接入不同模型与单价。")
                    .font(.system(size: 10.5))
                    .foregroundColor(LuminaTheme.textPrimary.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LuminaTheme.champagneGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.6), lineWidth: 1)
                    )
            )

            // Bottom-Left Version Badge & Check for Updates Button
            HStack(spacing: 8) {
                Text("v\(updater.currentVersion)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(LuminaTheme.textSecondary)
                Spacer()
                Button(action: { updater.checkForUpdates(silent: false) }) {
                    HStack(spacing: 4) {
                        if case .checking = updater.status {
                            ProgressView().scaleEffect(0.5).frame(width: 11, height: 11)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        Text("检查更新")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(LuminaTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.65)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
        .padding(18)
    }

    private func sidebarControlRow(icon: String, title: String, badge: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(LuminaTheme.textPrimary.opacity(0.75))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(LuminaTheme.textPrimary)
                Spacer()
                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(badge == "待授权" ? LuminaTheme.coral : LuminaTheme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.05)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.45)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Top Bar

    private var topBarView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.greetingString())
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                    .foregroundColor(LuminaTheme.textPrimary)
                Text(vm.formattedTodayDate())
                    .font(.system(size: 12))
                    .foregroundColor(LuminaTheme.textSecondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Button(action: {
                    NotificationCenter.default.post(name: .luminaTriggerScreenshot, object: nil)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 12, weight: .semibold))
                        Text("截屏提问 (\(settings.screenshotHotkey.displayString))")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(LuminaTheme.activeTileGradient))
                }
                .buttonStyle(.plain)

                Button(action: {
                    settings.enableTextSelectionPopup.toggle()
                    ToastHUD.shared.show(settings.enableTextSelectionPopup ? "已开启全局划词弹窗" : "已暂停全局划词弹窗")
                }) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(settings.enableTextSelectionPopup ? LuminaTheme.emerald : LuminaTheme.textTertiary)
                            .frame(width: 7, height: 7)
                        Text(settings.enableTextSelectionPopup ? "划词已开启" : "划词已关闭")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(LuminaTheme.textPrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(LuminaTheme.cardBg)
                            .overlay(Capsule().stroke(Color.white.opacity(0.8), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Overview Dashboard Content

    private var overviewContent: some View {
        let configuredCount = FeatureKind.allCases.filter { settings.config(for: $0).isConfigured }.count
        let totalCalls = usage.totalCallsLast7Days()
        let totalTokens = usage.totalTokensLast7Days()
        let totalCost = usage.totalCostLast7Days(settings: settings)
        let callSpark = usage.dailyTotalsLast7Days(mode: .calls, settings: settings)
        let tokSpark = usage.dailyTotalsLast7Days(mode: .tokens, settings: settings)
        let costSpark = usage.dailyTotalsLast7Days(mode: .cost, settings: settings)
        let currency = settings.config(for: .translate).currencySymbol

        let allSeries = usage.weeklySeriesByFeature(mode: vm.metricMode, settings: settings)
        let filteredSeries = allSeries.filter { vm.visibleFeatures.contains($0.feature) }
        let dayLabels = usage.last7Days().map { usage.dayLabel(for: $0) }

        return VStack(spacing: 16) {
            // 4-Column Frosted KPI Strip (ZIXO Signature)
            HStack(spacing: 0) {
                kpiColumn(
                    title: "近 7 天总调用",
                    valueView: AnyView(
                        Text("\(totalCalls)")
                            .font(.system(size: 24, weight: .semibold, design: .serif))
                            .foregroundColor(LuminaTheme.textPrimary)
                    ),
                    subtitle: "▲ 实时统计",
                    subtitleColor: LuminaTheme.emerald,
                    sparklineValues: callSpark,
                    sparkColor: LuminaTheme.charcoalDark
                )
                Divider().frame(height: 46).opacity(0.25)

                kpiColumn(
                    title: "近 7 天总 Token",
                    valueView: AnyView(
                        Text(formatCompactNumber(totalTokens))
                            .font(.system(size: 24, weight: .semibold, design: .serif))
                            .foregroundColor(LuminaTheme.textPrimary)
                    ),
                    subtitle: "输入 + 输出",
                    subtitleColor: LuminaTheme.textSecondary,
                    sparklineValues: tokSpark,
                    sparkColor: LuminaTheme.emerald
                )
                Divider().frame(height: 46).opacity(0.25)

                kpiColumn(
                    title: "预估总费用",
                    valueView: AnyView(
                        MutedDecimalText(prefix: currency, value: totalCost, fontSize: 24, decimals: 3)
                    ),
                    subtitle: "按手动单价计算",
                    subtitleColor: LuminaTheme.coral,
                    sparklineValues: costSpark,
                    sparkColor: LuminaTheme.coral
                )
                Divider().frame(height: 46).opacity(0.25)

                kpiColumn(
                    title: "已配置 API",
                    valueView: AnyView(
                        Text("\(configuredCount) / \(FeatureKind.allCases.count)")
                            .font(.system(size: 24, weight: .semibold, design: .serif))
                            .foregroundColor(LuminaTheme.textPrimary)
                    ),
                    subtitle: configuredCount > 0 ? "▲ 可独立路由" : "请前往 API 配置",
                    subtitleColor: configuredCount > 0 ? LuminaTheme.emerald : LuminaTheme.coral,
                    sparklineValues: [1, 2, 2, 3, 4, 5, Double(max(configuredCount, 1))],
                    sparkColor: Color(hex: "#C59B5F")
                )
            }
            .bentoCard(cornerRadius: 20, padding: 16)

            // Asymmetric 2-Column Bento Grid
            HStack(alignment: .top, spacing: 16) {
                // Left (~63%): 7-Day Multi-API Spline Curve Card
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("API 近一周使用量趋势")
                                .font(.system(size: 16, weight: .semibold, design: .serif))
                                .foregroundColor(LuminaTheme.textPrimary)
                            Text(vm.metricMode == .cost ? "按相对比例缩放曲线，清晰对比每日开销占比" : "点击下方日期或功能标签可切换对比曲线")
                                .font(.system(size: 11))
                                .foregroundColor(LuminaTheme.textSecondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)

                        // Metric switcher pill
                        HStack(spacing: 2) {
                            ForEach(UsageMetricMode.allCases) { mode in
                                Button(action: { vm.metricMode = mode }) {
                                    Text(mode.rawValue)
                                        .font(.system(size: 11, weight: .medium))
                                        .fixedSize(horizontal: true, vertical: false)
                                        .foregroundColor(vm.metricMode == mode ? .white : LuminaTheme.textSecondary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule().fill(vm.metricMode == mode ? LuminaTheme.charcoalDark : Color.clear)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(3)
                        .background(Capsule().fill(Color.black.opacity(0.05)))
                    }

                    MultiSeriesSplineChartView(
                        seriesList: filteredSeries,
                        dayLabels: dayLabels,
                        selectedDayIndex: vm.selectedDayIndex,
                        metricMode: vm.metricMode,
                        currencySymbol: currency,
                        onSelectDay: { idx in vm.selectedDayIndex = idx }
                    )

                    // Interactive feature legend pills
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(FeatureKind.allCases) { kind in
                                let active = vm.visibleFeatures.contains(kind)
                                Button(action: { vm.toggleFeatureInChart(kind) }) {
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(Color(hex: kind.chartColorHex))
                                            .frame(width: 7, height: 7)
                                            .opacity(active ? 1.0 : 0.3)
                                        Text(kind.shortName)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(active ? LuminaTheme.textPrimary : LuminaTheme.textTertiary)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule().fill(active ? Color.black.opacity(0.06) : Color.black.opacity(0.02))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .bentoCard(cornerRadius: 20, padding: 18)
                .frame(maxWidth: .infinity)

                // Right (~37%): Radial-Ticked Arc Gauge + Manual Pricing Input Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("单价与成本估算")
                            .font(.system(size: 16, weight: .semibold, design: .serif))
                            .foregroundColor(LuminaTheme.textPrimary)
                        Spacer()
                        Button(action: { vm.selectedTab = .apiConfig }) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(LuminaTheme.textPrimary)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.black.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }

                    RadialTickArcGauge(
                        progress: Double(configuredCount) / Double(FeatureKind.allCases.count),
                        centerTitle: "\(Int((Double(configuredCount) / Double(FeatureKind.allCases.count)) * 100))%",
                        centerSubtitle: "功能 API 已配置"
                    )

                    Divider().opacity(0.25)

                    // Manual Pricing Editor
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("手动单价 (/1M Tok)")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(LuminaTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { vm.pricingFeature },
                                set: { vm.selectPricingFeature($0) }
                            )) {
                                ForEach(FeatureKind.allCases) { f in
                                    Text(f.shortName).tag(f)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 88)
                        }

                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("输入价格")
                                    .font(.system(size: 10))
                                    .foregroundColor(LuminaTheme.textSecondary)
                                TextField("0.80", text: $vm.pricingInputText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("输出价格")
                                    .font(.system(size: 10))
                                    .foregroundColor(LuminaTheme.textSecondary)
                                TextField("2.00", text: $vm.pricingOutputText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("币种")
                                    .font(.system(size: 10))
                                    .foregroundColor(LuminaTheme.textSecondary)
                                TextField("¥", text: $vm.pricingCurrency)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                                    .frame(width: 46)
                            }
                        }

                        Button(action: { vm.savePricingFields() }) {
                            Text("应用单价并重算曲线")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(LuminaTheme.activeTileGradient))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .bentoCard(cornerRadius: 20, padding: 18)
                .frame(width: 300)
            }

            // Bottom Full-Width Card: Recent API Calls (ZIXO Transactions Style)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("最近调用记录")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundColor(LuminaTheme.textPrimary)
                    Spacer()
                    if !usage.records.isEmpty {
                        Button("清空记录") {
                            usage.clearHistory()
                        }
                        .font(.system(size: 11.5))
                        .foregroundColor(LuminaTheme.textSecondary)
                        .buttonStyle(.plain)
                    }
                }

                if usage.records.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 22))
                                .foregroundColor(LuminaTheme.textTertiary)
                            Text("暂无调用记录。选中文字或按下 \(settings.screenshotHotkey.displayString) 截屏即可开始使用。")
                                .font(.system(size: 12.5))
                                .foregroundColor(LuminaTheme.textSecondary)
                        }
                        .padding(.vertical, 22)
                        Spacer()
                    }
                } else {
                    ForEach(Array(usage.records.prefix(8))) { rec in
                        let dynCost = usage.dynamicCost(for: rec, settings: settings)
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: rec.feature.chartColorHex).opacity(0.14))
                                .frame(width: 34, height: 34)
                                .overlay(
                                    Image(systemName: rec.feature.symbolName)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(Color(hex: rec.feature.chartColorHex))
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(rec.feature.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(LuminaTheme.textPrimary)
                                Text("\(rec.modelName) • \(formatRecordTime(rec.timestamp))")
                                    .font(.system(size: 11))
                                    .foregroundColor(LuminaTheme.textSecondary)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                MutedDecimalText(
                                    prefix: settings.config(for: rec.feature).currencySymbol,
                                    value: dynCost,
                                    fontSize: 14,
                                    decimals: 4
                                )
                                Text(rec.success ? "▲ \(rec.totalTokens) tokens" : "▼ 调用失败")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(rec.success ? LuminaTheme.emerald : LuminaTheme.coral)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .bentoCard(cornerRadius: 20, padding: 18)
        }
    }

    private func kpiColumn(
        title: String,
        valueView: AnyView,
        subtitle: String,
        subtitleColor: Color,
        sparklineValues: [Double],
        sparkColor: Color
    ) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(LuminaTheme.textSecondary)
                valueView
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(subtitleColor)
            }
            Spacer(minLength: 4)
            MiniSparklineView(values: sparklineValues, strokeColor: sparkColor)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }

    // MARK: - API Configuration Content (Per-Feature + Copy to Other Features)

    private var apiConfigContent: some View {
        let currentCfg = settings.config(for: vm.editingFeature)

        return VStack(alignment: .leading, spacing: 16) {
            // Feature Selector Bar
            VStack(alignment: .leading, spacing: 10) {
                Text("选择要独立配置 API 的功能")
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundColor(LuminaTheme.textPrimary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(FeatureKind.allCases) { kind in
                            let selected = (vm.editingFeature == kind)
                            let configured = settings.config(for: kind).isConfigured
                            Button(action: { vm.editingFeature = kind }) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(configured ? LuminaTheme.emerald : LuminaTheme.textTertiary)
                                        .frame(width: 6, height: 6)
                                    Image(systemName: kind.symbolName)
                                        .font(.system(size: 11.5))
                                    Text(kind.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundColor(selected ? .white : LuminaTheme.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(selected ? LuminaTheme.activeTileGradient : LinearGradient(colors: [Color.black.opacity(0.05), Color.black.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .bentoCard()

            // Main API Form Card
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("\(vm.editingFeature.displayName) — 接口配置")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundColor(LuminaTheme.textPrimary)
                    Spacer()

                    // Quick provider presets
                    HStack(spacing: 6) {
                        presetChip("火山方舟/豆包") {
                            var cfg = settings.config(for: vm.editingFeature)
                            cfg.providerName = "火山方舟 · 豆包"
                            cfg.baseURL = "https://ark.cn-beijing.volces.com/api/v3"
                            cfg.modelName = vm.editingFeature.isVisionCapable ? "doubao-1-5-vision-pro-32k-250115" : "doubao-1-5-pro-32k-250115"
                            settings.updateConfig(cfg)
                        }
                        presetChip("OpenAI") {
                            var cfg = settings.config(for: vm.editingFeature)
                            cfg.providerName = "OpenAI"
                            cfg.baseURL = "https://api.openai.com/v1"
                            cfg.modelName = vm.editingFeature.isVisionCapable ? "gpt-4o" : "gpt-4o-mini"
                            settings.updateConfig(cfg)
                        }
                        presetChip("DeepSeek") {
                            var cfg = settings.config(for: vm.editingFeature)
                            cfg.providerName = "DeepSeek"
                            cfg.baseURL = "https://api.deepseek.com/v1"
                            cfg.modelName = "deepseek-chat"
                            settings.updateConfig(cfg)
                        }
                    }
                }

                HStack(spacing: 14) {
                    labeledField("服务商名称") {
                        TextField("如：火山方舟 · 豆包", text: configBinding(\.providerName))
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("模型名称 / Endpoint ID") {
                        TextField("如：doubao-1-5-pro-32k-250115", text: configBinding(\.modelName))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                labeledField("Base URL (OpenAI 兼容接口)") {
                    TextField("https://ark.cn-beijing.volces.com/api/v3", text: configBinding(\.baseURL))
                        .textFieldStyle(.roundedBorder)
                }

                labeledField("API Key") {
                    HStack {
                        if vm.showAPIKeyPlaintext {
                            TextField("sk-... 或火山方舟 API Key", text: configBinding(\.apiKey))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("sk-... 或火山方舟 API Key", text: configBinding(\.apiKey))
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(action: { vm.showAPIKeyPlaintext.toggle() }) {
                            Image(systemName: vm.showAPIKeyPlaintext ? "eye.slash" : "eye")
                                .foregroundColor(LuminaTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 14) {
                    labeledField("输入单价 (/ 1M Tokens)") {
                        TextField("0.8", value: configDoubleBinding(\.inputPricePerMillion), format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("输出单价 (/ 1M Tokens)") {
                        TextField("2.0", value: configDoubleBinding(\.outputPricePerMillion), format: .number)
                            .textFieldStyle(.roundedBorder)
                    }
                    labeledField("货币符号") {
                        TextField("¥", text: configBinding(\.currencySymbol))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                    }
                }

                // Thinking / Reasoning Options
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("开启深度思考（Thinking / Reasoning）", isOn: configBoolBinding(\.enableThinking))
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if currentCfg.enableThinking {
                            HStack(spacing: 4) {
                                Text("思考强度")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(LuminaTheme.textSecondary)
                                Picker("", selection: configThinkingEffortBinding()) {
                                    ForEach(ThinkingEffort.allCases) { effort in
                                        Text(effort.displayName).tag(effort)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 220)
                            }
                        }
                    }
                    Text("开启后将自动随请求发送 `reasoning_effort` 与火山方舟 `thinking: enabled` 参数，并在回复浮窗中流式展示可折叠的「深度思考过程」。")
                        .font(.system(size: 11))
                        .foregroundColor(LuminaTheme.textSecondary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.03))
                )

                // Preset System Prompt Editor + Reset
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("预设提示词 (System Prompt)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(LuminaTheme.textSecondary)
                        Spacer()
                        Button("恢复默认提示词") {
                            settings.resetSystemPrompt(for: vm.editingFeature)
                            ToastHUD.shared.show("已恢复「\(vm.editingFeature.shortName)」默认提示词")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(LuminaTheme.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.06)))
                        .buttonStyle(.plain)
                    }
                    TextEditor(text: configBinding(\.systemPrompt))
                        .font(.system(size: 12.5))
                        .frame(height: 82)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.1), lineWidth: 1))
                }
            }
            .bentoCard()

            // Copy API Config to Other Features Card
            VStack(alignment: .leading, spacing: 12) {
                Text("复制当前 API 信息到其他功能")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundColor(LuminaTheme.textPrimary)

                HStack(spacing: 16) {
                    Toggle("同时复制模型名称", isOn: $vm.copyIncludeModel)
                        .font(.system(size: 12))
                    Toggle("同时复制单价设置", isOn: $vm.copyIncludePricing)
                        .font(.system(size: 12))
                    Toggle("同时复制思考设置", isOn: $vm.copyIncludeThinking)
                        .font(.system(size: 12))
                }

                HStack(spacing: 10) {
                    Picker("复制到指定功能", selection: $vm.copyTargetFeature) {
                        ForEach(FeatureKind.allCases.filter { $0 != vm.editingFeature }) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    .frame(width: 240)

                    Button("复制到该功能") {
                        settings.copyAPIConfig(
                            from: vm.editingFeature,
                            to: [vm.copyTargetFeature],
                            includeModel: vm.copyIncludeModel,
                            includePricing: vm.copyIncludePricing,
                            includeThinking: vm.copyIncludeThinking
                        )
                        ToastHUD.shared.show("已将「\(vm.editingFeature.shortName)」API 复制到「\(vm.copyTargetFeature.shortName)」")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("复制到全部文本功能") {
                        let textFeatures: [FeatureKind] = [.translate, .explain, .summarize, .followUp]
                        settings.copyAPIConfig(
                            from: vm.editingFeature,
                            to: textFeatures,
                            includeModel: vm.copyIncludeModel,
                            includePricing: vm.copyIncludePricing,
                            includeThinking: vm.copyIncludeThinking
                        )
                        ToastHUD.shared.show("已应用到全部划词文本功能")
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        settings.copyAPIConfig(
                            from: vm.editingFeature,
                            to: FeatureKind.allCases,
                            includeModel: vm.copyIncludeModel,
                            includePricing: vm.copyIncludePricing,
                            includeThinking: vm.copyIncludeThinking
                        )
                        ToastHUD.shared.show("已将当前 API 配置复制到全部 7 个功能")
                    }) {
                        Text("一键应用到全部功能")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(LuminaTheme.activeTileGradient))
                    }
                    .buttonStyle(.plain)
                }

                if currentCfg.apiKey.isEmpty {
                    Text("提示：当前功能的 API Key 为空，填写后再复制会更省事。")
                        .font(.system(size: 11))
                        .foregroundColor(LuminaTheme.textSecondary)
                }
            }
            .bentoCard()
        }
    }

    // MARK: - Selection Settings Content

    private var selectionSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("全局划词弹窗设置")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundColor(LuminaTheme.textPrimary)

                Toggle("启用全局划词悬浮胶囊（选中文字后在鼠标附近弹出翻译/解释/总结/追问）", isOn: $settings.enableTextSelectionPopup)
                    .font(.system(size: 13))

                Toggle("启用兼容兜底模式（在浏览器/Electron 应用中无障碍无法直接读取选区时，自动无痕借用 ⌘C 并还原剪贴板）", isOn: $settings.useClipboardFallbackForSelection)
                    .font(.system(size: 13))

                Divider().opacity(0.25)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("划词弹窗实时预览")
                            .font(.system(size: 13, weight: .medium))
                        Text("点击右侧按钮可在当前鼠标位置弹出悬浮胶囊，体验流式回复浮窗。")
                            .font(.system(size: 11.5))
                            .foregroundColor(LuminaTheme.textSecondary)
                    }
                    Spacer()
                    Button(action: {
                        FloatingPanelController.shared.showSelectionCapsule(
                            for: "Artificial Intelligence is transforming personal productivity on macOS.",
                            near: NSEvent.mouseLocation
                        )
                    }) {
                        Text("立即预览划词胶囊")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(LuminaTheme.activeTileGradient))
                    }
                    .buttonStyle(.plain)
                }
            }
            .bentoCard()

            // Capsule Items Order & Visibility Customization Card
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("划词胶囊选项自定义（显示与排序）")
                            .font(.system(size: 16, weight: .semibold, design: .serif))
                            .foregroundColor(LuminaTheme.textPrimary)
                        Text("自由勾选需要放入悬浮胶囊的功能，并使用上下箭头调整显示顺序。")
                            .font(.system(size: 11.5))
                            .foregroundColor(LuminaTheme.textSecondary)
                    }
                    Spacer()
                    Button("恢复默认") {
                        settings.resetCapsuleActions()
                        ToastHUD.shared.show("已恢复默认胶囊顺序")
                    }
                    .buttonStyle(.bordered)
                }

                // Live Capsule Preview
                HStack {
                    Text("实时预览：")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(LuminaTheme.textSecondary)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(LuminaTheme.activeTileGradient)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Image(systemName: "sparkle")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(LuminaTheme.champagneLight)
                            )
                        ForEach(settings.enabledCapsuleActions) { item in
                            HStack(spacing: 4) {
                                Image(systemName: item.symbolName)
                                    .font(.system(size: 10.5))
                                Text(item.shortName)
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundColor(LuminaTheme.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.05)))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 3)
                    )
                    Spacer()
                }
                .padding(.vertical, 4)

                // Reorderable Toggle Rows
                VStack(spacing: 8) {
                    ForEach(Array(settings.capsuleActions.enumerated()), id: \.element.id) { idx, item in
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { item.isEnabled },
                                set: { settings.toggleCapsuleAction(item.action, enabled: $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)

                            Image(systemName: item.action.symbolName)
                                .font(.system(size: 13))
                                .foregroundColor(item.isEnabled ? LuminaTheme.textPrimary : LuminaTheme.textTertiary)
                                .frame(width: 20)

                            Text(item.action.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(item.isEnabled ? LuminaTheme.textPrimary : LuminaTheme.textSecondary)

                            Spacer()

                            HStack(spacing: 4) {
                                Button(action: { settings.moveCapsuleAction(at: idx, offset: -1) }) {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(idx == 0 ? LuminaTheme.textTertiary : LuminaTheme.textPrimary)
                                        .frame(width: 26, height: 24)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.05)))
                                }
                                .buttonStyle(.plain)
                                .disabled(idx == 0)

                                Button(action: { settings.moveCapsuleAction(at: idx, offset: 1) }) {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(idx == settings.capsuleActions.count - 1 ? LuminaTheme.textTertiary : LuminaTheme.textPrimary)
                                        .frame(width: 26, height: 24)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.05)))
                                }
                                .buttonStyle(.plain)
                                .disabled(idx == settings.capsuleActions.count - 1)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(Color.white.opacity(0.75))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.black.opacity(0.05), lineWidth: 1))
                        )
                    }
                }
            }
            .bentoCard()
        }
    }

    // MARK: - Screenshot Settings Content

    private var screenshotSettingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Text("全局快捷键截屏提问")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundColor(LuminaTheme.textPrimary)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("截屏框选快捷键")
                            .font(.system(size: 13, weight: .medium))
                        Text("点击录制后，可自由按下任意单键（如 F1–F12）或任意多键组合（如 ⌘⌥⇧A、⌃⌥S 等）。")
                            .font(.system(size: 11.5))
                            .foregroundColor(LuminaTheme.textSecondary)
                    }
                    Spacer()

                    let recText = vm.recordingPreviewModifiers.isEmpty
                        ? "请按下快捷键 (ESC 取消)..."
                        : "\(vm.recordingPreviewModifiers) + ..."
                    Text(vm.isRecordingHotkey ? recText : settings.screenshotHotkey.displayString)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(vm.isRecordingHotkey ? LuminaTheme.coral : LuminaTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(vm.isRecordingHotkey ? LuminaTheme.coral : Color.black.opacity(0.1), lineWidth: 1))
                        )

                    Button(action: {
                        if vm.isRecordingHotkey {
                            vm.stopHotkeyRecording()
                        } else {
                            vm.startHotkeyRecording()
                        }
                    }) {
                        Text(vm.isRecordingHotkey ? "取消" : "修改快捷键")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(LuminaTheme.activeTileGradient))
                    }
                    .buttonStyle(.plain)
                }

                Divider().opacity(0.25)

                Toggle("提取文字（OCR）时优先使用 macOS 本机 Vision 离线高精度识别（速度更快且零费用，未识别到文字时自动回退到多模态 AI）", isOn: $settings.useNativeVisionOCRFirst)
                    .font(.system(size: 13))

                HStack {
                    Text("框选截屏包含暗角遮罩、呼吸准星指针、L 型角标及悬浮工具条（复制 / OCR / AI 翻译 / AI 提问）。")
                        .font(.system(size: 11.5))
                        .foregroundColor(LuminaTheme.textSecondary)
                    Spacer()
                    Button("立即体验截屏") {
                        NotificationCenter.default.post(name: .luminaTriggerScreenshot, object: nil)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .bentoCard()
        }
    }

    // MARK: - Appearance & Permissions Content

    private var appearanceAndPermissionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Presence card
            VStack(alignment: .leading, spacing: 12) {
                Text("图标显示位置（Dock 栏 / 顶部菜单栏）")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundColor(LuminaTheme.textPrimary)

                Toggle("在 Dock 栏显示应用图标", isOn: Binding(
                    get: { settings.showInDock },
                    set: { settings.applyPresenceChange(dock: $0, menuBar: settings.showInMenuBar) }
                ))
                .font(.system(size: 13))

                Toggle("在顶部菜单栏显示常驻图标", isOn: Binding(
                    get: { settings.showInMenuBar },
                    set: { settings.applyPresenceChange(dock: settings.showInDock, menuBar: $0) }
                ))
                .font(.system(size: 13))

                Toggle("开机自动启动（登录 macOS 时自动在后台运行）", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                .font(.system(size: 13))

                Text("提示：为避免应用无法唤出，Dock 与菜单栏至少会保留一个入口。")
                    .font(.system(size: 11.5))
                    .foregroundColor(LuminaTheme.textSecondary)

                Divider().opacity(0.25)

                VStack(alignment: .leading, spacing: 6) {
                    Text("GitHub 自动更新仓库（格式：用户名/仓库名）")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(LuminaTheme.textPrimary)
                    HStack(spacing: 8) {
                        TextField("例如：yourname/LuminaAI", text: $settings.githubRepo)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                        Button("检查更新") {
                            updater.checkForUpdates(silent: false)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("自动更新下载新版后会自动使用本机持久化签名证书重签，保留辅助功能与屏幕录制授权，无需重新授权。")
                        .font(.system(size: 11))
                        .foregroundColor(LuminaTheme.textSecondary)
                }
            }
            .bentoCard()

            // Permissions card
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("macOS 系统权限状态")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundColor(LuminaTheme.textPrimary)
                    Spacer()
                    Button("重新检测") {
                        permissions.refreshStatus()
                    }
                    .buttonStyle(.bordered)
                }

                permissionRow(
                    title: "辅助功能（Accessibility）",
                    desc: "用于全局监听鼠标划词选区并弹出悬浮操作胶囊。",
                    granted: permissions.hasAccessibility,
                    onRequest: { permissions.requestAccessibilityPrompt() },
                    onOpenSettings: { permissions.openAccessibilitySettings() }
                )

                Divider().opacity(0.25)

                permissionRow(
                    title: "屏幕录制（Screen Recording）",
                    desc: "用于快捷键框选截屏、本机 OCR 提取文字及多模态 AI 识图。",
                    granted: permissions.hasScreenRecording,
                    onRequest: { permissions.requestScreenRecordingPrompt() },
                    onOpenSettings: { permissions.openScreenRecordingSettings() }
                )
            }
            .bentoCard()
        }
    }

    private func permissionRow(
        title: String,
        desc: String,
        granted: Bool,
        onRequest: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(granted ? LuminaTheme.emerald.opacity(0.15) : LuminaTheme.coral.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundColor(granted ? LuminaTheme.emerald : LuminaTheme.coral)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(LuminaTheme.textPrimary)
                    Text(granted ? "已授权" : "未授权")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(granted ? LuminaTheme.emerald : LuminaTheme.coral)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((granted ? LuminaTheme.emerald : LuminaTheme.coral).opacity(0.12)))
                }
                Text(desc)
                    .font(.system(size: 11.5))
                    .foregroundColor(LuminaTheme.textSecondary)
            }

            Spacer()

            if !granted {
                Button("请求弹窗", action: onRequest)
                    .buttonStyle(.bordered)
                Button(action: onOpenSettings) {
                    Text("前往系统设置")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(LuminaTheme.activeTileGradient))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Background Logs Content (With Retention & Line Cap)

    private var logsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("后台运行与错误日志")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundColor(LuminaTheme.textPrimary)
                    Text("\(logger.logFileURL.path)  （当前 \(logger.currentLineCount) 行）")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(LuminaTheme.textSecondary)
                }
                Spacer()
                Button("立即清理过期") {
                    logger.pruneNow()
                    ToastHUD.shared.show("已按保留策略清理日志")
                }
                .buttonStyle(.bordered)
                Button("刷新") { logger.reloadRecentLogs() }
                    .buttonStyle(.bordered)
                Button("清空") { logger.clearLogs() }
                    .buttonStyle(.bordered)
                Button(action: { logger.revealInFinder() }) {
                    Text("在 Finder 中查看")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(LuminaTheme.activeTileGradient))
                }
                .buttonStyle(.plain)
            }

            // Retention & Max Lines Controls
            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    Text("日志保留时长")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(LuminaTheme.textSecondary)
                    Picker("", selection: $settings.logRetentionPeriod) {
                        ForEach(LogRetentionPeriod.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                }

                HStack(spacing: 6) {
                    Text("最大保存行数")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(LuminaTheme.textSecondary)
                    Picker("", selection: $settings.logMaxLines) {
                        Text("200 行").tag(200)
                        Text("500 行").tag(500)
                        Text("2000 行").tag(2000)
                        Text("5000 行").tag(5000)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }

                Spacer()
                Text("已启用 3 秒去重与写入限流，防止异常死循环刷爆磁盘")
                    .font(.system(size: 11))
                    .foregroundColor(LuminaTheme.textSecondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.03)))

            ScrollView {
                Text(logger.recentLogText.isEmpty ? "暂无日志记录。" : logger.recentLogText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(LuminaTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(height: 330)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.08), lineWidth: 1))
            )
        }
        .bentoCard()
    }

    // MARK: - GitHub Update Modal Overlay

    private var updateModalOverlay: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { updater.showUpdateSheet = false }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("软件更新")
                        .font(.system(size: 18, weight: .semibold, design: .serif))
                        .foregroundColor(LuminaTheme.textPrimary)
                    Spacer()
                    Button(action: { updater.showUpdateSheet = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(LuminaTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.black.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }

                switch updater.status {
                case .available(let ver, let notes, let url):
                    Text("发现新版本 v\(ver)（当前 v\(updater.currentVersion)）")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(LuminaTheme.emerald)
                    ScrollView {
                        Text(notes)
                            .font(.system(size: 12.5))
                            .foregroundColor(LuminaTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 110)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.85)))

                    HStack {
                        Spacer()
                        Button("稍后") { updater.showUpdateSheet = false }
                            .buttonStyle(.bordered)
                        Button(action: { updater.downloadAndInstall(from: url) }) {
                            Text("立即更新并重启（免重新授权）")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(LuminaTheme.activeTileGradient))
                        }
                        .buttonStyle(.plain)
                    }

                case .downloading:
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.75)
                        Text("正在从 GitHub 下载更新包...")
                            .font(.system(size: 13))
                    }
                    .padding(.vertical, 14)

                case .installing:
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.75)
                        Text("正在本地重签名（保留系统权限）并准备重启...")
                            .font(.system(size: 13))
                    }
                    .padding(.vertical, 14)

                case .error(let msg):
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundColor(LuminaTheme.coral)
                    HStack {
                        Spacer()
                        Button("关闭") { updater.showUpdateSheet = false }
                            .buttonStyle(.bordered)
                    }

                default:
                    Text("当前已是最新版本 v\(updater.currentVersion)。")
                        .font(.system(size: 13))
                        .foregroundColor(LuminaTheme.textSecondary)
                }
            }
            .padding(22)
            .frame(width: 460)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LuminaTheme.cardBg)
                    .shadow(color: Color.black.opacity(0.24), radius: 24, x: 0, y: 12)
            )
        }
    }

    // MARK: - Permission Guide Modal Overlay

    private var permissionGuideOverlay: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { permissions.showGuideModal = false }

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("需要授予系统权限")
                            .font(.system(size: 18, weight: .semibold, design: .serif))
                            .foregroundColor(LuminaTheme.textPrimary)
                        Text("为了使用全局划词与快捷键截屏提问，请在系统设置中勾选 LuminaAI。")
                            .font(.system(size: 12))
                            .foregroundColor(LuminaTheme.textSecondary)
                    }
                    Spacer()
                    Button(action: { permissions.showGuideModal = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(LuminaTheme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.black.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }

                permissionRow(
                    title: "辅助功能",
                    desc: "全局划词选区读取必需权限",
                    granted: permissions.hasAccessibility,
                    onRequest: { permissions.requestAccessibilityPrompt() },
                    onOpenSettings: { permissions.openAccessibilitySettings() }
                )

                permissionRow(
                    title: "屏幕录制",
                    desc: "框选截屏与视觉 AI 提问必需权限",
                    granted: permissions.hasScreenRecording,
                    onRequest: { permissions.requestScreenRecordingPrompt() },
                    onOpenSettings: { permissions.openScreenRecordingSettings() }
                )

                HStack {
                    Button("重新检测状态") {
                        permissions.refreshStatus()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button(action: { permissions.showGuideModal = false }) {
                        Text(permissions.allGranted ? "全部就绪，开始使用" : "稍后设置")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(LuminaTheme.activeTileGradient))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
            .frame(width: 520)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LuminaTheme.cardBg)
                    .shadow(color: Color.black.opacity(0.24), radius: 24, x: 0, y: 12)
            )
        }
    }

    // MARK: - Helpers

    private func presetChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(LuminaTheme.textPrimary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(LuminaTheme.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func configBinding(_ keyPath: WritableKeyPath<APIEndpointConfig, String>) -> Binding<String> {
        Binding(
            get: { settings.config(for: vm.editingFeature)[keyPath: keyPath] },
            set: { newVal in
                var cfg = settings.config(for: vm.editingFeature)
                cfg[keyPath: keyPath] = newVal
                settings.updateConfig(cfg)
            }
        )
    }

    private func configDoubleBinding(_ keyPath: WritableKeyPath<APIEndpointConfig, Double>) -> Binding<Double> {
        Binding(
            get: { settings.config(for: vm.editingFeature)[keyPath: keyPath] },
            set: { newVal in
                var cfg = settings.config(for: vm.editingFeature)
                cfg[keyPath: keyPath] = max(0, newVal)
                settings.updateConfig(cfg)
            }
        )
    }

    private func configBoolBinding(_ keyPath: WritableKeyPath<APIEndpointConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.config(for: vm.editingFeature)[keyPath: keyPath] },
            set: { newVal in
                var cfg = settings.config(for: vm.editingFeature)
                cfg[keyPath: keyPath] = newVal
                settings.updateConfig(cfg)
            }
        )
    }

    private func configThinkingEffortBinding() -> Binding<ThinkingEffort> {
        Binding(
            get: { settings.config(for: vm.editingFeature).thinkingEffort },
            set: { newVal in
                var cfg = settings.config(for: vm.editingFeature)
                cfg.thinkingEffort = newVal
                settings.updateConfig(cfg)
            }
        )
    }

    private func formatCompactNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000.0) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000.0) }
        return "\(n)"
    }

    private func formatRecordTime(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: date)
    }
}
