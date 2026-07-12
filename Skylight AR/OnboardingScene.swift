//
//  OnboardingScene.swift
//  Skylight AR
//
//  The living canvas behind onboarding — one continuous night, not slides.
//  A single airliner flies through all three acts: it enters under the stars
//  (the promise), a bearing line pins it to your place as the horizon rises
//  (location), and a viewfinder irises open and locks it with a reticle
//  (camera). Advancing doesn't swap pictures; the camera of the scene moves.
//  Everything is a pure function of (time, act-progress) in the app's
//  particle discipline: no per-frame state, no allocations, no assets.
//

import SwiftUI

struct OnboardingScene: View {
    /// Which beat the copy is on (0, 1, 2). The scene eases toward it.
    var act: Int
    /// Set when onboarding finishes: the night dissolves into star-motes.
    var finaleStart: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The act transition: `u` eases from `fromAct` toward `act` over 0.9 s.
    // Plain vars updated on act change; per-frame reads are pure.
    @State private var fromAct: Double = 0
    @State private var actChangedAt = Date.distantPast

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion && finaleStart == nil)) { tl in
            let now = tl.date
            let t = reduceMotion ? 7.0 : now.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let raw = reduceMotion ? 1
                    : min(1, now.timeIntervalSince(actChangedAt) / 0.9)
                let eased = 1 - pow(1 - raw, 3)
                let u = fromAct + (Double(act) - fromAct) * eased
                let finale = finaleStart.map { min(1, now.timeIntervalSince($0) / 0.8) } ?? 0
                draw(ctx, size, t: t, u: u, finale: finale)
            }
        }
        .onChange(of: act) { old, _ in
            // Capture where the eased value actually is, so a fast tap
            // mid-transition doesn't jump.
            let raw = min(1, Date().timeIntervalSince(actChangedAt) / 0.9)
            let eased = 1 - pow(1 - raw, 3)
            fromAct = fromAct + (Double(old) - fromAct) * eased
            actChangedAt = Date()
        }
        .onAppear { fromAct = Double(act); actChangedAt = .distantPast }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: The night, drawn

    private func hash(_ i: Int) -> (Double, Double, Double, Double) {
        var h = UInt64(i) &* 0x9E3779B97F4A7C15
        func rnd() -> Double {
            h ^= h >> 12; h ^= h << 25; h ^= h >> 27
            return Double((h &* 2685821657736338717) >> 40) / Double(1 << 24)
        }
        return (rnd(), rnd(), rnd(), rnd())
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize,
                      t: Double, u: Double, finale: Double) {
        let w = size.width, h = size.height
        let u1 = min(max(u, 0), 1)           // act 0 → 1: the horizon rises
        let u2 = min(max(u - 1, 0), 1)       // act 1 → 2: the viewfinder opens
        let live = 1 - finale                // the finale dims the whole night

        // ---- Stars: two parallax layers, breathing at full spectacle.
        for layer in 0..<2 {
            let lift = CGFloat(u1) * h * (layer == 0 ? 0.10 : 0.22)
            for i in 0..<(layer == 0 ? 46 : 40) {
                let (r0, r1, r2, r3) = hash(i + layer * 977)
                let x = r0 * w
                var y = (r1 * 1.15).truncatingRemainder(dividingBy: 1.15) * h - lift
                y = y < -8 ? y + h * 1.15 : y
                let tw = 0.55 + 0.45 * sin(t * (0.4 + r2 * 0.9) + r3 * 6.28)
                let s = 0.8 + r2 * 2.0 + (r3 > 0.93 ? 1.2 : 0)
                ctx.fill(Path(ellipseIn: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)),
                         with: .color(Color(red: 0.86, green: 0.90, blue: 1.0)
                            .opacity((0.35 + 0.6 * tw) * live)))
            }
        }

        // ---- Aurora: soft indigo-teal curtains breathing above the horizon.
        if u1 > 0.02 {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 18))
                for i in 0..<3 {
                    let (r0, r1, _, _) = hash(300 + i)
                    let cx = w * (0.18 + 0.32 * Double(i)) + sin(t * 0.07 + r0 * 6.28) * w * 0.06
                    let breathe = 0.5 + 0.5 * sin(t * 0.16 + r1 * 6.28)
                    let top = h * (0.30 + 0.08 * Double(i))
                    let rect = CGRect(x: cx - w * 0.10, y: top, width: w * 0.20, height: h * 0.34)
                    layer.fill(Path(roundedRect: rect, cornerRadius: w * 0.10),
                               with: .linearGradient(
                                Gradient(colors: [.clear,
                                                  Color(red: 0.30, green: 0.75, blue: 0.72)
                                                    .opacity((0.05 + 0.09 * breathe) * u1 * live)]),
                                startPoint: CGPoint(x: cx, y: rect.minY),
                                endPoint: CGPoint(x: cx, y: rect.maxY)))
                }
            }
        }

        // ---- The plane: one airliner, the whole way through. In act 3 it
        // banks into a slow circuit INSIDE the viewfinder, so the reticle
        // locks something that's really there.
        let loop = (t / 17).truncatingRemainder(dividingBy: 1)
        let freeX = w * (-0.12 + 1.24 * loop)
        let freeY = h * (0.175 + 0.035 * sin(loop * .pi * 2 + 1.3)) - CGFloat(u1) * h * 0.015
        let apCenter = CGPoint(x: w * 0.5, y: h * 0.185)
        let inApX = apCenter.x + CGFloat(sin(t * 0.35)) * w * 0.20
        let inApY = apCenter.y + 10 + CGFloat(sin(t * 0.8)) * 7
        let blend = CGFloat(u2 * u2 * (3 - 2 * u2))
        let plane = CGPoint(x: freeX * (1 - blend) + inApX * blend,
                            y: freeY * (1 - blend) + inApY * blend)
        let heading = Double(blend) * atan2(cos(t * 0.8) * 5.6, cos(t * 0.35) * Double(w) * 0.07)

        // Contrail with glints (the free-flight trail; it hands off to the
        // viewfinder circuit as act 3 arrives).
        for k in 1...16 {
            let uu = loop - Double(k) * 0.011
            guard uu > -0.1 else { break }
            let cxp = w * (-0.12 + 1.24 * uu)
            let cyp = h * (0.175 + 0.035 * sin(uu * .pi * 2 + 1.3)) - CGFloat(u1) * h * 0.015
            let fade = (1 - Double(k) / 16)
            let s = 1.0 + CGFloat(k) * 0.16
            ctx.fill(Path(ellipseIn: CGRect(x: cxp - s / 2, y: cyp - s / 2, width: s, height: s)),
                     with: .color(.white.opacity(0.38 * fade * live * (1 - Double(blend)))))
        }
        // A glint flares off the fuselage every few seconds.
        let glint = max(0, sin(t * 0.9))
        if glint > 0.94 {
            let g = (glint - 0.94) / 0.06
            var gl = ctx; gl.opacity = g * 0.9 * live
            for len in [CGFloat(9), 4.5] {
                var p = Path()
                p.move(to: CGPoint(x: plane.x - len, y: plane.y)); p.addLine(to: CGPoint(x: plane.x + len, y: plane.y))
                p.move(to: CGPoint(x: plane.x, y: plane.y - len)); p.addLine(to: CGPoint(x: plane.x, y: plane.y + len))
                gl.stroke(p, with: .color(.white), lineWidth: len > 5 ? 1.4 : 1.0)
            }
        }
        var resolved = ctx.resolve(Image(systemName: "airplane"))
        resolved.shading = .color(Color(red: 1.0, green: 0.86, blue: 0.55).opacity(live))
        ctx.drawLayer { layer in
            layer.translateBy(x: plane.x, y: plane.y)
            layer.rotate(by: .radians(heading))
            layer.addFilter(.shadow(color: Color(red: 1.0, green: 0.8, blue: 0.4).opacity(0.6 * live), radius: 6))
            layer.draw(resolved, in: CGRect(x: -11, y: -11, width: 22, height: 22))
        }

        // ---- Act 2: the ground arrives — curved horizon, you, pulse rings.
        if u1 > 0.01 {
            let obs = CGPoint(x: w * 0.5, y: h * (1.44 - 0.49 * CGFloat(u1)))
            let alpha = u1 * live

            // Ground bloom below the horizon.
            ctx.fill(Path(CGRect(x: 0, y: obs.y - 2, width: w, height: h - obs.y + 2)),
                     with: .linearGradient(Gradient(colors: [Theme.indigo.opacity(0.34 * alpha), .clear]),
                                           startPoint: CGPoint(x: 0, y: obs.y),
                                           endPoint: CGPoint(x: 0, y: h)))
            let horizonR = w * 1.5
            var horizon = Path()
            horizon.addArc(center: CGPoint(x: w * 0.5, y: obs.y + horizonR - 4), radius: horizonR,
                           startAngle: .degrees(252), endAngle: .degrees(288), clockwise: false)
            ctx.stroke(horizon, with: .color(Theme.accent.opacity(0.5 * alpha)), lineWidth: 1.4)

            // Pulse rings, generous at full spectacle.
            for i in 0..<4 {
                let ph = ((t * 0.55 + Double(i) * 0.35).truncatingRemainder(dividingBy: 1.4)) / 1.4
                let e = 1 - pow(1 - ph, 3)
                var rc = ctx; rc.opacity = (1 - ph) * 0.55 * alpha
                let rr = CGFloat(e) * w * 0.46
                rc.stroke(Path(ellipseIn: CGRect(x: obs.x - rr, y: obs.y - rr * 0.30,
                                                 width: rr * 2, height: rr * 0.60)),
                          with: .color(Theme.accent), lineWidth: 1.3)
            }

            // The dashed bearing line: the plane, pinned to YOUR sky.
            var bl = ctx; bl.opacity = 0.4 * alpha * (1 - u2)
            var lp = Path(); lp.move(to: obs); lp.addLine(to: plane)
            bl.stroke(lp, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))

            // You: beam, glow, dot.
            var beam = ctx; beam.opacity = 0.6 * alpha
            beam.fill(Path(CGRect(x: obs.x - 1.2, y: obs.y - 40, width: 2.4, height: 40)),
                      with: .linearGradient(Gradient(colors: [.clear, Theme.accent.opacity(0.7)]),
                                            startPoint: CGPoint(x: 0, y: obs.y - 40),
                                            endPoint: CGPoint(x: 0, y: obs.y)))
            ctx.fill(Path(ellipseIn: CGRect(x: obs.x - 13, y: obs.y - 13, width: 26, height: 26)),
                     with: .radialGradient(Gradient(colors: [Theme.accent.opacity(0.55 * alpha), .clear]),
                                           center: obs, startRadius: 1, endRadius: 13))
            ctx.fill(Path(ellipseIn: CGRect(x: obs.x - 4.6, y: obs.y - 4.6, width: 9.2, height: 9.2)),
                     with: .color(.white.opacity(alpha)))
            ctx.fill(Path(ellipseIn: CGRect(x: obs.x - 2.4, y: obs.y - 2.4, width: 4.8, height: 4.8)),
                     with: .color(Theme.accent.opacity(alpha)))
        }

        // ---- Act 3: the viewfinder irises open and LOCKS the plane.
        if u2 > 0.01 {
            let iris = 1 - pow(1 - u2, 3)
            let ap = CGRect(x: w * 0.5 - w * 0.40 * iris,
                            y: h * 0.185 - h * 0.135 * iris,
                            width: w * 0.80 * iris, height: h * 0.27 * iris)
            let frame = Path(roundedRect: ap, cornerRadius: 18, style: .continuous)

            // Outside the glass, the night dims — inside stays vivid.
            var dim = Path(CGRect(origin: .zero, size: size))
            dim.addPath(frame)
            ctx.fill(dim, with: .color(.black.opacity(0.42 * u2 * live)), style: FillStyle(eoFill: true))

            ctx.stroke(frame, with: .color(.white.opacity(0.55 * u2 * live)), lineWidth: 1.6)
            // Dynamic-island pill: it's a phone you're looking through.
            ctx.fill(Path(roundedRect: CGRect(x: ap.midX - 16, y: ap.minY + 9, width: 32, height: 8),
                          cornerRadius: 4),
                     with: .color(.black.opacity(0.7 * u2 * live)))

            // The reticle flies in from the aperture corners and snaps to the
            // plane — your first spot, made for you.
            let q = min(max((u2 - 0.35) / 0.55, 0), 1)
            let snap = 1 - pow(1 - q, 3)
            let half = (ap.width * 0.5) * (1 - snap) + 22 * snap
            let tick = 10 + 8 * (1 - snap)
            let target = CGPoint(x: min(max(plane.x, ap.minX + 40), ap.maxX - 40),
                                 y: min(max(plane.y, ap.minY + 30), ap.maxY - 30))
            let c = CGPoint(x: ap.midX * (1 - snap) + target.x * snap,
                            y: ap.midY * (1 - snap) + target.y * snap)
            var ret = ctx; ret.opacity = Double(u2) * live * (0.35 + 0.65 * Double(snap))
            for sx in [-1.0, 1.0] {
                for sy in [-1.0, 1.0] {
                    let corner = CGPoint(x: c.x + sx * half, y: c.y + sy * half)
                    var p = Path()
                    p.move(to: CGPoint(x: corner.x - sx * tick, y: corner.y))
                    p.addLine(to: corner)
                    p.addLine(to: CGPoint(x: corner.x, y: corner.y - sy * tick))
                    ret.stroke(p, with: .color(Theme.gold), lineWidth: 1.8)
                }
            }
            // Locked: the callsign chip fades up under the catch.
            if q > 0.9 {
                let a = Double((q - 0.9) / 0.1) * live
                let text = ctx.resolve(Text(verbatim: "EK203 · A380 → DXB")
                    .font(Theme.display(10, .semibold)).foregroundColor(.white))
                let ts = text.measure(in: CGSize(width: 220, height: 40))
                let chip = CGRect(x: c.x - ts.width / 2 - 9, y: c.y + half + 10,
                                  width: ts.width + 18, height: ts.height + 8)
                ctx.fill(Path(roundedRect: chip, cornerRadius: chip.height / 2),
                         with: .color(.black.opacity(0.6 * a)))
                ctx.stroke(Path(roundedRect: chip, cornerRadius: chip.height / 2),
                           with: .color(Theme.gold.opacity(0.5 * a)), lineWidth: 1)
                var tc = ctx; tc.opacity = a
                tc.draw(text, at: CGPoint(x: chip.midX, y: chip.midY))
            }
        }

        // ---- Finale: the night lets go — a full-screen swirl of star-motes
        // as the real sky arrives beneath.
        if finale > 0, let start = finaleStart {
            let p = min(1, Date().timeIntervalSince(start) / 0.8)
            for i in 0..<150 {
                let (r0, r1, r2, r3) = hash(9000 + i)
                let delay = r0 * 0.3
                let uu = min(max((p - delay) / (1 - delay), 0), 1)
                let e = 1 - pow(1 - uu, 2.2)
                let bx = r1 * w, by = r2 * h
                let ang = -.pi / 2 + (r3 - 0.5) * 2.4
                let x = bx + cos(ang) * e * (60 + r2 * 140)
                let y = by + sin(ang) * e * (60 + r1 * 140)
                let a = sin(.pi * uu) * (0.35 + 0.5 * r3)
                let s = (i % 5 == 0 ? 1.8 : 1.2) + r2 * 1.8
                ctx.fill(Path(ellipseIn: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)),
                         with: .color((i % 5 == 0 ? Color.white : Theme.gold).opacity(a)))
            }
        }
    }
}
