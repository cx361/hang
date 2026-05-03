import WidgetKit
import SwiftUI

// MARK: - Data model

struct HangEntry: TimelineEntry {
    let date: Date
    let nearbyCount: Int
    let statusText: String
    let isIncognito: Bool
    let isSafeZone: Bool
    let lastUpdated: Date?
}

// MARK: - Timeline provider

struct HangProvider: TimelineProvider {
    private let appGroup = "group.com.hangsocial.hang"

    func placeholder(in context: Context) -> HangEntry {
        HangEntry(date: Date(), nearbyCount: 1, statusText: "1 friend nearby",
                  isIncognito: false, isSafeZone: false, lastUpdated: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (HangEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HangEntry>) -> Void) {
        let entry = readEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func readEntry() -> HangEntry {
        let defaults = UserDefaults(suiteName: appGroup)
        let nearbyCount = defaults?.integer(forKey: "hang.nearbyCount") ?? 0
        let statusText  = defaults?.string(forKey: "hang.statusText")  ?? "Open hang to start"
        let isIncognito = defaults?.bool(forKey: "hang.isIncognito")   ?? false
        let isSafeZone  = defaults?.bool(forKey: "hang.isSafeZone")    ?? false
        var lastUpdated: Date? = nil
        if let iso = defaults?.string(forKey: "hang.lastUpdated") {
            lastUpdated = ISO8601DateFormatter().date(from: iso)
        }
        return HangEntry(date: Date(), nearbyCount: nearbyCount, statusText: statusText,
                         isIncognito: isIncognito, isSafeZone: isSafeZone, lastUpdated: lastUpdated)
    }
}

// MARK: - Hex shape

struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let r  = min(rect.width, rect.height) / 2
        var path = Path()
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3 - .pi / 6
            let pt = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Hex grid view

struct HexGrid: View {
    let hasNearbyFriends: Bool
    let isIncognito: Bool
    let isSafeZone: Bool

    // flat-top hex centres for a 3-ring pattern (scaled to 1.0 unit)
    private let positions: [(CGFloat, CGFloat)] = [
        // ring 0
        (0, 0),
        // ring 1
        (1, 0), (0.5, 0.866), (-0.5, 0.866),
        (-1, 0), (-0.5, -0.866), (0.5, -0.866),
        // ring 2 (partial, visible in medium)
        (2, 0), (1.5, 0.866), (0.5, 1.732), (-0.5, 1.732),
        (-1.5, 0.866), (-2, 0), (-1.5, -0.866), (-0.5, -1.732),
        (0.5, -1.732), (1.5, -0.866),
    ]

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width, geo.size.height) / 5.2
            let cx = geo.size.width  / 2
            let cy = geo.size.height / 2
            let hexR = scale * 0.55

            Canvas { ctx, _ in
                for (idx, pos) in positions.enumerated() {
                    let x = cx + pos.0 * scale
                    let y = cy + pos.1 * scale
                    let rect = CGRect(x: x - hexR, y: y - hexR,
                                      width: hexR * 2, height: hexR * 2)
                    let path = HexagonShape().path(in: rect)

                    // center hex
                    if idx == 0 {
                        if isSafeZone {
                            ctx.fill(path, with: .color(Color(hex: "#1A3A3D")))
                            ctx.stroke(path, with: .color(Color(hex: "#4DD0E1")), lineWidth: 1.5)
                        } else if isIncognito {
                            ctx.fill(path, with: .color(Color(hex: "#1A1A1A")))
                            ctx.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 1.5)
                        } else if hasNearbyFriends {
                            ctx.fill(path, with: .color(Color(hex: "#FF8800").opacity(0.25)))
                            ctx.stroke(path, with: .color(Color(hex: "#FF8800")), lineWidth: 1.5)
                        } else {
                            ctx.fill(path, with: .color(Color(hex: "#2A2A2A")))
                            ctx.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 1.5)
                        }
                    } else {
                        ctx.fill(path, with: .color(Color(hex: "#1A1A1A")))
                        ctx.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 1)
                    }
                }
            }
        }
    }
}

