//
//  MedalAssembly.swift
//  Skylight AR
//
//  The medal-open moment: a cloud of star-motes swirls in along decaying
//  spirals and assembles into the medal's engraved emblem — the pictogram
//  drawn purely in particles — then the real metal materialises through the
//  formation as the dots sigh outward and fade. Runs every time a medal is
//  opened; the whole animation is a pure function of one start date and each
//  particle's seed, so there is no per-frame state and nothing to clean up.
//
//  Targets are sampled once per medal from MedalArt's emblem render (white
//  on transparent), so whatever the engraving shows — the rotor, the
//  constellation, a count — is exactly what the particles draw.
//

import SwiftUI

// MARK: - Emblem sampling

@MainActor
private enum EmblemPoints {
    private static var cache: [String: [CGPoint]] = [:]

    /// Unit-square points (0…1) covering the emblem's bright pixels, plus a
    /// guaranteed rim ring. Capped so the Canvas stays cheap.
    static func points(for medal: Medal, cap: Int = 750) -> [CGPoint] {
        if let hit = cache[medal.id] { return hit }
        var pts: [CGPoint] = []

        // Rasterise the emblem small and read alpha — the emblem is drawn
        // white on transparent, so alpha IS the shape.
        let n = 112
        let img = MedalArt.emblemImage(for: medal, size: 224)
        var alpha = [UInt8](repeating: 0, count: n * n)
        if let cg = img.cgImage,
           let ctx = CGContext(data: &alpha, width: n, height: n, bitsPerComponent: 8,
                               bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            for y in 0..<n where y % 2 == 0 {          // every other row: even density
                for x in 0..<n where x % 2 == 0 {
                    if alpha[y * n + x] > 96 {
                        pts.append(CGPoint(x: Double(x) / Double(n),
                                           y: Double(y) / Double(n)))
                    }
                }
            }
        }
        // Thin to the cap deterministically (no shuffling — stable visuals).
        if pts.count > cap {
            let stride = Double(pts.count) / Double(cap)
            pts = (0..<cap).map { pts[Int(Double($0) * stride)] }
        }
        // The rim ring, explicit — the engraved circle is one pixel wide and
        // samples too sparsely to read as a rim on its own.
        for i in 0..<110 {
            let a = Double(i) / 110 * 2 * .pi
            pts.append(CGPoint(x: 0.5 + cos(a) * 0.41, y: 0.5 + sin(a) * 0.41))
        }
        cache[medal.id] = pts
        return pts
    }
}

// MARK: - The assembly overlay

/// Draws the swirl-in + formation + release. Place over the medal view;
/// it renders nothing once finished.
struct MedalAssembly: View {
    let medal: Medal
    var duration: Double = 1.5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        if !reduceMotion {
            let targets = EmblemPoints.points(for: medal)
            let tint = MedalArt.colors(medal.finish).thumbLight
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    let p = timeline.date.timeIntervalSince(start) / duration
                    guard p < 1.08 else { return }
                    let side = min(size.width, size.height)
                    let cx = size.width / 2, cy = size.height / 2
                    let span = side * 0.94                 // emblem square on screen

                    for (i, tp) in targets.enumerated() {
                        var h = UInt64(i) &* 0x9E3779B97F4A7C15
                        func rnd() -> Double {
                            h ^= h >> 12; h ^= h << 25; h ^= h >> 27
                            return Double((h &* 2685821657736338717) >> 40) / Double(1 << 24)
                        }
                        let r0 = rnd(), r1 = rnd(), r2 = rnd(), r3 = rnd()

                        // Target in polar form around the centre.
                        let tx = (tp.x - 0.5) * span, ty = (tp.y - 0.5) * span
                        let tRadius = sqrt(tx * tx + ty * ty)
                        let tAngle = atan2(ty, tx)

                        // Life: staggered starts, ease-out arrival.
                        let delay = r0 * 0.30
                        let u = min(max((p - delay) / (0.78 - delay), 0), 1)
                        let e = 1 - pow(1 - u, 3)

                        // Swirl in: born far out on a rotated angle, spiral
                        // decays onto the target. Alternate handedness.
                        let swirl = (1.4 + r1 * 1.6) * (i % 2 == 0 ? 1 : -1)
                        let born = side * (0.55 + r2 * 0.45)
                        let radius = tRadius + (born - tRadius) * (1 - e)
                        let angle = tAngle + swirl * (1 - e)
                        // Formed dots breathe just a little, like the sky.
                        let shimmer = e * sin(timeline.date.timeIntervalSinceReferenceDate * (1.5 + r3) + r1 * 6.28)
                        let x = cx + cos(angle) * radius + shimmer
                        let y = cy + sin(angle) * radius + shimmer * 0.6

                        // In fast, out slow: release after the metal shows.
                        var a = min(u * 4, 1) * (0.35 + 0.55 * r3)
                        if p > 0.86 { a *= max(0, 1 - (p - 0.86) / 0.22) }

                        let spark = i % 6 == 0
                        let s = (spark ? 1.4 : 1.1) + r2 * 1.7
                        ctx.fill(Path(ellipseIn: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)),
                                 with: .color((spark ? Color.white : tint).opacity(a)))
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Medal + assembly, ready to drop in

/// The 3D medal that arrives by particle assembly: dots draw the emblem,
/// then the metal fades up through them. Every open replays the moment
/// (`.id(medal.id)` in callers restarts it when the subject changes).
struct AssembledMedal3D: View {
    let medal: Medal
    var award: MedalAward?
    var cameraDistance: Float = 2.8
    var hero: Bool = true
    var locked: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        ZStack {
            MedalView3D(medal: medal, award: award,
                        cameraDistance: cameraDistance, hero: hero, locked: locked)
                .opacity(revealed ? 1 : 0)
                .scaleEffect(revealed ? 1 : 0.94)
            MedalAssembly(medal: medal)
        }
        .task {
            guard !reduceMotion else { revealed = true; return }
            revealed = false
            // The metal surfaces just before the dots let go (assembly holds
            // until ~0.86 of its 1.5 s), so the emblem hands off seamlessly.
            try? await Task.sleep(for: .seconds(0.95))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { revealed = true }
        }
    }
}
