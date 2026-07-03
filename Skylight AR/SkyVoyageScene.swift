//
//  SkyVoyageScene.swift
//  Skylight AR
//
//  Animated hero scene: a miniature solar system with an airliner that glides
//  across the sky and passes behind real Liquid Glass, refracting through it.
//  Used as the Profile header and the onboarding welcome hero. Pure Canvas —
//  no assets, no dependencies — and freezes to a composed still under
//  Reduce Motion.
//

import SwiftUI

// MARK: - Scene canvas

/// The drawing itself: stars, sun, orbiting planets, contrail and plane.
/// Time-driven via TimelineView so everything stays perfectly smooth and cheap.
struct SkyVoyageScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds for one full plane crossing (including the offscreen pause).
    var planeCycle: Double = 11
    /// Star density; the onboarding hero uses more, the header fewer.
    var starCount: Int = 70
    /// Vertical band the airliner crosses in (fraction of height at the edges)
    /// and how far the arc climbs above it. Profile lifts the plane to the top
    /// so it threads through the glass banner pinned there.
    var planeBaseY: CGFloat = 0.72
    var planeArc: CGFloat = 0.18
    /// Stop drawing entirely (scrolled away, covered) — not just slow down.
    var paused: Bool = false

    private struct SceneStar {
        let x: CGFloat, y: CGFloat, r: CGFloat, phase: Double, speed: Double, base: Double
    }

    private let sceneStars: [SceneStar]

    init(planeCycle: Double = 11, starCount: Int = 70,
         planeBaseY: CGFloat = 0.72, planeArc: CGFloat = 0.18,
         paused: Bool = false) {
        self.planeCycle = planeCycle
        self.starCount = starCount
        self.planeBaseY = planeBaseY
        self.planeArc = planeArc
        self.paused = paused
        var rng = VoyageRNG(seed: 42)
        sceneStars = (0..<starCount).map { _ in
            SceneStar(x: .random(in: 0...1, using: &rng),
                      y: .random(in: 0...1, using: &rng),
                      r: .random(in: 0.4...1.4, using: &rng),
                      phase: .random(in: 0...(2 * .pi), using: &rng),
                      speed: .random(in: 0.3...1.0, using: &rng),
                      base: .random(in: 0.25...0.65, using: &rng))
        }
    }

    var body: some View {
        // 30 fps: the scene's motion is slow drift — indistinguishable from 60
        // at these speeds, and it halves the canvas redraw cost.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || paused)) { timeline in
            // Under Reduce Motion, hold a hand-picked still: plane mid-sky,
            // planets spread pleasantly around their orbits.
            let t = reduceMotion ? planeCycle * 0.38
                                 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                drawStars(ctx: ctx, size: size, t: t)
                drawSolarSystem(ctx: ctx, size: size, t: t)
                drawPlane(ctx: ctx, size: size, t: t)
            }
        }
    }

    // MARK: Stars

    private func drawStars(ctx: GraphicsContext, size: CGSize, t: Double) {
        var ctx = ctx
        for s in sceneStars {
            let twinkle = s.base + (1 - s.base) * (0.5 + 0.5 * sin(t * s.speed + s.phase))
            let rect = CGRect(x: s.x * size.width, y: s.y * size.height,
                              width: s.r * 2, height: s.r * 2)
            ctx.opacity = twinkle
            ctx.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.85, green: 0.89, blue: 1.0)))
        }
    }

    // MARK: Solar system

    private struct Planet {
        let orbit: CGFloat        // orbit radius as a fraction of scene height
        let size: CGFloat
        let speed: Double         // radians per second
        let phase: Double
        let color: Color
        let ringed: Bool
    }

    private let planets: [Planet] = [
        Planet(orbit: 0.34, size: 3.2, speed: 0.52, phase: 2.4,
               color: Color(red: 0.60, green: 0.74, blue: 1.00), ringed: false),
        Planet(orbit: 0.55, size: 4.4, speed: 0.31, phase: 0.6,
               color: Color(red: 0.95, green: 0.72, blue: 0.52), ringed: false),
        Planet(orbit: 0.78, size: 3.8, speed: 0.19, phase: 4.1,
               color: Color(red: 0.58, green: 0.86, blue: 0.80), ringed: true),
    ]

    private func drawSolarSystem(ctx: GraphicsContext, size: CGSize, t: Double) {
        // Sun sits toward the top-trailing corner; orbits are flattened
        // ellipses for a gentle sense of perspective.
        let sun = CGPoint(x: size.width * 0.80, y: size.height * 0.34)
        let squash: CGFloat = 0.42

        // Orbit rings
        for p in planets {
            let r = p.orbit * size.height
            let ring = Path(ellipseIn: CGRect(x: sun.x - r, y: sun.y - r * squash,
                                              width: r * 2, height: r * 2 * squash))
            ctx.stroke(ring, with: .color(.white.opacity(0.09)), lineWidth: 0.8)
        }

        // Planets behind the sun (upper half of the ellipse) draw first, so
        // the sun's glow covers them — cheap depth.
        let positioned = planets.map { p -> (Planet, CGPoint, Bool) in
            let a = t * p.speed + p.phase
            let r = p.orbit * size.height
            let pt = CGPoint(x: sun.x + cos(a) * r, y: sun.y + sin(a) * r * squash)
            return (p, pt, sin(a) < 0)   // behind when on the far side
        }

        for (p, pt, behind) in positioned where behind { drawPlanet(ctx: ctx, p, at: pt) }
        drawSun(ctx: ctx, at: sun)
        for (p, pt, behind) in positioned where !behind { drawPlanet(ctx: ctx, p, at: pt) }
    }

    private func drawSun(ctx: GraphicsContext, at pt: CGPoint) {
        let gold = Color(red: 1.00, green: 0.84, blue: 0.55)
        // Halo
        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 26, y: pt.y - 26, width: 52, height: 52)),
                 with: .radialGradient(Gradient(colors: [gold.opacity(0.35), .clear]),
                                       center: pt, startRadius: 2, endRadius: 26))
        // Core
        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 7, y: pt.y - 7, width: 14, height: 14)),
                 with: .radialGradient(Gradient(colors: [Color(red: 1.0, green: 0.96, blue: 0.86), gold]),
                                       center: CGPoint(x: pt.x - 2, y: pt.y - 2),
                                       startRadius: 1, endRadius: 9))
    }

    private func drawPlanet(ctx: GraphicsContext, _ p: Planet, at pt: CGPoint) {
        if p.ringed {
            let ring = Path(ellipseIn: CGRect(x: pt.x - p.size * 2.1, y: pt.y - p.size * 0.75,
                                              width: p.size * 4.2, height: p.size * 1.5))
            ctx.stroke(ring, with: .color(p.color.opacity(0.55)), lineWidth: 1)
        }
        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - p.size, y: pt.y - p.size,
                                        width: p.size * 2, height: p.size * 2)),
                 with: .radialGradient(Gradient(colors: [p.color, p.color.opacity(0.55)]),
                                       center: CGPoint(x: pt.x - p.size * 0.4, y: pt.y - p.size * 0.4),
                                       startRadius: 0.5, endRadius: p.size * 1.6))
    }

    // MARK: Plane + contrail

    /// Position along the crossing at unit progress `u` (0 = enters left,
    /// 1 = exits right), on a gentle climbing arc.
    private func planePoint(_ u: Double, size: CGSize) -> CGPoint {
        let x = CGFloat(u) * (size.width + 80) - 40
        let y = size.height * (planeBaseY - planeArc * CGFloat(sin(u * .pi)))
        return CGPoint(x: x, y: y)
    }

    private func drawPlane(ctx: GraphicsContext, size: CGSize, t: Double) {
        // The plane spends ~80% of the cycle crossing, then rests offscreen.
        let u = (t.truncatingRemainder(dividingBy: planeCycle)) / (planeCycle * 0.8)
        guard u <= 1.02 else { return }

        let pt = planePoint(u, size: size)
        let ahead = planePoint(min(u + 0.01, 1.05), size: size)
        let heading = atan2(ahead.y - pt.y, ahead.x - pt.x)

        // Contrail: fading, slightly dispersing puffs along the path flown.
        var trail = ctx
        for i in 1...26 {
            let uu = u - Double(i) * 0.012
            guard uu > 0 else { break }
            let p = planePoint(uu, size: size)
            let fade = 1 - Double(i) / 26
            let puff: CGFloat = 1.0 + CGFloat(i) * 0.10
            trail.opacity = fade * 0.30
            trail.fill(Path(ellipseIn: CGRect(x: p.x - puff, y: p.y - puff,
                                              width: puff * 2, height: puff * 2)),
                       with: .color(.white))
        }

        // The airliner itself — SF Symbol, banked along its heading.
        var resolved = ctx.resolve(Image(systemName: "airplane"))
        resolved.shading = .color(.white.opacity(0.95))
        ctx.drawLayer { layer in
            layer.translateBy(x: pt.x, y: pt.y)
            layer.rotate(by: .radians(heading))
            layer.addFilter(.shadow(color: .white.opacity(0.5), radius: 5))
            layer.draw(resolved, in: CGRect(x: -9, y: -9, width: 18, height: 18))
        }
    }
}

/// Seeded RNG so the layout is stable across redraws and launches.
private struct VoyageRNG: RandomNumberGenerator {
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

// MARK: - Onboarding hero

/// Larger welcome-page hero: the same living sky behind the glass moon orb,
/// with the plane refracting through the moon as it passes.
struct SkyVoyageHero: View {
    var body: some View {
        ZStack {
            SkyVoyageScene(planeCycle: 9, starCount: 40)
                .frame(height: 190)
            MoonMark().frame(width: 116, height: 116)
        }
        .accessibilityHidden(true)
    }
}

#Preview("Hero") {
    ZStack {
        Theme.skyGradient.ignoresSafeArea()
        SkyVoyageHero()
    }
}