// MARK: - Widget views

struct HangWidgetSmallView: View {
    let entry: HangEntry

    var body: some View {
        ZStack {
            Color(hex: "#0A0A0A")

            VStack(spacing: 0) {
                // title
                HStack {
                    Text("hang.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                // hex grid
                HexGrid(hasNearbyFriends: entry.nearbyCount > 0,
                        isIncognito: entry.isIncognito,
                        isSafeZone: entry.isSafeZone)
                    .frame(height: 80)
                    .padding(.horizontal, 8)

                // status
                Text(statusLabel)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(statusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                // updated
                Text(updatedLabel)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.bottom, 10)
            }
        }
    }

    private var statusLabel: String {
        if entry.isSafeZone  { return "Safe Zone" }
        if entry.isIncognito { return "Incognito" }
        if entry.nearbyCount == 0 { return "No one nearby" }
        if entry.nearbyCount == 1 { return "1 friend nearby" }
        return "\(entry.nearbyCount) friends nearby"
    }

    private var statusColor: Color {
        if entry.isSafeZone  { return Color(hex: "#4DD0E1") }
        if entry.isIncognito { return .white.opacity(0.4) }
        if entry.nearbyCount > 0 { return Color(hex: "#FF8A00") }
        return .white.opacity(0.7)
    }

    private var updatedLabel: String {
        guard let d = entry.lastUpdated else { return "Not updated yet" }
        let mins = Int(Date().timeIntervalSince(d) / 60)
        if mins < 1  { return "Just now" }
        if mins < 60 { return "\(mins)m ago" }
        return "\(mins / 60)h ago"
    }
}

struct HangWidgetMediumView: View {
    let entry: HangEntry

    var body: some View {
        ZStack {
            Color(hex: "#0A0A0A")

            HStack(spacing: 0) {
                // hex grid left side
                HexGrid(hasNearbyFriends: entry.nearbyCount > 0,
                        isIncognito: entry.isIncognito,
                        isSafeZone: entry.isSafeZone)
                    .frame(width: 120)
                    .padding(.leading, 8)

                // info right side
                VStack(alignment: .leading, spacing: 6) {
                    Text("hang.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))

                    Text(statusLabel)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(statusColor)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)

                    Spacer()

                    Text(updatedLabel)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                }
                .padding(.vertical, 14)
                .padding(.leading, 12)
                .padding(.trailing, 16)

                Spacer()
            }
        }
    }

    private var statusLabel: String {
        if entry.isSafeZone  { return "Safe Zone active" }
        if entry.isIncognito { return "Incognito mode" }
        if entry.nearbyCount == 0 { return "No friends nearby" }
        if entry.nearbyCount == 1 { return "1 friend\nnearby" }
        return "\(entry.nearbyCount) friends\nnearby"
    }

    private var statusColor: Color {
        if entry.isSafeZone  { return Color(hex: "#4DD0E1") }
        if entry.isIncognito { return .white.opacity(0.4) }
        if entry.nearbyCount > 0 { return Color(hex: "#FF8A00") }
        return .white.opacity(0.7)
    }

    private var updatedLabel: String {
        guard let d = entry.lastUpdated else { return "Not updated yet" }
        let mins = Int(Date().timeIntervalSince(d) / 60)
        if mins < 1  { return "Updated just now" }
        if mins < 60 { return "Updated \(mins)m ago" }
        return "Updated \(mins / 60)h ago"
    }
}

// MARK: - Widget

struct HangWidget: Widget {
    let kind: String = "HangWidgetExtension"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HangProvider()) { entry in
            HangWidgetEntryView(entry: entry)
                .widgetURL(URL(string: "hang://open"))
        }
        .configurationDisplayName("hang.")
        .description("See who's nearby at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct HangWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: HangEntry

    var body: some View {
        switch family {
        case .systemMedium:
            HangWidgetMediumView(entry: entry)
        default:
            HangWidgetSmallView(entry: entry)
        }
    }
}

// MARK: - Helpers

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >>  8) & 0xFF) / 255
        let b = Double((int      ) & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
