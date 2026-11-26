import SwiftUI

// MARK: - Editorial Light Palette (ZIXO-inspired)

enum LuminaTheme {
    static let canvasBg = Color(hex: "#F3F3F4")
    static let sidebarBg = Color(hex: "#E9EAEB")
    static let cardBg = Color(hex: "#F8F8F9")
    static let cardSubtleBg = Color(hex: "#EFEFF1")
    static let charcoalDark = Color(hex: "#222326")
    static let charcoalMid = Color(hex: "#38393D")
    static let textPrimary = Color(hex: "#1D1E20")
    static let textSecondary = Color(hex: "#8E9095")
    static let textTertiary = Color(hex: "#9A9CA1")
    static let emerald = Color(hex: "#34A853")
    static let coral = Color(hex: "#D9534F")
    static let champagneLight = Color(hex: "#EAE2CE")
    static let champagneMid = Color(hex: "#D7CBB3")
    static let trackGray = Color(hex: "#D8D9DC")

    static let activeTileGradient = LinearGradient(
        colors: [Color(hex: "#252629"), Color(hex: "#3B3C40")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let champagneGradient = LinearGradient(
        colors: [Color(hex: "#ECE5D4"), Color(hex: "#D9CEB8")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Bento Card Modifier

struct BentoCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 18
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LuminaTheme.cardBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.82), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.045), radius: 12, x: 0, y: 4)
            )
    }
}

