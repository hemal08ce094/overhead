//
//  StarDissolve.swift
//  Skylight AR
//
//  The "portrait dissolving into particles" effect, in Overhead's language:
//  a quiet, endless stream of star-motes breaking off an anchor's trailing
//  edge and drifting away, as if the medal were made of night sky. Pure
//  function of time — every particle's whole life is derived from its seed
//  and the clock, so there's no per-frame state, no allocations, and the
//  animation is identical on every appearance.
//

import SwiftUI

struct StarDissolve: View {
    /// Where particles are born, in the receiving view's coordinate space —
    /// typically a thin band hugging the subject's trailing edge.
    var emitter: CGRect
    /// Body color of the motes (pass the tier metal's light tint).
    var tint: Color
    var count: Int = 80

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // Still poetry, no motion: a faint fixed sprinkle.
            Canvas { ctx, _ in
                draw(in: &ctx, at: 0, frozen: true)
            }
            .allowsHitTesting(false)
        } else {
            // 30 fps is plenty for slow-drifting motes, and quarters the
            // redraw work — this runs on top of a live AR session.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { ctx, _ in
                    draw(in: &ctx, at: timeline.date.timeIntervalSinceReferenceDate, frozen: false)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func draw(in ctx: inout GraphicsContext, at t: TimeInterval, frozen: Bool) {
        for i in 0..<count {
            // Six stable pseudo-randoms per particle from one integer hash.
            var h = UInt64(i) &* 0x9E3779B97F4A7C15
            func rnd() -> Double {
                h ^= h >> 12; h ^= h << 25; h ^= h >> 27
                return Double((h &* 2685821657736338717) >> 40) / Double(1 << 24)
            }
            let r0 = rnd(), r1 = rnd(), r2 = rnd(), r3 = rnd(), r4 = rnd(), r5 = rnd()

            // Life: born at the emitter, gone ~a card-width later.
            let period = 3.5 + r0 * 4.5                       // 3.5–8 s per journey
            let life = frozen ? (0.2 + 0.6 * r1)              // frozen: mid-flight
                              : (t / period + r1).truncatingRemainder(dividingBy: 1)
            let travel = 50.0 + r2 * 130.0
            let x = emitter.minX + r4 * emitter.width + life * travel
            let sway = frozen ? 0 : sin(t * (0.5 + r5) + r3 * .pi * 2) * (3 + r5 * 5)
            let y = emitter.minY + r3 * emitter.height        // lane
                  + sway                                       // gentle bob
                  + life * (r4 - 0.5) * 26                     // slow scatter
            // Fade in fast, out slow; farther particles are dimmer.
            let alpha = sin(.pi * min(max(life, 0), 1)) * (0.22 + 0.55 * r5)

            let isSpark = i % 6 == 0                           // a few pure-white glints
            let size = (isSpark ? 1.0 : 1.2) + r2 * 1.9
            let rect = CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
            ctx.fill(Path(ellipseIn: rect),
                     with: .color((isSpark ? Color.white : tint).opacity(alpha)))
        }
    }
}
