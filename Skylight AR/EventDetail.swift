//
//  EventDetail.swift
//  Overhead
//
//  Handcrafted event art (no SF-symbol placeholders) and the event detail
//  view, narrated by Apple's on-device foundation model when available.
//

import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Palette

private let gold = Theme.gold
private let moonlight = Color(red: 0.96, green: 0.96, blue: 0.91)
private let nightDisc = Color(red: 0.07, green: 0.08, blue: 0.12)

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

// MARK: - Event detail

struct EventDetailView: View {
    let event: SkyEvent
    @State private var narration: String?
    @State private var writing = true

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
                            .foregroundStyle(event.kind == .eclipse ? gold : Theme.accent)
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
            narration = await EventNarrator.describe(event)
            writing = false
        }
    }

    private var daysAway: String {
        let days = event.date.timeIntervalSinceNow / 86_400
        if days < 1 { return "today" }
        return "in \(Int(days))d"
    }
}