extension View {
    func bentoCard(cornerRadius: CGFloat = 18, padding: CGFloat = 18) -> some View {
        modifier(BentoCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - Muted Decimal Currency Text (ZIXO Signature Detail)

struct MutedDecimalText: View {
    let prefix: String
    let value: Double
    let fontSize: CGFloat
    let decimals: Int

    init(prefix: String = "¥", value: Double, fontSize: CGFloat = 24, decimals: Int = 2) {
        self.prefix = prefix
        self.value = value
        self.fontSize = fontSize
        self.decimals = decimals
    }

    var body: some View {
        let formatted = String(format: "%.\(decimals)f", value)
        let parts = formatted.split(separator: ".", maxSplits: 1)
        let intPart = parts.first.map(String.init) ?? "0"
        let decPart = parts.count > 1 ? ".\(parts[1])" : ""

        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(prefix)\(intPart)")
                .font(.system(size: fontSize, weight: .semibold, design: .serif))
                .foregroundColor(LuminaTheme.textPrimary)
            if !decPart.isEmpty {
                Text(decPart)
                    .font(.system(size: fontSize * 0.82, weight: .regular, design: .serif))
                    .foregroundColor(LuminaTheme.textTertiary)
            }
        }
    }
}

// MARK: - Mini Sparkline View

struct MiniSparklineView: View {
    let values: [Double]
    let strokeColor: Color

    var body: some View {
        GeometryReader { geo in
            let maxVal = max(values.max() ?? 1, 0.0001)
            let minVal = values.min() ?? 0
            let span = max(maxVal - minVal, 0.0001)
            let stepX = values.count > 1 ? geo.size.width / CGFloat(values.count - 1) : geo.size.width

            Path { path in
                guard !values.isEmpty else { return }
                let pts: [CGPoint] = values.enumerated().map { idx, val in
                    let x = CGFloat(idx) * stepX
                    let norm = (val - minVal) / span
                    let y = geo.size.height - CGFloat(norm) * (geo.size.height * 0.78) - geo.size.height * 0.11
                    return CGPoint(x: x, y: y)
                }
                path.move(to: pts[0])
                for i in 1..<pts.count {
                    let prev = pts[i - 1]
                    let curr = pts[i]
                    let midX = (prev.x + curr.x) / 2
                    path.addCurve(to: curr, control1: CGPoint(x: midX, y: prev.y), control2: CGPoint(x: midX, y: curr.y))
                }
            }
            .stroke(strokeColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 48, height: 22)
    }
}

// MARK: - Smooth Multi-Series Spline Chart (7-Day API Usage, Relative Proportional Scale)

struct MultiSeriesSplineChartView: View {
    let seriesList: [FeatureWeeklySeries]
    let dayLabels: [String]
    let selectedDayIndex: Int
    let metricMode: UsageMetricMode
    let currencySymbol: String
    let onSelectDay: (Int) -> Void

    /// Dynamic relative scale: peak value fills ~85% height even for tiny ¥0.001 costs!
    private var globalMax: Double {
        let rawMax = seriesList.flatMap { $0.points.map(\.value) }.max() ?? 0
        if rawMax <= 0 {
            return 1.0
        }
        return rawMax * 1.15
    }

    private var weekGrandTotal: Double {
        seriesList.reduce(0.0) { $0 + $1.totalValue }
    }

    private var selectedDayTotal: Double {
        guard selectedDayIndex >= 0 && selectedDayIndex < dayLabels.count else { return 0 }
        return seriesList.reduce(0.0) { acc, s in
            acc + (selectedDayIndex < s.points.count ? s.points[selectedDayIndex].value : 0)
        }
    }

    private func formatTooltipValue(_ val: Double) -> String {
        switch metricMode {
        case .calls:
            return "\(Int(val)) 次"
        case .tokens:
            if val >= 1000 {
                return String(format: "%.1fK tok", val / 1000.0)
            }
            return "\(Int(val)) tok"
        case .cost:
            let pct = weekGrandTotal > 0 ? (val / weekGrandTotal) * 100.0 : 0.0
            return String(format: "占比 %.1f%% · %@%.4f", pct, currencySymbol, val)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let sideInset: CGFloat = 14
                let width = max(geo.size.width - sideInset * 2, 40)
                let height = geo.size.height
                let topPad: CGFloat = 36
                let bottomPad: CGFloat = 12
                let plotHeight = max(height - topPad - bottomPad, 40)
                let count = max(dayLabels.count, 2)
                let stepX = width / CGFloat(count - 1)
                let activeX = sideInset + CGFloat(min(max(selectedDayIndex, 0), count - 1)) * stepX

                ZStack(alignment: .topLeading) {
                    // Subtle baseline
                    Path { p in
                        p.move(to: CGPoint(x: sideInset, y: height - bottomPad))
                        p.addLine(to: CGPoint(x: sideInset + width, y: height - bottomPad))
                    }
                    .stroke(Color.black.opacity(0.07), lineWidth: 1)

                    // Subtle vertical indicator pin for selected day
                    Path { p in
                        p.move(to: CGPoint(x: activeX, y: topPad - 4))
                        p.addLine(to: CGPoint(x: activeX, y: height - bottomPad))
                    }
                    .stroke(LuminaTheme.charcoalDark.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    // Draw each API series smooth Bezier spline
                    ForEach(seriesList) { series in
                        let pts: [CGPoint] = series.points.enumerated().map { idx, pt in
                            let x = sideInset + CGFloat(idx) * stepX
                            let norm = pt.value / globalMax
                            let y = topPad + plotHeight * (1.0 - CGFloat(norm))
                            return CGPoint(x: x, y: y)
                        }

                        if series.totalValue > 0 && pts.count >= 2 {
                            Path { path in
                                path.move(to: CGPoint(x: pts[0].x, y: height - bottomPad))
                                path.addLine(to: pts[0])
                                for i in 1..<pts.count {
                                    let prev = pts[i - 1]
                                    let curr = pts[i]
                                    let midX = (prev.x + curr.x) / 2
                                    path.addCurve(to: curr, control1: CGPoint(x: midX, y: prev.y), control2: CGPoint(x: midX, y: curr.y))
                                }
                                path.addLine(to: CGPoint(x: pts.last!.x, y: height - bottomPad))
                                path.closeSubpath()
                            }
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: series.colorHex).opacity(0.12), Color(hex: series.colorHex).opacity(0.0)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        }

                        Path { path in
                            guard pts.count >= 2 else { return }
                            path.move(to: pts[0])
                            for i in 1..<pts.count {
                                let prev = pts[i - 1]
                                let curr = pts[i]
                                let midX = (prev.x + curr.x) / 2
                                path.addCurve(to: curr, control1: CGPoint(x: midX, y: prev.y), control2: CGPoint(x: midX, y: curr.y))
                            }
                        }
                        .stroke(
                            Color(hex: series.colorHex).opacity(series.totalValue > 0 ? 0.92 : 0.22),
                            style: StrokeStyle(lineWidth: series.totalValue > 0 ? 2.2 : 1.0, lineCap: .round, lineJoin: .round)
                        )

                        if selectedDayIndex < pts.count && series.points[selectedDayIndex].value > 0 {
                            let pt = pts[selectedDayIndex]
                            Circle()
                                .fill(Color.white)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color(hex: series.colorHex), lineWidth: 2))
                                .position(pt)
                        }
                    }

                    // Floating dark charcoal capsule tooltip
                    let tipHalfWidth: CGFloat = metricMode == .cost ? 76 : 44
                    let clampedTipX = min(max(activeX, tipHalfWidth), geo.size.width - tipHalfWidth)
                    Text(formatTooltipValue(selectedDayTotal))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(LuminaTheme.charcoalDark))
                        .shadow(color: Color.black.opacity(0.16), radius: 6, x: 0, y: 3)
                        .position(x: clampedTipX, y: 14)

                    // Tap columns to select any day
                    HStack(spacing: 0) {
                        ForEach(0..<dayLabels.count, id: \.self) { idx in
                            Rectangle()
                                .fill(Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelectDay(idx)
                                }
                        }
                    }
                }
            }
            .frame(height: 185)

            HStack {
                ForEach(Array(dayLabels.enumerated()), id: \.offset) { idx, label in
                    Button(action: { onSelectDay(idx) }) {
                        Text(label)
                            .font(.system(size: 11, weight: idx == selectedDayIndex ? .bold : .regular))
                            .foregroundColor(idx == selectedDayIndex ? LuminaTheme.textPrimary : LuminaTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    if idx < dayLabels.count - 1 {
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

// MARK: - Semi-Circular Radial-Ticked Arc Gauge (ZIXO Weekly Spending Style)

struct RadialTickArcGauge: View {
    let progress: Double // 0.0 ... 1.0
    let centerTitle: String
    let centerSubtitle: String

    var body: some View {
        ZStack {
            // Radial hatched ticks along the full semi-circle
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height - 10)
                let radius = min(size.width / 2 - 14, size.height - 20)
                let totalTicks = 36
                for i in 0...totalTicks {
                    let frac = Double(i) / Double(totalTicks)
                    let angle = Angle(degrees: 180 + frac * 180).radians
                    let innerR = radius - 7
                    let outerR = radius + 7
                    let p1 = CGPoint(x: center.x + CGFloat(cos(angle)) * innerR, y: center.y + CGFloat(sin(angle)) * innerR)
                    let p2 = CGPoint(x: center.x + CGFloat(cos(angle)) * outerR, y: center.y + CGFloat(sin(angle)) * outerR)
                    var tick = Path()
                    tick.move(to: p1)
                    tick.addLine(to: p2)
                    context.stroke(tick, with: .color(LuminaTheme.trackGray), lineWidth: 1.5)
                }

                // Active solid charcoal arc
                let clamped = min(max(progress, 0.04), 1.0)
                var arc = Path()
                arc.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(180),
                    endAngle: .degrees(180 + clamped * 180),
                    clockwise: false
                )
                context.stroke(arc, with: .color(LuminaTheme.charcoalDark), style: StrokeStyle(lineWidth: 13, lineCap: .round))
            }

            VStack(spacing: 2) {
                Spacer()
                Text(centerTitle)
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundColor(LuminaTheme.textPrimary)
                Text(centerSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(LuminaTheme.textSecondary)
            }
            .padding(.bottom, 10)
        }
        .frame(height: 112)
    }
}
