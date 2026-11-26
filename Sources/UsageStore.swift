import Foundation

enum UsageMetricMode: String, CaseIterable, Identifiable {
    case calls = "调用次数"
    case tokens = "Token 数"
    case cost = "预估费用"

    var id: String { rawValue }
}

struct DailySeriesPoint: Identifiable {
    let id = UUID()
    let date: Date
    let dayLabel: String
    let value: Double
}

struct FeatureWeeklySeries: Identifiable {
    var id: String { feature.rawValue }
    let feature: FeatureKind
    let label: String
    let colorHex: String
    let points: [DailySeriesPoint]
    var totalValue: Double { points.reduce(0) { $0 + $1.value } }
}

final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published var records: [UsageRecord] = []

    private let storeURL: URL
    private let calendar = Calendar.current
    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M/d"
        return df
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LuminaAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("usage_records.json")
        load()
    }

    func recordUsage(
        feature: FeatureKind,
        config: APIEndpointConfig,
        inputTokens: Int,
        outputTokens: Int,
        success: Bool,
        previewText: String
    ) {
        let cost = Self.calculateCost(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            inputPricePerMillion: config.inputPricePerMillion,
            outputPricePerMillion: config.outputPricePerMillion
        )
        let record = UsageRecord(
            id: UUID(),
            timestamp: Date(),
            feature: feature,
            providerName: config.providerName,
            modelName: config.modelName,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCost: cost,
            currencySymbol: config.currencySymbol,
            success: success,
            previewText: String(previewText.prefix(80))
        )
        DispatchQueue.main.async {
            self.records.insert(record, at: 0)
            // Keep last 90 days max
            let cutoff = self.calendar.date(byAdding: .day, value: -90, to: Date()) ?? Date()
            self.records = self.records.filter { $0.timestamp >= cutoff }
            self.save()
        }
    }

    /// Dynamically recalculate cost using current manual pricing in SettingsStore
    func dynamicCost(for record: UsageRecord, settings: SettingsStore = .shared) -> Double {
        let cfg = settings.config(for: record.feature)
        return Self.calculateCost(
            inputTokens: record.inputTokens,
            outputTokens: record.outputTokens,
            inputPricePerMillion: cfg.inputPricePerMillion,
            outputPricePerMillion: cfg.outputPricePerMillion
        )
    }

    static func calculateCost(
        inputTokens: Int,
        outputTokens: Int,
        inputPricePerMillion: Double,
        outputPricePerMillion: Double
    ) -> Double {
        let inCost = (Double(inputTokens) / 1_000_000.0) * inputPricePerMillion
        let outCost = (Double(outputTokens) / 1_000_000.0) * outputPricePerMillion
        return inCost + outCost
    }

    /// Returns the last 7 calendar days (oldest to newest, ending today)
    func last7Days() -> [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
        }
    }

    func dayLabel(for date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    func recordsInLast7Days() -> [UsageRecord] {
        guard let start = last7Days().first else { return [] }
        return records.filter { $0.timestamp >= start }
    }

    func totalCallsLast7Days() -> Int {
        recordsInLast7Days().count
    }

    func totalTokensLast7Days() -> Int {
        recordsInLast7Days().reduce(0) { $0 + $1.totalTokens }
    }

    func totalCostLast7Days(settings: SettingsStore = .shared) -> Double {
        recordsInLast7Days().reduce(0.0) { $0 + dynamicCost(for: $1, settings: settings) }
    }

    func dailyTotalsLast7Days(mode: UsageMetricMode, settings: SettingsStore = .shared) -> [Double] {
        let days = last7Days()
        return days.map { day in
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
            let dayRecords = records.filter { $0.timestamp >= day && $0.timestamp < nextDay }
            switch mode {
            case .calls:
                return Double(dayRecords.count)
            case .tokens:
                return Double(dayRecords.reduce(0) { $0 + $1.totalTokens })
            case .cost:
                return dayRecords.reduce(0.0) { $0 + dynamicCost(for: $1, settings: settings) }
            }
        }
    }

    func weeklySeriesByFeature(mode: UsageMetricMode, settings: SettingsStore = .shared) -> [FeatureWeeklySeries] {
        let days = last7Days()
        var result: [FeatureWeeklySeries] = []
        for feature in FeatureKind.allCases {
            let points: [DailySeriesPoint] = days.map { day in
                let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
                let matching = records.filter {
                    $0.feature == feature && $0.timestamp >= day && $0.timestamp < nextDay
                }
                let val: Double
                switch mode {
                case .calls:
                    val = Double(matching.count)
                case .tokens:
                    val = Double(matching.reduce(0) { $0 + $1.totalTokens })
                case .cost:
                    val = matching.reduce(0.0) { $0 + dynamicCost(for: $1, settings: settings) }
                }
                return DailySeriesPoint(date: day, dayLabel: dayLabel(for: day), value: val)
            }
            result.append(FeatureWeeklySeries(
                feature: feature,
                label: feature.displayName,
                colorHex: feature.chartColorHex,
                points: points
            ))
        }
        return result
    }

    func clearHistory() {
        records = []
        save()
    }

    private func load() {
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([UsageRecord].self, from: data) {
            self.records = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
