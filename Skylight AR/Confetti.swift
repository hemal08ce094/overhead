//
//  Confetti.swift
//  Skylight AR
//
//  A one-shot confetti blast for the moment a medal unlocks. Pure Canvas — a
//  couple of hundred rotating paper pieces launched up and out from a point,
//  pulled back down by gravity, spinning and fading as they fall. Deterministic
//  per trigger (seeded), self-stopping after a few seconds, and silent under
//  Reduce Motion.
//

import SwiftUI

struct ConfettiBurst: View {
    /// Changing this restarts the blast (pass the medal id).
    var seed: String
    /// The winning medal's metal, folded into the paper palette.
    var accent: Color = Theme.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var done = false

    private let duration: Double = 2.6
    private let pieces: [ConfettiPiece]
    private let palette: [Color]

    init(seed: String, accent: Color = Theme.accent) {
        self.seed = seed
        self.accent = accent
        var rng = ConfettiRNG(seed: seed)
        pieces = (0..<120).map { _ in ConfettiPiece(rng: &rng) }
        palette = [accent, Theme.gold, .white,
                   Color(red: 1.00, green: 0.45, blue: 0.62),
                   Color(red: 0.45, green: 0.90, blue: 0.75),
                   Color(red: 0.55, green: 0.72, blue: 1.00),
                   Color(red: 1.00, green: 0.82, blue: 0.38)]
    }

    var body: some View {
        Group {
            if reduceMotion || done {
                Color.clear
            } else {
                TimelineView(.animation) { tl in
                    Canvas { ctx, size in
                        guard let start else { return }
                        let t = tl.date.timeIntervalSince(start)
                        guard t <= duration else { return }
                        draw(ctx, size, t)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            start = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) { done = true }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        // Launch point sits behind the award banner, up top.
        let origin = CGPoint(x: size.width * 0.5, y: size.height * 0.30)
        let gravity = 780.0
        let fadeStart = duration - 0.7

        for p in pieces {
            let vx = cos(p.angle) * p.speed
            let vy = sin(p.angle) * p.speed
            let x = origin.x + vx * t + sin(t * p.wobbleFreq + p.phase) * p.wobbleAmp
            let y = origin.y + vy * t + 0.5 * gravity * t * t
            guard y < size.height + 40 else { continue }

            let fade = t > fadeStart ? max(0, (duration - t) / 0.7) : 1
            let rot = p.spin0 + p.spinSpeed * t
            let w = CGFloat(p.size), h = CGFloat(p.size * p.ar)
            let color = palette[p.colorIndex % palette.count]

            var layer = ctx
            layer.opacity = fade
            layer.translateBy(x: x, y: y)
            layer.rotate(by: .radians(rot))
            // A thin foil sheen: brighter top half, darker bottom, sold as one strip.
            layer.fill(Path(CGRect(x: -w / 2, y: -h / 2, width: w, height: h)),
                       with: .linearGradient(Gradient(colors: [color, color.opacity(0.72)]),
                                             startPoint: CGPoint(x: 0, y: -h / 2),
                                             endPoint: CGPoint(x: 0, y: h / 2)))
        }
    }
}

private struct ConfettiPiece {
    let angle: Double        // radians; upper hemisphere (y is down, so negative)
    let speed: Double
    let size: Double
    let ar: Double           // aspect ratio h/w
    let colorIndex: Int
    let spin0: Double
    let spinSpeed: Double
    let wobbleAmp: Double
    let wobbleFreq: Double
    let phase: Double

    init<R: RandomNumberGenerator>(rng: inout R) {
        angle = -Double.pi * Double.random(in: 0.12...0.88, using: &rng)   // up-and-out fan
        speed = Double.random(in: 260...650, using: &rng)
        size = Double.random(in: 6...11, using: &rng)
        ar = Double.random(in: 0.4...1.2, using: &rng)
        colorIndex = Int.random(in: 0...9_999, using: &rng)
        spin0 = Double.random(in: 0...(2 * .pi), using: &rng)
        spinSpeed = Double.random(in: -6...6, using: &rng)
        wobbleAmp = Double.random(in: 0...18, using: &rng)
        wobbleFreq = Double.random(in: 2...5, using: &rng)
        phase = Double.random(in: 0...(2 * .pi), using: &rng)
    }
}

/// Tiny seeded xorshift so the same medal always bursts the same way.
private struct ConfettiRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: String) {
        var h: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        state = h == 0 ? 0x9E3779B97F4A7C15 : h
    }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
