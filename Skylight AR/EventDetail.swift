//
//  EventDetail.swift
//  Overhead
//
//  Handcrafted event art (no SF-symbol placeholders) and the event detail
//  view, narrated by Apple's on-device foundation model when available.
//

import SwiftUI
import UserNotifications
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Palette

private let gold = Theme.gold
private let moonlight = Color(red: 0.96, green: 0.96, blue: 0.91)
private let nightDisc = Color(red: 0.07, green: 0.08, blue: 0.12)
private let copper = Color(red: 0.93, green: 0.52, blue: 0.35)
private let auroraGreen = Color(red: 0.40, green: 0.85, blue: 0.62)
private let flame = Color(red: 0.98, green: 0.62, blue: 0.30)

extension SkyEvent.Kind {
    /// One accent per event family — countdowns, progress rings, borders.
    var tint: Color {
        switch self {
        case .eclipse: gold
        case .lunarEclipse: copper
        case .meteorShower: Theme.accent
        case .fullMoon: moonlight
        case .conjunction: Theme.accent
        case .season: gold
        case .occultation: moonlight
        case .aurora: auroraGreen
        case .rocketLaunch: flame
        case .reentry: copper
        case .fireball: gold
        }
    }

    /// Eclipses and occultations — the location-exact spectacles — get the
    /// headline treatment.
    var isHeadline: Bool { self == .eclipse || self == .lunarEclipse || self == .occultation }
}

// MARK: - Handcrafted glyphs (list size)

/// Small drawn mark for an event row — layered shapes, not symbols.
struct EventGlyph: View {
    let kind: SkyEvent.Kind

