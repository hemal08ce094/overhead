//
//  OverheadNowWidget.swift
//  SkylightWidgets
//
//  "Overhead now" — a glance at the sky above you: how many aircraft are up,
//  and the nearest one plotted on a little radar rose at its true bearing.
//  The app writes a compact snapshot into the shared App Group on each refresh
//  (see the app-side `SkyGlance.swift`); this widget renders it across the Home
//  Screen (small / medium) and the Lock Screen (circular / rectangular / inline).
//
//  Pure SwiftUI + Canvas — no assets. Degrades gracefully: a calm "quiet sky"
//  when nothing's up, a friendly nudge before the app has ever run, and an
//  honest "x min ago" once a snapshot goes stale.
//

import WidgetKit
import SwiftUI

// MARK: - Snapshot mirror
// Coding shape MUST stay identical to the app-side `SkyGlanceSnapshot`; the two
// processes talk only through this JSON in the shared App Group.

struct SkyGlanceSnapshot: Codable, Equatable {
    var updated: Date
    var count: Int
    var offline: Bool
    var nearest: Plane?
    var observerLat: Double?
    var observerLon: Double?

    struct Plane: Codable, Equatable {
        var callsign: String?
        var type: String?
        var destination: String?
        var distanceNm: Double
        var altitudeFeet: Double
        var bearingDeg: Double
        var elevationDeg: Double
    }
}

enum SkyGlanceStore {
    static let appGroup = "group.hemal.Skylight-AR"
    static let key = "glance.v1"
    static let lastLatKey = "glance.lastLat"
    static let lastLonKey = "glance.lastLon"
    static let widgetKind = "hemal.Skylight-AR.overheadNow"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func read() -> SkyGlanceSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SkyGlanceSnapshot.self, from: data)
    }

    /// Persist a snapshot the widget fetched itself, so the app and other
    /// widgets share the fresher reading.
    static func write(_ snapshot: SkyGlanceSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: key)
    }

    /// The fetch seed: prefer the last snapshot's observer, fall back to the
    /// standalone last-known location the app stashes on every fix.
    static func seedLocation() -> (lat: Double, lon: Double)? {
        if let s = read(), let lat = s.observerLat, let lon = s.observerLon { return (lat, lon) }
        guard let d = defaults,
              d.object(forKey: lastLatKey) != nil, d.object(forKey: lastLonKey) != nil else { return nil }
        return (d.double(forKey: lastLatKey), d.double(forKey: lastLonKey))
    }

    /// A believable preview/placeholder so the gallery and first-run look alive.
    static var sample: SkyGlanceSnapshot {
        SkyGlanceSnapshot(updated: Date(), count: 6, offline: false,
                          nearest: .init(callsign: "EK203", type: "A388", destination: "DXB",
                                         distanceNm: 11.4, altitudeFeet: 36_000,
                                         bearingDeg: 247, elevationDeg: 34))
    }
}

// MARK: - Palette

enum Sky {
    static let accent    = Color(red: 0.60, green: 0.74, blue: 1.00)
    static let moonlight = Color(red: 0.96, green: 0.96, blue: 0.91)
    static let nightTop  = Color(red: 0.05, green: 0.06, blue: 0.13)
    static let nightBot  = Color(red: 0.01, green: 0.01, blue: 0.04)
    static let amber     = Color(red: 1.00, green: 0.75, blue: 0.40)

    static let gradient = LinearGradient(colors: [nightTop, nightBot],
                                         startPoint: .top, endPoint: .bottom)
}

// MARK: - Formatting helpers

enum Fmt {
    static let compass = ["N","NNE","NE","ENE","E","ESE","SE","SSE",
                          "S","SSW","SW","WSW","W","WNW","NW","NNW"]

    static func point(_ bearing: Double) -> String {
        compass[(Int((bearing / 22.5).rounded()) % 16 + 16) % 16]
    }

    static func altitude(_ feet: Double) -> String {
        feet >= 18_000
            ? "FL\(Int((feet / 100).rounded()))"
            : "\(Int((feet / 500).rounded() * 500).formatted()) ft"
    }

    static func distance(_ nm: Double) -> String {
        nm < 10 ? String(format: "%.1f nm", nm) : "\(Int(nm.rounded())) nm"
    }

    static func age(_ updated: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(updated))
        if s < 90 { return "just now" }
        if s < 3_600 { return "\(Int(s / 60))m ago" }
        return "\(Int(s / 3_600))h ago"
    }

    static func isStale(_ updated: Date, now: Date) -> Bool {
        now.timeIntervalSince(updated) > 600
    }

    static func callsign(_ p: SkyGlanceSnapshot.Plane) -> String {
        if let c = p.callsign, !c.isEmpty { return c }
        return "Traffic"
    }
}

