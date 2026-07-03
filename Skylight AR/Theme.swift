//
//  Theme.swift
//  Skylight AR
//
//  Design system. Dark, celestial, typography-forward — calm motion, soft glows,
//  frosted glass. Shared palette + reusable components for every SwiftUI surface.
//

import SwiftUI

// MARK: - Palette & type

enum Theme {
    // Night palette
    static let nightTop    = Color(red: 0.05, green: 0.06, blue: 0.13)
    static let nightBottom = Color(red: 0.01, green: 0.01, blue: 0.04)
    static let indigo      = Color(red: 0.23, green: 0.25, blue: 0.48)
    static let moonlight   = Color(red: 0.96, green: 0.96, blue: 0.91)
    static let accent      = Color(red: 0.60, green: 0.74, blue: 1.00)
    static let accentSoft  = Color(red: 0.45, green: 0.58, blue: 0.95)

    /// Sunlight gold — eclipses, the sun, transit moments. One value app-wide.
    static let gold = Color(red: 1.0, green: 0.82, blue: 0.45)

    static let textPrimary   = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary  = Color.white.opacity(0.40)

    /// The deep-sky backdrop used behind every full-screen surface.
    static var skyGradient: LinearGradient {
        LinearGradient(
            colors: [nightTop, nightBottom],
            startPoint: .top, endPoint: .bottom)
    }

    /// A soft radial glow, e.g. a moon or a horizon bloom.
    static func glow(_ color: Color) -> RadialGradient {
        RadialGradient(
            colors: [color.opacity(0.55), color.opacity(0.0)],
            center: .center, startRadius: 1, endRadius: 220)
    }

    // Display type — rounded, generous, calm.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Tracked-caps section label — the one way sections are introduced app-wide.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.display(11, .semibold))
            .tracking(1.6)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// The app's card material: night-tinted glass with a moonlit top edge, so
/// grouped content reads as part of the sky rather than a gray settings box.
struct NightCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 18
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                shape.fill(Theme.indigo.opacity(0.12))
                shape.fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.025)],
                                          startPoint: .top, endPoint: .bottom))
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
    }
}

extension View {
    func nightCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(NightCardModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Animated starfield backdrop

private struct Star {
    let x: CGFloat, y: CGFloat, r: CGFloat, phase: Double, speed: Double, base: Double
}

/// A tiny seeded RNG so the star layout is stable across redraws and launches.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Gently twinkling field of stars. Cheap Canvas draw; calm motion.
struct Starfield: View {
    private let stars: [Star]

    init(count: Int = 110) {
        var rng = SeededRNG(seed: 7)
        stars = (0..<count).map { _ in
            Star(x: .random(in: 0...1, using: &rng),
                 y: .random(in: 0...1, using: &rng),
                 r: .random(in: 0.4...1.6, using: &rng),
                 phase: .random(in: 0...(2 * .pi), using: &rng),
                 speed: .random(in: 0.3...1.1, using: &rng),
                 base: .random(in: 0.25...0.7, using: &rng))
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for s in stars {
                    let twinkle = s.base + (1 - s.base) * (0.5 + 0.5 * sin(t * s.speed + s.phase))
                    let rect = CGRect(x: s.x * size.width, y: s.y * size.height,
                                      width: s.r * 2, height: s.r * 2)
                    ctx.opacity = twinkle
                    ctx.fill(Path(ellipseIn: rect), with: .color(Theme.star))
                }
            }
        }
    }
}

private extension Theme { static let star = Color(red: 0.85, green: 0.89, blue: 1.0) }

// MARK: - Reusable surfaces

/// Liquid glass card.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(20)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
    }
}

/// Primary action button — liquid glass, faintly moonlit, springy on press.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.display(17, .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .contentShape(Capsule())
            // Plain (non-interactive) glass: `.interactive()` runs its own touch
            // handling and swallows the tap before the Button receives it.
            .glassEffect(.regular.tint(Theme.accentSoft.opacity(0.35)), in: .capsule)
            .shadow(color: Theme.accent.opacity(0.25), radius: 16, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Quiet secondary button (text only).
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.display(16, .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.vertical, 12)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}