    var body: some View {
        switch kind {
        case .eclipse:
            ZStack {
                Circle().fill(gold)
                Circle().fill(nightDisc).offset(x: 7, y: -4)
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(gold.opacity(0.6), lineWidth: 0.8))
            .shadow(color: gold.opacity(0.5), radius: 4)
        case .meteorShower:
            Canvas { context, size in
                var streak = Path()
                streak.move(to: CGPoint(x: size.width * 0.15, y: size.height * 0.2))
                streak.addLine(to: CGPoint(x: size.width * 0.78, y: size.height * 0.78))
                context.stroke(streak, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0), .white]),
                    startPoint: CGPoint(x: size.width * 0.15, y: size.height * 0.2),
                    endPoint: CGPoint(x: size.width * 0.78, y: size.height * 0.78)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                let head = CGRect(x: size.width * 0.72, y: size.height * 0.72,
                                  width: size.width * 0.14, height: size.width * 0.14)
                context.fill(Path(ellipseIn: head), with: .color(.white))
            }
            .shadow(color: .white.opacity(0.6), radius: 3)
        case .fullMoon:
            Circle()
                .fill(RadialGradient(colors: [moonlight, moonlight.opacity(0.75)],
                                     center: .topLeading, startRadius: 1, endRadius: 22))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.8))
                .shadow(color: moonlight.opacity(0.5), radius: 4)
        case .lunarEclipse:
            // The moon deep in the umbra: copper disc, shadow across one limb.
            ZStack {
                Circle().fill(RadialGradient(colors: [copper, copper.opacity(0.55)],
                                             center: UnitPoint(x: 0.35, y: 0.65),
                                             startRadius: 1, endRadius: 20))
                Circle().fill(nightDisc.opacity(0.65)).offset(x: 6, y: -8)
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(copper.opacity(0.5), lineWidth: 0.8))
            .shadow(color: copper.opacity(0.55), radius: 4)
        case .conjunction:
            // Two lanterns almost touching.
            ZStack {
                Circle().fill(gold)
                    .frame(width: 11, height: 11)
                    .offset(x: -4, y: 3)
                    .shadow(color: gold.opacity(0.7), radius: 3)
                Circle().fill(.white)
                    .frame(width: 7, height: 7)
                    .offset(x: 5, y: -5)
                    .shadow(color: .white.opacity(0.7), radius: 3)
            }
        case .season:
            // Half a sun resting on the horizon line.
            Canvas { context, size in
                let hy = size.height * 0.64
                let c = CGPoint(x: size.width / 2, y: hy)
                var disc = Path()
                disc.addArc(center: c, radius: size.width * 0.30,
                            startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                disc.closeSubpath()
                context.fill(disc, with: .color(Color(gold)))
                var line = Path()
                line.move(to: CGPoint(x: 1, y: hy))
                line.addLine(to: CGPoint(x: size.width - 1, y: hy))
                context.stroke(line, with: .color(.white.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
            .shadow(color: gold.opacity(0.5), radius: 3)
        case .occultation:
            // The moon's dark limb sliding over a star.
            ZStack {
                Circle().fill(.white)
                    .frame(width: 6, height: 6)
                    .offset(x: 7, y: -6)
                    .shadow(color: .white.opacity(0.8), radius: 3)
                Circle().fill(RadialGradient(colors: [moonlight.opacity(0.9), moonlight.opacity(0.5)],
                                             center: UnitPoint(x: 0.3, y: 0.7),
                                             startRadius: 1, endRadius: 18))
                    .frame(width: 18, height: 18)
                    .offset(x: -2, y: 2)
            }
        case .aurora:
            // Three curtains leaning with the field lines.
            Canvas { context, size in
                for (i, x) in [0.28, 0.52, 0.76].enumerated() {
                    let lean = CGFloat(i - 1) * 3
                    var curtain = Path()
                    curtain.move(to: CGPoint(x: size.width * x + lean, y: size.height * 0.18))
                    curtain.addLine(to: CGPoint(x: size.width * x - lean, y: size.height * 0.85))
                    context.stroke(curtain, with: .linearGradient(
                        Gradient(colors: [auroraGreen.opacity(0.15), auroraGreen]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)),
                        style: StrokeStyle(lineWidth: i == 1 ? 4 : 3, lineCap: .round))
                }
            }
            .shadow(color: auroraGreen.opacity(0.6), radius: 4)
        case .rocketLaunch:
            // A climb-out: bright head, flame trail back to the pad.
            Canvas { context, size in
                let head = CGPoint(x: size.width * 0.66, y: size.height * 0.22)
                let pad = CGPoint(x: size.width * 0.30, y: size.height * 0.88)
                var trail = Path()
                trail.move(to: pad)
                trail.addQuadCurve(to: head, control: CGPoint(x: size.width * 0.34, y: size.height * 0.44))
                context.stroke(trail, with: .linearGradient(
                    Gradient(colors: [flame.opacity(0), flame]),
                    startPoint: pad, endPoint: head),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: head.x - 3.5, y: head.y - 3.5, width: 7, height: 7)),
                             with: .color(.white))
            }
            .shadow(color: flame.opacity(0.6), radius: 3)
        case .reentry:
            // Falling the other way, shedding sparks.
            Canvas { context, size in
                let head = CGPoint(x: size.width * 0.26, y: size.height * 0.80)
                let entry = CGPoint(x: size.width * 0.82, y: size.height * 0.16)
                var streak = Path()
                streak.move(to: entry)
                streak.addLine(to: head)
                context.stroke(streak, with: .linearGradient(
                    Gradient(colors: [copper.opacity(0), copper]),
                    startPoint: entry, endPoint: head),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                for (i, u) in [0.32, 0.55].enumerated() {
                    let p = CGPoint(x: entry.x + (head.x - entry.x) * u,
                                    y: entry.y + (head.y - entry.y) * u + CGFloat(i) * 3 + 3)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4)),
                                 with: .color(copper.opacity(0.8)))
                }
                context.fill(Path(ellipseIn: CGRect(x: head.x - 3, y: head.y - 3, width: 6, height: 6)),
                             with: .color(.white))
            }
            .shadow(color: copper.opacity(0.6), radius: 3)
        case .fireball:
            // One violent instant: a blazing head outshining its short trail.
            Canvas { context, size in
                let head = CGPoint(x: size.width * 0.62, y: size.height * 0.62)
                var streak = Path()
                streak.move(to: CGPoint(x: size.width * 0.2, y: size.height * 0.24))
                streak.addLine(to: head)
                context.stroke(streak, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0), gold]),
                    startPoint: CGPoint(x: size.width * 0.2, y: size.height * 0.24),
                    endPoint: head),
                    style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: head.x - 8, y: head.y - 8, width: 16, height: 16)),
                             with: .radialGradient(Gradient(colors: [gold.opacity(0.65), .clear]),
                                                   center: head, startRadius: 1, endRadius: 8))
                context.fill(Path(ellipseIn: CGRect(x: head.x - 3.5, y: head.y - 3.5, width: 7, height: 7)),
                             with: .color(.white))
            }
            .shadow(color: gold.opacity(0.7), radius: 4)
        }
    }
}