// MARK: - The radar rose (the signature graphic)

/// A top-down scope: you at the centre, N up, the nearest contact plotted at its
/// true bearing with a soft needle and contrail. Distance sets how far out it
/// sits. Draws crisply at any size and stays legible when the Lock Screen tints
/// everything one colour.
struct SkyRose: View {
    var nearest: SkyGlanceSnapshot.Plane?
    var quiet: Bool = false
    /// Lock-Screen accessories flatten colour — draw in the tint, not our palette.
    var monochrome: Bool = false
    var showCardinals: Bool = true

    var body: some View {
        Canvas { ctx, size in
            let R = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let ink = monochrome ? Color.primary : Sky.accent
            let star = monochrome ? Color.primary : Sky.moonlight

            // Range rings.
            ctx.stroke(ring(c, R * 0.98), with: .color(ink.opacity(monochrome ? 0.5 : 0.28)),
                       lineWidth: monochrome ? 1.5 : 1)
            ctx.stroke(ring(c, R * 0.60), with: .color(ink.opacity(0.16)),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 4]))

            // Cardinal ticks; N gets a brighter stub.
            if showCardinals {
                for k in 0..<4 {
                    let a = Double(k) * .pi / 2
                    let outer = pointOn(c, R * 0.98, a)
                    let inner = pointOn(c, R * (k == 0 ? 0.74 : 0.86), a)
                    var p = Path(); p.move(to: inner); p.addLine(to: outer)
                    ctx.stroke(p, with: .color(ink.opacity(k == 0 ? 0.8 : 0.3)),
                               lineWidth: k == 0 ? 2 : 1)
                }
            }

            // Observer.
            ctx.fill(dot(c, monochrome ? 2.4 : 2.8), with: .color(star))

            guard let n = nearest, !quiet else {
                // Quiet sky: a single calm star drifting off-centre.
                if quiet {
                    let p = pointOn(c, R * 0.34, -0.6)
                    ctx.fill(dot(p, 1.8), with: .color(star.opacity(0.7)))
                }
                return
            }

            // Plot: bearing → angle (N up, clockwise), distance → radius.
            let theta = n.bearingDeg * .pi / 180
            let t = min(max(n.distanceNm / 40.0, 0), 1)          // 0…40 nm across the scope
            let rr = R * (0.30 + 0.62 * t)
            let pt = CGPoint(x: c.x + sin(theta) * rr, y: c.y - cos(theta) * rr)

            // Needle from you to the contact.
            var needle = Path(); needle.move(to: c); needle.addLine(to: pt)
            ctx.stroke(needle, with: .color(ink.opacity(monochrome ? 0.6 : 0.45)),
                       lineWidth: monochrome ? 1.4 : 1.2)

            // A short contrail trailing back toward you.
            for i in 1...5 {
                let f = CGFloat(i) / 6
                let p = CGPoint(x: c.x + (pt.x - c.x) * (1 - f * 0.5),
                                y: c.y + (pt.y - c.y) * (1 - f * 0.5))
                var tc = ctx; tc.opacity = Double(1 - f) * 0.5
                tc.fill(dot(p, 1.3 * (1 - f) + 0.5), with: .color(ink))
            }

