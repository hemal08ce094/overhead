//
//  MoonClockWidget.swift
//  SkylightWidgets
//
//  A nightstand moon clock — phase disc, illumination, and the next full
//  moon. Designed for StandBy: calm, dim, legible from across the room.
//  Phase math is self-contained (mean synodic month), accurate to ~½ day.
//

import WidgetKit
import SwiftUI

struct MoonClockEntry: TimelineEntry {
    let date: Date
    let fraction: Double      // illuminated 0…1
    let waxing: Bool
    let phaseName: String
    let nextFullMoon: Date
}

enum MoonMath {
    static let synodic = 29.530588853 * 86_400
    /// A known new moon: 2000-01-06 18:14 UTC.
    static let epoch = Date(timeIntervalSince1970: 947_182_440)

    static func entry(for date: Date) -> MoonClockEntry {
        let age = (date.timeIntervalSince(epoch)).truncatingRemainder(dividingBy: synodic)
        let phase = age / synodic                       // 0 new → 0.5 full → 1 new
        let fraction = (1 - cos(2 * .pi * phase)) / 2
        let waxing = phase < 0.5
        let name: String
        switch phase {
        case ..<0.03, 0.97...: name = "New moon"
        case ..<0.22: name = "Waxing crescent"
        case ..<0.28: name = "First quarter"
        case ..<0.47: name = "Waxing gibbous"
        case ..<0.53: name = "Full moon"
        case ..<0.72: name = "Waning gibbous"
        case ..<0.78: name = "Last quarter"
        default: name = "Waning crescent"
        }
        let sinceEpoch = date.timeIntervalSince(epoch)
        let cycles = (sinceEpoch / synodic).rounded(.down)
        var nextFull = epoch.addingTimeInterval((cycles + 0.5) * synodic)
        if nextFull < date { nextFull = epoch.addingTimeInterval((cycles + 1.5) * synodic) }
        return MoonClockEntry(date: date, fraction: fraction, waxing: waxing,
                              phaseName: name, nextFullMoon: nextFull)
    }
}

struct MoonClockProvider: TimelineProvider {
    func placeholder(in context: Context) -> MoonClockEntry { MoonMath.entry(for: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (MoonClockEntry) -> Void) {
        completion(MoonMath.entry(for: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MoonClockEntry>) -> Void) {
        let now = Date()
        let entries = (0..<12).map { MoonMath.entry(for: now.addingTimeInterval(Double($0) * 3600)) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct MoonClockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "hemal.Skylight-AR.moonClock", provider: MoonClockProvider()) { entry in
            MoonClockView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.13),
                                            Color(red: 0.01, green: 0.01, blue: 0.04)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Moon clock")
        .description("Tonight's moon, its phase, and the next full moon.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct MoonClockView: View {
    let entry: MoonClockEntry
    @Environment(\.widgetFamily) private var family

    private let moonlight = Color(red: 0.96, green: 0.96, blue: 0.91)
    private let night = Color(red: 0.10, green: 0.11, blue: 0.16)

    var body: some View {
        switch family {
        case .systemMedium:
            HStack(spacing: 18) {
                moonDisc.frame(width: 78, height: 78)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.phaseName)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(moonlight)
                    Text("\(Int((entry.fraction * 100).rounded()))% illuminated")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("Full moon \(entry.nextFullMoon, format: .dateTime.month(.abbreviated).day())")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        default:
            VStack(spacing: 8) {
                moonDisc.frame(width: 64, height: 64)
                Text(entry.phaseName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(moonlight)
                    .minimumScaleFactor(0.8)
                Text("\(Int((entry.fraction * 100).rounded()))%")
                    .font(.system(size: 11, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The phase disc: lit limb plus an elliptical terminator.
    private var moonDisc: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                                width: 2 * r, height: 2 * r)),
                         with: .color(night))
            let f = entry.fraction
            guard f > 0.01 else { return }
            let sign: CGFloat = entry.waxing ? 1 : -1
            let rx = r * CGFloat(1 - 2 * f)
            var path = Path()
            let n = 48
            for i in 0...n {
                let phi = CGFloat.pi * CGFloat(i) / CGFloat(n)
                let p = CGPoint(x: center.x + sign * r * sin(phi), y: center.y - r * cos(phi))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            for i in 0...n {
                let phi = CGFloat.pi * CGFloat(n - i) / CGFloat(n)
                path.addLine(to: CGPoint(x: center.x + sign * rx * sin(phi),
                                         y: center.y - r * cos(phi)))
            }
            path.closeSubpath()
            context.fill(path, with: .color(moonlight))
        }
        .shadow(color: moonlight.opacity(0.35), radius: 8)
    }
}