// MARK: - Hero art (detail size)

/// The full-bleed layered artwork at the top of an event's detail page.
struct EventHero: View {
    let kind: SkyEvent.Kind

    var body: some View {
        ZStack {
            // Star dust shared by all heroes.
            Canvas { context, size in
                var seed: UInt64 = 11
                for _ in 0..<34 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let x = CGFloat((seed >> 33) % 1000) / 1000 * size.width
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let y = CGFloat((seed >> 33) % 1000) / 1000 * size.height
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let r = 0.6 + CGFloat((seed >> 33) % 100) / 100 * 1.2
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                                 with: .color(.white.opacity(0.5)))
                }
            }
            heroBody
        }
        .frame(height: 190)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Theme.nightTop, Theme.nightBottom],
                           startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    @ViewBuilder private var heroBody: some View {
        switch kind {
        case .eclipse:
            ZStack {
                // Corona breathing out from behind the moon.
                Circle()
                    .fill(RadialGradient(colors: [gold.opacity(0.85), gold.opacity(0)],
                                         center: .center, startRadius: 24, endRadius: 95))
                    .frame(width: 190, height: 190)
                // The thin solar crescent.
                ZStack {
                    Circle().fill(gold)
                    Circle().fill(Theme.nightBottom).offset(x: 14, y: -8)
                }
                .frame(width: 92, height: 92)
                .clipShape(Circle())
                // Moon disc edge catching earthshine.
                Circle()
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    .frame(width: 92, height: 92)
                    .offset(x: 14, y: -8)
            }
        case .meteorShower:
            Canvas { context, size in
                let radiant = CGPoint(x: size.width * 0.68, y: size.height * 0.3)
                // Radiant glow.
                context.fill(Path(ellipseIn: CGRect(x: radiant.x - 26, y: radiant.y - 26, width: 52, height: 52)),
                             with: .radialGradient(Gradient(colors: [.white.opacity(0.35), .clear]),
                                                   center: radiant, startRadius: 1, endRadius: 30))
                // Streaks fanning out of the radiant.
                let angles: [CGFloat] = [2.45, 2.8, 3.25, 3.7, 2.1, 3.0]
                let lengths: [CGFloat] = [120, 88, 132, 76, 96, 150]
                for (i, angle) in angles.enumerated() {
                    let end = CGPoint(x: radiant.x + cos(angle) * lengths[i],
                                      y: radiant.y - sin(angle) * -lengths[i] * 0.55)
                    var streak = Path()
                    streak.move(to: radiant)
                    streak.addLine(to: end)
                    context.stroke(streak, with: .linearGradient(
                        Gradient(colors: [.white.opacity(0.85), .white.opacity(0)]),
                        startPoint: radiant, endPoint: end),
                        style: StrokeStyle(lineWidth: i % 2 == 0 ? 2.2 : 1.4, lineCap: .round))
                    context.fill(Path(ellipseIn: CGRect(x: radiant.x - 2.5, y: radiant.y - 2.5, width: 5, height: 5)),
                                 with: .color(.white))
                }
            }
        case .fullMoon:
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [moonlight.opacity(0.5), .clear],
                                         center: .center, startRadius: 40, endRadius: 110))
                    .frame(width: 220, height: 220)
                Circle()
                    .fill(RadialGradient(colors: [moonlight, moonlight.opacity(0.8)],
                                         center: UnitPoint(x: 0.35, y: 0.3),
                                         startRadius: 4, endRadius: 90))
                    .frame(width: 110, height: 110)
                // Mare shadows — three soft pools.
                Group {
                    Circle().fill(nightDisc.opacity(0.18)).frame(width: 30, height: 30).offset(x: -16, y: -12)
                    Circle().fill(nightDisc.opacity(0.14)).frame(width: 22, height: 22).offset(x: 14, y: 4)
                    Circle().fill(nightDisc.opacity(0.12)).frame(width: 16, height: 16).offset(x: -4, y: 22)
                }
            }
        case .lunarEclipse:
            ZStack {
                // Copper aura — sunset light bent through Earth's atmosphere.
                Circle()
                    .fill(RadialGradient(colors: [copper.opacity(0.45), .clear],
                                         center: .center, startRadius: 35, endRadius: 105))
                    .frame(width: 210, height: 210)
                // The blood moon itself, lit from its lower limb.
                Circle()
                    .fill(RadialGradient(colors: [copper, Color(red: 0.45, green: 0.16, blue: 0.10)],
                                         center: UnitPoint(x: 0.42, y: 0.78),
                                         startRadius: 6, endRadius: 85))
                    .frame(width: 104, height: 104)
                // The umbra's soft edge still biting the upper limb.
                Circle()
                    .fill(RadialGradient(colors: [nightDisc.opacity(0.75), .clear],
                                         center: .center, startRadius: 20, endRadius: 60))
                    .frame(width: 120, height: 120)
                    .offset(x: 22, y: -34)
                    .blendMode(.multiply)
            }
        case .conjunction:
            ZStack {
                // The brighter lantern, gold with a wide halo…
                Circle()
                    .fill(RadialGradient(colors: [gold.opacity(0.55), .clear],
                                         center: .center, startRadius: 3, endRadius: 60))
                    .frame(width: 120, height: 120)
                    .offset(x: -24, y: 12)
                Circle().fill(gold)
                    .frame(width: 17, height: 17)
                    .offset(x: -24, y: 12)
                // …and its companion just a finger's width away.
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.5), .clear],
                                         center: .center, startRadius: 2, endRadius: 42))
                    .frame(width: 84, height: 84)
                    .offset(x: 26, y: -18)
                Circle().fill(.white)
                    .frame(width: 11, height: 11)
                    .offset(x: 26, y: -18)
            }
        case .season:
            ZStack(alignment: .center) {
                // Glow pooling on the horizon.
                Circle()
                    .fill(RadialGradient(colors: [gold.opacity(0.5), .clear],
                                         center: .center, startRadius: 8, endRadius: 95))
                    .frame(width: 190, height: 190)
                    .offset(y: 34)
                // Half sun on the line.
                Circle()
                    .fill(LinearGradient(colors: [gold, gold.opacity(0.75)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 76, height: 76)
                    .mask(Rectangle().frame(height: 38).offset(y: -19))
                    .offset(y: 34)
                // The horizon itself, with the land dark below.
                VStack(spacing: 0) {
                    Spacer()
                    Rectangle().fill(.white.opacity(0.35)).frame(height: 1.2)
                    Rectangle().fill(Theme.nightBottom.opacity(0.85)).frame(height: 61)
                }
            }
        case .occultation:
            ZStack {
                // The star, moments from vanishing behind the limb.
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.6), .clear],
                                         center: .center, startRadius: 2, endRadius: 44))
                    .frame(width: 88, height: 88)
                    .offset(x: 52, y: -34)
                Circle().fill(.white)
                    .frame(width: 9, height: 9)
                    .offset(x: 52, y: -34)
                // The moon closing in, lit low on one limb.
                Circle()
                    .fill(RadialGradient(colors: [moonlight, moonlight.opacity(0.55)],
                                         center: UnitPoint(x: 0.3, y: 0.75),
                                         startRadius: 4, endRadius: 80))
                    .frame(width: 104, height: 104)
                    .offset(x: -12, y: 10)
                Circle()
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    .frame(width: 104, height: 104)
                    .offset(x: -12, y: 10)
            }
        case .aurora:
            Canvas { context, size in
                // Curtains hanging from the field lines, brightest at the base.
                let xs: [CGFloat] = [0.16, 0.30, 0.46, 0.60, 0.74, 0.88]
                let heights: [CGFloat] = [0.52, 0.72, 0.60, 0.80, 0.56, 0.68]
                context.addFilter(.blur(radius: 6))
                for (i, x) in xs.enumerated() {
                    let lean = CGFloat(i % 3 - 1) * 10
                    let top = CGPoint(x: size.width * x + lean, y: size.height * (1 - heights[i]) * 0.5)
                    let base = CGPoint(x: size.width * x - lean, y: size.height * 0.86)
                    var curtain = Path()
                    curtain.move(to: top)
                    curtain.addLine(to: base)
                    context.stroke(curtain, with: .linearGradient(
                        Gradient(colors: [auroraGreen.opacity(0.05), auroraGreen.opacity(0.7)]),
                        startPoint: top, endPoint: base),
                        style: StrokeStyle(lineWidth: i % 2 == 0 ? 16 : 22, lineCap: .round))
                }
            }
        case .rocketLaunch:
            Canvas { context, size in
                let pad = CGPoint(x: size.width * 0.30, y: size.height * 0.92)
                let head = CGPoint(x: size.width * 0.64, y: size.height * 0.22)
                // Pad glow still burning on the horizon.
                context.fill(Path(ellipseIn: CGRect(x: pad.x - 40, y: pad.y - 12, width: 80, height: 24)),
                             with: .radialGradient(Gradient(colors: [flame.opacity(0.5), .clear]),
                                                   center: pad, startRadius: 1, endRadius: 40))
                // The arc of the climb, flame fading up into exhaust.
                var trail = Path()
                trail.move(to: pad)
                trail.addQuadCurve(to: head, control: CGPoint(x: size.width * 0.34, y: size.height * 0.48))
                context.stroke(trail, with: .linearGradient(
                    Gradient(colors: [flame.opacity(0.1), flame]),
                    startPoint: pad, endPoint: head),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                // The vehicle: a hard white point with a wide halo.
                context.fill(Path(ellipseIn: CGRect(x: head.x - 26, y: head.y - 26, width: 52, height: 52)),
                             with: .radialGradient(Gradient(colors: [.white.opacity(0.35), .clear]),
                                                   center: head, startRadius: 1, endRadius: 26))
                context.fill(Path(ellipseIn: CGRect(x: head.x - 5, y: head.y - 5, width: 10, height: 10)),
                             with: .color(.white))
            }
        case .reentry:
            Canvas { context, size in
                let entry = CGPoint(x: size.width * 0.86, y: size.height * 0.14)
                let head = CGPoint(x: size.width * 0.24, y: size.height * 0.72)
                var streak = Path()
                streak.move(to: entry)
                streak.addLine(to: head)
                context.stroke(streak, with: .linearGradient(
                    Gradient(colors: [copper.opacity(0), copper]),
                    startPoint: entry, endPoint: head),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                // Fragments peeling off and dying behind the head.
                for (i, u) in [0.30, 0.46, 0.62].enumerated() {
                    let p = CGPoint(x: entry.x + (head.x - entry.x) * u,
                                    y: entry.y + (head.y - entry.y) * u + CGFloat(i) * 7 + 8)
                    let s = 3.5 - CGFloat(i) * 0.7
                    context.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)),
                                 with: .color(copper.opacity(0.8 - Double(i) * 0.2)))
                }
                context.fill(Path(ellipseIn: CGRect(x: head.x - 20, y: head.y - 20, width: 40, height: 40)),
                             with: .radialGradient(Gradient(colors: [copper.opacity(0.5), .clear]),
                                                   center: head, startRadius: 1, endRadius: 20))
                context.fill(Path(ellipseIn: CGRect(x: head.x - 4.5, y: head.y - 4.5, width: 9, height: 9)),
                             with: .color(.white))
            }
        case .fireball:
            Canvas { context, size in
                let head = CGPoint(x: size.width * 0.60, y: size.height * 0.58)
                let tail = CGPoint(x: size.width * 0.16, y: size.height * 0.18)
                var streak = Path()
                streak.move(to: tail)
                streak.addLine(to: head)
                context.stroke(streak, with: .linearGradient(
                    Gradient(colors: [gold.opacity(0), gold]),
                    startPoint: tail, endPoint: head),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round))
                // The flash that lights the whole frame for a heartbeat.
                context.fill(Path(ellipseIn: CGRect(x: head.x - 60, y: head.y - 60, width: 120, height: 120)),
                             with: .radialGradient(Gradient(colors: [gold.opacity(0.45), .clear]),
                                                   center: head, startRadius: 2, endRadius: 60))
                context.fill(Path(ellipseIn: CGRect(x: head.x - 7, y: head.y - 7, width: 14, height: 14)),
                             with: .color(.white))
            }
        }
    }
}

