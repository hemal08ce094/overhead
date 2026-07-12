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
    static func points(for medal: Medal, cap: Int = 980) -> [CGPoint] {
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
        for i in 0..<140 {
            let a = Double(i) / 140 * 2 * .pi
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
    /// Must match the MedalView3D underneath: sets where its engraved face
    /// lands on screen, so the particle emblem forms exactly in register.
    var cameraDistance: Float = 2.8
    var duration: Double = 1.65

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Anchors t=0 to the FIRST FRAME the timeline actually delivers, not to
    /// view creation: a medal's first-ever open pays for SceneKit scene build
    /// + two Sobel normal maps on the main thread, and a clock started before
    /// that hitch would skip straight past the swirl-in. Reference type so
    /// recording the anchor inside Canvas doesn't dirty SwiftUI state.
    private final class Clock { var start: Date? }
    @State private var clock = Clock()

    var body: some View {
        if !reduceMotion {
            let targets = EmblemPoints.points(for: medal)
            let tint = MedalArt.colors(medal.finish).thumbLight
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    let start = clock.start ?? timeline.date
                    if clock.start == nil { clock.start = timeline.date }
                    let p = timeline.date.timeIntervalSince(start) / duration
                    // The slowest-staggered dot finishes its release at 1.18.
                    guard p < 1.20 else { return }
                    let side = min(size.width, size.height)
                    let cx = size.width / 2, cy = size.height / 2
                    // Project the medal face onto the screen so the particle
                    // emblem lands exactly on the engraving underneath: the
                    // disc's cap (radius 0.97, front face at z 0.07) through
                    // SceneKit's default 60° vertical FOV at cameraDistance.
                    // The emblem texture spans the cap's bounding square.
                    let viewPlane = 2 * tan(Double.pi / 6) * Double(cameraDistance - 0.07)
                    let span = size.height * (2 * 0.97) / viewPlane

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

                        // Release: while the metal fades up beneath, each dot
                        // loosens on its own stagger, drifts a touch outward
                        // and dims along a smoothstep — a hand-off through a
                        // long cross-dissolve, never a cut.
                        let rel = min(max((p - 0.72 - r0 * 0.10) / 0.36, 0), 1)
                        let relE = rel * rel * (3 - 2 * rel)

                        // Swirl in: born far out on a rotated angle, spiral
                        // decays onto the target. Alternate handedness.
                        let swirl = (1.4 + r1 * 1.6) * (i % 2 == 0 ? 1 : -1)
                        let born = side * (0.55 + r2 * 0.45)
                        let radius = tRadius + (born - tRadius) * (1 - e)
                                   + relE * (5 + r1 * 11)
                        let angle = tAngle + swirl * (1 - e)
                        // Formed dots breathe just a little, like the sky —
                        // stilling as they let go.
                        let shimmer = e * (1 - relE)
                            * sin(timeline.date.timeIntervalSinceReferenceDate * (1.5 + r3) + r1 * 6.28)
                        let x = cx + cos(angle) * radius + shimmer
                        let y = cy + sin(angle) * radius + shimmer * 0.6

                        // In fast, out slow — the smoothstep has no hard edge
                        // at either end of the dissolve.
                        let a = min(u * 4, 1) * (0.35 + 0.55 * r3) * (1 - relE)

                        let spark = i % 5 == 0
                        let s = (spark ? 1.5 : 1.1) + r2 * 1.8
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
    @State private var spinning = false
    @State private var finished = false

    var body: some View {
        ZStack {
            // Held face-on and still while the dots melt onto the engraving —
            // no scale, no rotation, so the two emblems stay in register.
            // The reveal spin fires only after the hand-off.
            MedalView3D(medal: medal, award: award,
                        cameraDistance: cameraDistance, hero: hero, locked: locked,
                        spinning: spinning)
                .opacity(revealed ? 1 : 0)
            if !finished {
                MedalAssembly(medal: medal, cameraDistance: cameraDistance)
            }
        }
        .task {
            // .task re-fires every time the view re-appears (pop back from a
            // push, scroll return). The strike plays once per identity; a run
            // interrupted mid-flight settles straight to the final state so
            // nothing replays against an expired particle clock.
            guard !finished else { return }
            guard !reduceMotion else { revealed = true; spinning = true; finished = true; return }
            // The strike: dots form the emblem, the still, face-on metal
            // rises beneath them exactly in register (release runs 0.72–1.18
            // of the 1.65 s assembly), the dots melt into the engraving —
            // and only then does the medal come alive with its reveal spin.
            try? await Task.sleep(for: .seconds(1.05))
            guard !Task.isCancelled else { revealed = true; spinning = true; finished = true; return }
            withAnimation(.easeInOut(duration: 0.8)) { revealed = true }
            // Last dot fades at 1.20 × 1.65 s; spin on its heels, then drop
            // the overlay so its TimelineView stops ticking — the medal page
            // is a place people linger (drag to spin), and an empty canvas
            // re-evaluated at 120 Hz is pure battery burn.
            try? await Task.sleep(for: .seconds(0.95))
            spinning = true
            finished = true
        }
    }
}