            // Glow, then the plane glyph — rotated to match the Live Activity.
            if !monochrome {
                ctx.fill(dot(pt, R * 0.16),
                         with: .radialGradient(Gradient(colors: [Sky.accent.opacity(0.55), .clear]),
                                               center: pt, startRadius: 0, endRadius: R * 0.16))
            }
            let glyph = min(R * 0.44, 22)
            var plane = ctx.resolve(Image(systemName: "airplane"))
            plane.shading = .color(monochrome ? .primary : Sky.moonlight)
            ctx.drawLayer { layer in
                layer.translateBy(x: pt.x, y: pt.y)
                layer.rotate(by: .degrees(n.bearingDeg - 90))
                layer.draw(plane, in: CGRect(x: -glyph / 2, y: -glyph / 2, width: glyph, height: glyph))
            }
        }
    }

    private func ring(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
    private func dot(_ c: CGPoint, _ r: CGFloat) -> Path { ring(c, r) }
    private func pointOn(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> CGPoint {
        // a measured from North (up), clockwise.
        CGPoint(x: c.x + sin(a) * r, y: c.y - cos(a) * r)
    }
}

// MARK: - Timeline

struct OverheadEntry: TimelineEntry {
    let date: Date
    let snapshot: SkyGlanceSnapshot?
}

struct OverheadProvider: TimelineProvider {
    func placeholder(in context: Context) -> OverheadEntry {
        OverheadEntry(date: Date(), snapshot: SkyGlanceStore.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (OverheadEntry) -> Void) {
        let snap = context.isPreview ? SkyGlanceStore.sample : SkyGlanceStore.read()
        completion(OverheadEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OverheadEntry>) -> Void) {
        let stored = SkyGlanceStore.read()

        // No location seed yet → the app hasn't run once; render what we have and
        // check back in an hour rather than hammering with no place to look.
        guard let seed = SkyGlanceStore.seedLocation() else {
            completion(timeline(from: stored, refreshIn: 3_600))
            return
        }

        // Fetch our own traffic so the widget is fresh even if the app has been
        // closed for hours. On any failure, fall back to the last stored snapshot.
        Task {
            let fresh = await OverheadFetch.glance(lat: seed.lat, lon: seed.lon)
            if let fresh {
                SkyGlanceStore.write(fresh)                  // share the fresher reading
                completion(timeline(from: fresh, refreshIn: 900))     // ~15 min
            } else {
                completion(timeline(from: stored, refreshIn: 900))
            }
        }
    }

    /// A short run of entries off one snapshot so the "x min ago" advances, then
    /// ask WidgetKit to wake us for the next fetch.
    private func timeline(from snapshot: SkyGlanceSnapshot?, refreshIn seconds: TimeInterval)
        -> Timeline<OverheadEntry> {
        let now = Date()
        let step = seconds / 4
        let entries = (0..<4).map {
            OverheadEntry(date: now.addingTimeInterval(Double($0) * step), snapshot: snapshot)
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(seconds)))
    }
}

// MARK: - Family views

/// systemSmall — the rose as a full-bleed radar scope with a count badge and a
/// one-line readout of the nearest contact.
struct OverheadSmall: View {
    let entry: OverheadEntry

    var body: some View {
        let snap = entry.snapshot
        ZStack {
            SkyRose(nearest: snap?.nearest, quiet: (snap?.count ?? 0) == 0)
                .padding(6)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    countBadge(snap)
                    Spacer()
                }
                Spacer()
                bottomLine(snap)
            }
            .padding(2)
        }
    }

    private func countBadge(_ snap: SkyGlanceSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: -2) {
            Text("\(snap?.count ?? 0)")
                .font(.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(Sky.moonlight)
            Text("overhead")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Sky.accent)
                .textCase(.uppercase)
        }
        .shadow(color: Sky.nightBot.opacity(0.9), radius: 4)
    }

    @ViewBuilder private func bottomLine(_ snap: SkyGlanceSnapshot?) -> some View {
        if snap == nil {
            Text("Open Overhead")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        } else if let n = snap?.nearest {
            HStack(spacing: 5) {
                Text(Fmt.callsign(n))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Sky.moonlight)
                Text("· \(Fmt.distance(n.distanceNm))")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .shadow(color: Sky.nightBot.opacity(0.9), radius: 3)
        } else {
            Text("Quiet sky")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

/// systemMedium — rose on the left, a full readout on the right.
struct OverheadMedium: View {
    let entry: OverheadEntry

    var body: some View {
        let snap = entry.snapshot
        HStack(spacing: 16) {
            SkyRose(nearest: snap?.nearest, quiet: (snap?.count ?? 0) == 0)
                .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(snap?.count ?? 0)")
                        .font(.system(size: 40, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(Sky.moonlight)
                    Text("aircraft\noverhead")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Sky.accent)
                        .fixedSize()
                }

                Spacer(minLength: 6)
                readout(snap)
                Spacer(minLength: 4)
                freshness(snap)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func readout(_ snap: SkyGlanceSnapshot?) -> some View {
        if snap == nil {
            Text("Open Overhead once to light up your sky.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let n = snap?.nearest {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "airplane")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Sky.accent)
                        .rotationEffect(.degrees(n.bearingDeg - 90))
                    Text(Fmt.callsign(n))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Sky.moonlight)
                    if let dest = n.destination {
                        Text("→ \(dest)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(Fmt.point(n.bearingDeg)) · \(Fmt.distance(n.distanceNm)) · \(Fmt.altitude(n.altitudeFeet))")
                    .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(Sky.accent.opacity(0.9))
            }
            .lineLimit(1)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quiet sky")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Sky.moonlight)
                Text("Nothing within range right now.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func freshness(_ snap: SkyGlanceSnapshot?) -> some View {
        if let snap {
            let stale = Fmt.isStale(snap.updated, now: entry.date)
            HStack(spacing: 4) {
                Circle()
                    .fill(snap.offline || stale ? Sky.amber : Color.green.opacity(0.9))
                    .frame(width: 5, height: 5)
                Text(snap.offline ? "feed offline · \(Fmt.age(snap.updated, now: entry.date))"
                                  : "updated \(Fmt.age(snap.updated, now: entry.date))")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// accessoryCircular — a tiny scope gauge with the count in the middle.
struct OverheadCircular: View {
    let entry: OverheadEntry
    var body: some View {
        let snap = entry.snapshot
        ZStack {
            AccessoryWidgetBackground()
            SkyRose(nearest: snap?.nearest, quiet: (snap?.count ?? 0) == 0,
                    monochrome: true, showCardinals: false)
                .padding(1)
            Text("\(snap?.count ?? 0)")
                .font(.system(size: 17, weight: .heavy, design: .rounded).monospacedDigit())
                .shadow(radius: 2)
        }
        .widgetLabel("Overhead")
    }
}

/// accessoryRectangular — one compact, tintable line block.
struct OverheadRectangular: View {
    let entry: OverheadEntry
    var body: some View {
        let snap = entry.snapshot
        HStack(spacing: 8) {
            SkyRose(nearest: snap?.nearest, quiet: (snap?.count ?? 0) == 0,
                    monochrome: true, showCardinals: false)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "airplane")
                    Text("\(snap?.count ?? 0) overhead")
                        .font(.headline)
                }
                if let n = snap?.nearest {
                    Text("\(Fmt.callsign(n)) · \(Fmt.distance(n.distanceNm)) \(Fmt.point(n.bearingDeg))")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Quiet sky")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// accessoryInline — the thin line above the clock.
struct OverheadInline: View {
    let entry: OverheadEntry
    var body: some View {
        let snap = entry.snapshot
        if let n = snap?.nearest {
            Label("\(snap?.count ?? 0) overhead · \(Fmt.callsign(n)) \(Fmt.distance(n.distanceNm))",
                  systemImage: "airplane")
        } else {
            Label("\(snap?.count ?? 0) overhead", systemImage: "airplane")
        }
    }
}

// MARK: - Dispatch + widget

struct OverheadNowEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OverheadEntry

    var body: some View {
        switch family {
        case .systemMedium:
            OverheadMedium(entry: entry)
                .containerBackground(for: .widget) { Sky.gradient }
        case .accessoryCircular:
            OverheadCircular(entry: entry)
                .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            OverheadRectangular(entry: entry)
                .containerBackground(.clear, for: .widget)
        case .accessoryInline:
            OverheadInline(entry: entry)
                .containerBackground(.clear, for: .widget)
        default:
            OverheadSmall(entry: entry)
                .containerBackground(for: .widget) { Sky.gradient }
        }
    }
}

struct OverheadNowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SkyGlanceStore.widgetKind, provider: OverheadProvider()) { entry in
            OverheadNowEntryView(entry: entry)
        }
        .configurationDisplayName("Overhead now")
        .description("How many aircraft are above you, and the nearest one on a live radar rose.")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) { OverheadNowWidget() }
timeline: {
    OverheadEntry(date: Date(), snapshot: SkyGlanceStore.sample)
    OverheadEntry(date: Date(), snapshot: SkyGlanceSnapshot(updated: Date(), count: 0, offline: false, nearest: nil))
}

#Preview("Medium", as: .systemMedium) { OverheadNowWidget() }
timeline: {
    OverheadEntry(date: Date(), snapshot: SkyGlanceStore.sample)
    OverheadEntry(date: Date().addingTimeInterval(-1_200),
                  snapshot: SkyGlanceSnapshot(updated: Date().addingTimeInterval(-1_200),
                                              count: 3, offline: true,
                                              nearest: .init(callsign: "BA106", type: "B77W", destination: "LHR",
                                                             distanceNm: 22, altitudeFeet: 38_000,
                                                             bearingDeg: 78, elevationDeg: 21)))
}

#Preview("Circular", as: .accessoryCircular) { OverheadNowWidget() }
timeline: { OverheadEntry(date: Date(), snapshot: SkyGlanceStore.sample) }

#Preview("Rectangular", as: .accessoryRectangular) { OverheadNowWidget() }
timeline: { OverheadEntry(date: Date(), snapshot: SkyGlanceStore.sample) }