// MARK: - On-device narration

enum EventNarrator {
    /// A few sentences from Apple's on-device model; nil when unavailable.
    static func describe(_ event: SkyEvent) async -> String? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: """
            You are the voice of a calm, premium sky-watching app. Write vivid, \
            factual astronomy prose for curious people. Plain sentences only — \
            no markdown, no lists, no exclamation marks.
            """)
        let prompt = """
            In three short sentences, describe this sky event for someone who \
            will watch it: \(event.title) on \(event.date.formatted(date: .long, time: .shortened)). \
            Context: \(event.subtitle). Explain what causes it and the best way to experience it.
            """
        return try? await session.respond(to: prompt).content
        #else
        return nil
        #endif
    }
}

// MARK: - Event reminders

/// One local notification per event, an hour before it peaks. The pending-
/// request queue is the single source of truth — no shadow state to drift.
enum EventReminder {
    static func identifier(for event: SkyEvent) -> String {
        "skyevent-\(Int(event.date.timeIntervalSince1970))"
    }

    static func isScheduled(_ event: SkyEvent) async -> Bool {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.contains { $0.identifier == identifier(for: event) }
    }

    /// Toggle the reminder; returns whether one is now scheduled.
    static func toggle(_ event: SkyEvent) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let id = identifier(for: event)
        if await isScheduled(event) {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return false
        }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }
        let fireAt = event.date.addingTimeInterval(-3600)
        guard fireAt > Date() else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(event.title) — one hour to go")
        content.body = String(localized: "\(event.subtitle). Step outside and look up.")
        content.sound = .default
        content.threadIdentifier = "events"
        content.interruptionLevel = .active
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                    from: fireAt)
        try? await center.add(UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        Analytics.log("Event.reminderSet")
        return true
    }
}

// MARK: - Event detail

struct EventDetailView: View {
    let event: SkyEvent
    /// Present when opened from the events sheet — enables the Pro
    /// "preview in your sky" time jump. Nil elsewhere hides the button.
    var engine: SkyEngine? = nil
    @State private var narration: String?
    @State private var writing = true
    @State private var reminderSet = false
    @State private var skySet = false
    @State private var showPaywall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                EventHero(kind: event.kind)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(event.title)
                            .font(Theme.display(24, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(daysAway)
                            .font(Theme.display(14, .bold).monospacedDigit())
                            .foregroundStyle(event.kind.tint)
                    }
                    Text(event.subtitle)
                        .font(Theme.display(15, .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(event.date.formatted(date: .complete, time: .shortened))
                        .font(Theme.display(13, .regular))
                        .foregroundStyle(Theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(narration ?? event.detail)
                        .font(Theme.display(15, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(4)
                    if writing {
                        HStack(spacing: 8) {
                            ProgressView().tint(Theme.textTertiary).controlSize(.small)
                            Text("Writing with on-device intelligence…")
                                .font(Theme.display(12, .regular))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    } else if narration != nil {
                        Text("Written on this device by Apple Intelligence.")
                            .font(Theme.display(11, .regular))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(16)
                .nightCard()

                // The bell button delivers on the bell icon: one tap and the
                // sky comes to you an hour before it happens.
                if event.date.timeIntervalSinceNow > 4000 {
                    Button {
                        Task { reminderSet = await EventReminder.toggle(event) }
                    } label: {
                        Label(reminderSet ? "Reminder set — an hour before" : "Remind me an hour before",
                              systemImage: reminderSet ? "bell.fill" : "bell")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .sensoryFeedback(.success, trigger: reminderSet) { _, new in new }
                }

                // Pro: time-travel the AR sky to this event's exact moment.
                if let engine, abs(event.date.timeIntervalSinceNow) < 366 * 86_400 {
                    Button {
                        if ProStore.shared.isPro {
                            engine.skyTimeOffsetMin = event.date.timeIntervalSinceNow / 60
                            skySet = true
                            Analytics.log("Event.previewInSky", ["kind": "\(event.kind)"])
                        } else {
                            showPaywall = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Label(skySet ? "Sky set — close this sheet and look up"
                                         : "Preview in your sky",
                                  systemImage: skySet ? "checkmark" : "clock.arrow.2.circlepath")
                            if !ProStore.shared.isPro { ProChip() }
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .sensoryFeedback(.success, trigger: skySet) { _, new in new }
                    .sheet(isPresented: $showPaywall) {
                        NavigationStack { PaywallView(source: "eventPreview") }
                            .preferredColorScheme(.dark)
                    }
                }

                if event.kind == .eclipse {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(gold)
                        Text("Never look at the sun without certified eclipse glasses — at any phase of a partial eclipse.")
                            .font(Theme.display(13, .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(14)
                    .background(gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(24)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task {
            reminderSet = await EventReminder.isScheduled(event)
            narration = await EventNarrator.describe(event)
            writing = false
        }
    }

    private var daysAway: String {
        let days = event.date.timeIntervalSinceNow / 86_400
        if days <= -1 { return String(localized: "\(Int(-days))d ago") }   // recorded events (fireballs)
        if days < 1 { return String(localized: "today") }
        return String(localized: "in \(Int(days))d")
    }
}
