//
//  LaunchIntro.swift
//  Skylight AR
//
//  The cold-launch entrance, for launches that already onboarded: totality.
//  Stars gather in a darkened sky, the eclipsed sun blooms — black moon disc
//  inside a breathing corona — and an airliner silhouette crosses the disc
//  trailing twin contrails. Mid-transit the reticle locks it and the label
//  pops: the app's whole promise in one drawn shot. Original artwork, all
//  Canvas, in the OnboardingScene discipline (pure function of time).
//  Doubles as a mask for AR session warm-up, which runs beneath it from
//  frame one. Total ~3 s, any tap skips, reduced motion shows the settled
//  frame and fades.
//
//  When the last known location is fresh enough, the label names a REAL
//  flight overhead (same FallbackSource chain as the sky), on a hard budget:
//  if the network hasn't answered before the lock, the scripted QTR649 beat
//  plays — the choreography is never delayed.
//

import SwiftUI

struct LaunchIntroView: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var start = Date()
    /// When the dissolve begins. A tap pulls it to "now".
    @State private var fadeAt = Date.distantFuture
    /// Live label text, if the fetch beat the choreography to it.
    @State private var liveLabel: String?

    /// Choreography (seconds from start): stars, eclipse bloom, the crossing
    /// (1.05→2.15 through the disc), lock, label, brand, dissolve.
    private static let eclipseAt = 0.4, transitFrom = 1.05, transitLen = 1.1,
                       lockAt = 1.4, chipAt = 1.6, fadeStart = 2.5, fadeLen = 0.5
    /// Reduced motion freezes here: plane on the disc, lock + label pinned.
    private static let settledT = 1.75

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in
            let now = tl.date
            let t = reduceMotion ? Self.settledT : now.timeIntervalSince(start)
            let fadesFrom = min(fadeAt, start.addingTimeInterval(
                reduceMotion ? 0.9 : Self.fadeStart))
            let fade = ramp(now.timeIntervalSince(fadesFrom) / Self.fadeLen)

            ZStack {
                Canvas { ctx, size in
                    draw(ctx, size, t: t)
                }
                VStack(spacing: 10) {
                    Text(verbatim: "OVERHEAD")
                        .font(Theme.display(14, .semibold))
                        .kerning(6)
                        .foregroundStyle(.white.opacity(0.8 * ramp((t - 0.8) / 0.5)))
                    Text("Everything above you, labeled.")
                        .font(Theme.display(13, .medium))
                        .foregroundStyle(.white.opacity(0.45 * ramp((t - 1.1) / 0.5)))
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 76)
            }
            .background(Theme.nightBottom)
            .opacity(1 - fade)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { fadeAt = min(fadeAt, Date()) }
        .accessibilityHidden(true)
        .task { await resolveLiveFlight() }
        .task(id: fadeAt) {
            let end = min(fadeAt, start.addingTimeInterval(
                reduceMotion ? 0.9 : Self.fadeStart)).addingTimeInterval(Self.fadeLen)
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow) + 0.05))
            onFinished()
        }
    }

    // MARK: The entrance, drawn

    /// 0→1 with a strong ease-out; the intro's only curve.
    private func ramp(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return 1 - pow(1 - c, 3)
    }

    private func hash(_ i: Int) -> (Double, Double, Double, Double) {
        var h = UInt64(i) &* 0x9E3779B97F4A7C15
        func rnd() -> Double {
            h ^= h >> 12; h ^= h << 25; h ^= h >> 27
            return Double((h &* 2685821657736338717) >> 40) / Double(1 << 24)
        }
        return (rnd(), rnd(), rnd(), rnd())
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let w = size.width, h = size.height
        drawStars(ctx, w, h, t: t)

        let center = CGPoint(x: w * 0.5, y: h * 0.30)
        let r = min(w, h) * 0.155
        drawEclipse(ctx, center: center, r: r, t: t)

        // The crossing: through the disc's heart on a shallow descent, the
        // silhouette a real long-lens scale against the corona.
        let heading = -0.245   // radians; the classic tilted lane
        let dir = CGPoint(x: cos(heading), y: sin(heading))
        let u = (t - Self.transitFrom) / Self.transitLen
        if u > -0.05, u < 1.1 {
            let along = (u - 0.5) * 3.4 * r
            let p = CGPoint(x: center.x + dir.x * along, y: center.y + dir.y * along)
            let visible = min(ramp((u + 0.05) / 0.12), ramp((1.1 - u) / 0.12))
            drawPlane(ctx, at: p, heading: heading, span: r * 1.35, alpha: visible)
            drawLock(ctx, at: p, t: t)
        }
        drawChip(ctx, w, at: CGPoint(x: center.x, y: center.y + r + 40), t: t)
    }

    /// Totality sky: stars out in daytime, milkier near the corona's glow.
    private func drawStars(_ ctx: GraphicsContext, _ w: CGFloat, _ h: CGFloat, t: Double) {
        for i in 0..<80 {
            let (r0, r1, r2, r3) = hash(i)
            let entered = ramp((t - r0 * 0.45) / 0.45)
            guard entered > 0 else { continue }
            let twinkle = 0.7 + 0.3 * sin(t * (0.4 + r2 * 0.9) + r3 * 6.28)
            let s = 0.8 + r2 * 1.6 + (r3 > 0.94 ? 1.0 : 0)
            ctx.fill(Path(ellipseIn: CGRect(x: r0 * w - s / 2, y: r1 * h - s / 2,
                                            width: s, height: s)),
                     with: .color(Color(red: 0.86, green: 0.90, blue: 1.0)
                        .opacity((0.18 + 0.42 * r2) * entered * twinkle)))
        }
    }

    /// The eclipsed sun, built the way totality actually looks: a hard bright
    /// inner corona hugging the limb, then ~110 fine filamentary strands —
    /// long streamers fanning out along the solar equator, short brushy
    /// plumes at the poles — each shimmering slightly out of phase. No
    /// uniform halo anywhere; the shape comes from the strands.
    private func drawEclipse(_ ctx: GraphicsContext, center: CGPoint, r: CGFloat, t: Double) {
        let bloom = ramp((t - Self.eclipseAt) / 0.6)
        guard bloom > 0 else { return }
        let tilt = -0.35   // solar equator's lean across the frame

        // Filaments, twice: once softly blurred for the glow body, once thin
        // and faint on top for the crisp strand texture photographs show.
        for pass in 0..<2 {
            ctx.drawLayer { layer in
                if pass == 0 { layer.addFilter(.blur(radius: 3.5)) }
                for i in 0..<110 {
                    let (r0, r1, r2, r3) = hash(600 + i)
                    let ang = r0 * 2 * .pi
                    // How equatorial this strand is decides how far it reaches.
                    let equat = pow(abs(cos(ang - tilt)), 2.4)
                    let len = r * (0.30 + 0.45 * r1 + equat * (1.0 + 1.9 * r2))
                    // Polar plumes splay outward a touch, like field lines.
                    let splay = (1 - equat) * (r3 - 0.5) * 0.35
                    let a0 = ang, a1 = ang + splay
                    let p0 = CGPoint(x: center.x + cos(a0) * r * 1.01,
                                     y: center.y + sin(a0) * r * 1.01)
                    let p1 = CGPoint(x: center.x + cos(a1) * (r + len),
                                     y: center.y + sin(a1) * (r + len))
                    let shimmer = 0.8 + 0.2 * sin(t * (0.15 + r1 * 0.4) + r3 * 6.28)
                    let alpha = (pass == 0 ? 0.10 : 0.05)
                        * (0.5 + r3 * 0.9) * (0.45 + equat) * bloom * shimmer
                    var strand = Path()
                    strand.move(to: p0)
                    strand.addLine(to: p1)
                    layer.stroke(strand, with: .linearGradient(
                        Gradient(colors: [Color(red: 0.99, green: 0.97, blue: 0.93).opacity(alpha),
                                          .clear]),
                        startPoint: p0, endPoint: p1),
                        style: StrokeStyle(lineWidth: pass == 0 ? 1.6 + r2 * 1.4 : 0.7,
                                           lineCap: .round))
                }
            }
        }

        // Inner corona: the blinding collar right against the limb — bright,
        // tight, and falling off fast. This is what sells the exposure.
        let collar = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: Color(red: 1.0, green: 0.99, blue: 0.96).opacity(0.92 * bloom), location: 0.385),
            .init(color: Color(red: 1.0, green: 0.96, blue: 0.86).opacity(0.42 * bloom), location: 0.52),
            .init(color: Color(red: 0.98, green: 0.90, blue: 0.72).opacity(0.10 * bloom), location: 0.75),
            .init(color: .clear, location: 1.0),
        ])
        let cr = r * 2.6
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - cr, y: center.y - cr,
                                        width: cr * 2, height: cr * 2)),
                 with: .radialGradient(collar, center: center, startRadius: 0, endRadius: cr))

        // The moon: near-nothing. Corona light scatters into the lens, so the
        // disc reads charcoal with glare creeping in from the limb — which is
        // exactly what lets a crossing silhouette stay visible against it.
        let disc = Gradient(stops: [
            .init(color: Color(red: 0.030, green: 0.028, blue: 0.026), location: 0.0),
            .init(color: Color(red: 0.055, green: 0.050, blue: 0.042), location: 0.78),
            .init(color: Color(red: 0.11, green: 0.095, blue: 0.075), location: 1.0),
        ])
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                        width: r * 2, height: r * 2)),
                 with: .radialGradient(disc, center: center, startRadius: 0, endRadius: r))

        // Chromosphere: a hairline of fire around the limb, two prominences.
        ctx.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                          width: r * 2, height: r * 2)),
                   with: .color(Color(red: 1.0, green: 0.90, blue: 0.70).opacity(0.9 * bloom)),
                   lineWidth: 1.2)
        for (i, ang) in [2.1, 5.4].enumerated() {
            let p = CGPoint(x: center.x + cos(ang) * r, y: center.y + sin(ang) * r)
            let s: CGFloat = i == 0 ? 3.2 : 2.4
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)),
                     with: .color(Color(red: 1.0, green: 0.45, blue: 0.30).opacity(0.8 * bloom)))
        }
    }

    /// The airliner, bottom view, drawn as the silhouette it really is against
    /// totality — swept wings, tailplane, two engines, twin contrails.
    private func drawPlane(_ ctx: GraphicsContext, at p: CGPoint, heading: Double,
                           span: CGFloat, alpha: Double) {
        guard alpha > 0 else { return }
        ctx.drawLayer { layer in
            layer.translateBy(x: p.x, y: p.y)
            layer.rotate(by: .radians(heading))
            layer.opacity = alpha
            let s = span   // local unit: 1 wingspan

            // Contrails first, so the airframe sits on top of them — four
            // threads, one per engine, the jumbo's signature.
            for side in [-1.0, 1.0] {
                for engineY in [0.14, 0.30] {
                    let y = CGFloat(side) * s * engineY
                    var trail = Path()
                    trail.move(to: CGPoint(x: -s * 0.30, y: y))
                    trail.addLine(to: CGPoint(x: -s * 1.9, y: y))
                    layer.stroke(trail, with: .linearGradient(
                        Gradient(colors: [Color(red: 0.10, green: 0.09, blue: 0.07).opacity(0.32),
                                          .clear]),
                        startPoint: CGPoint(x: -s * 0.30, y: y),
                        endPoint: CGPoint(x: -s * 1.9, y: y)),
                        style: StrokeStyle(lineWidth: s * 0.030, lineCap: .round))
                }
            }

            let ink = GraphicsContext.Shading.color(Color(red: 0.012, green: 0.010, blue: 0.008))
            // Corona light wraps the airframe's edge — a hairline of warm rim
            // keeps the shape readable even over the disc's darkest center.
            let rim = GraphicsContext.Shading.color(
                Color(red: 1.0, green: 0.88, blue: 0.62).opacity(0.28))
            // Fuselage: the jumbo's wide-body capsule, nose to the +x.
            let fuselage = Path(roundedRect: CGRect(x: -s * 0.50, y: -s * 0.048,
                                                    width: s * 1.04, height: s * 0.096),
                                cornerRadius: s * 0.048)
            layer.fill(fuselage, with: ink)
            layer.stroke(fuselage, with: rim, lineWidth: 0.6)
            // Wings swept back, engines slung beneath, tailplane at the rear.
            for side in [-1.0, 1.0] {
                var wing = Path()
                wing.move(to: CGPoint(x: s * 0.12, y: CGFloat(side) * s * 0.03))
                wing.addLine(to: CGPoint(x: -s * 0.16, y: CGFloat(side) * s * 0.50))
                wing.addLine(to: CGPoint(x: -s * 0.27, y: CGFloat(side) * s * 0.50))
                wing.addLine(to: CGPoint(x: -s * 0.09, y: CGFloat(side) * s * 0.03))
                wing.closeSubpath()
                layer.fill(wing, with: ink)
                layer.stroke(wing, with: rim, lineWidth: 0.6)
                // Four engines — inner pair and outer pair, following the sweep.
                for (engineY, engineX) in [(0.14, 0.05), (0.30, -0.07)] {
                    let engine = Path(roundedRect: CGRect(
                        x: s * CGFloat(engineX),
                        y: CGFloat(side) * s * CGFloat(engineY) - s * 0.026,
                        width: s * 0.14, height: s * 0.052),
                        cornerRadius: s * 0.026)
                    layer.fill(engine, with: ink)
                    layer.stroke(engine, with: rim, lineWidth: 0.6)
                }
                var tail = Path()
                tail.move(to: CGPoint(x: -s * 0.40, y: CGFloat(side) * s * 0.018))
                tail.addLine(to: CGPoint(x: -s * 0.52, y: CGFloat(side) * s * 0.19))
                tail.addLine(to: CGPoint(x: -s * 0.58, y: CGFloat(side) * s * 0.19))
                tail.addLine(to: CGPoint(x: -s * 0.50, y: CGFloat(side) * s * 0.018))
                tail.closeSubpath()
                layer.fill(tail, with: ink)
                layer.stroke(tail, with: rim, lineWidth: 0.6)
            }
        }
    }

    /// The lock: four gold corners fly in from wide and snap to the plane.
    private func drawLock(_ ctx: GraphicsContext, at c: CGPoint, t: Double) {
        let snap = ramp((t - Self.lockAt) / 0.3)
        guard snap > 0 else { return }
        let half = 74 * (1 - snap) + 34 * snap
        let tick = 10 + 7 * (1 - snap)
        var ret = ctx; ret.opacity = 0.35 + 0.65 * snap
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
    }

    /// The label: the party trick, steady beneath the disc while the plane
    /// races — a caption for the moment, not a chase.
    private func drawChip(_ ctx: GraphicsContext, _ w: CGFloat, at c: CGPoint, t: Double) {
        let pinned = ramp((t - Self.chipAt) / 0.2)
        guard pinned > 0 else { return }
        let text = ctx.resolve(Text(verbatim: liveLabel ?? "EK225 · A380 · DXB → SFO")
            .font(Theme.display(11, .semibold)).foregroundColor(.white))
        let ts = text.measure(in: CGSize(width: 260, height: 40))
        let chip = CGRect(x: min(max(c.x - ts.width / 2 - 10, 12), w - ts.width - 32),
                          y: c.y + (1 - pinned) * 5,
                          width: ts.width + 20, height: ts.height + 10)
        var cc = ctx; cc.opacity = pinned
        cc.fill(Path(roundedRect: chip, cornerRadius: chip.height / 2),
                with: .color(.black.opacity(0.6)))
        cc.stroke(Path(roundedRect: chip, cornerRadius: chip.height / 2),
                  with: .color(Theme.gold.opacity(0.5)), lineWidth: 1)
        cc.draw(text, at: CGPoint(x: chip.midX, y: chip.midY))
    }

    // MARK: The real sky, if it answers in time

    /// Fetch the nearest airborne flight at the last known location. Budgeted
    /// so it can only ever upgrade the label, never stall the entrance, and
    /// applied only before the label pops so the text never swaps mid-read.
    private func resolveLiveFlight() async {
        let d = UserDefaults.standard
        let lat = d.double(forKey: SkyDefaults.lastLat)
        let lon = d.double(forKey: SkyDefaults.lastLon)
        guard lat != 0 || lon != 0 else { return }
        let traffic = await withTaskGroup(of: [Aircraft]?.self) { group in
            group.addTask {
                try? await FallbackSource.freeFeeds().aircraft(lat: lat, lon: lon, radiusNm: 40)
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(900))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let cosLat = cos(lat * .pi / 180)
        guard Date().timeIntervalSince(start) < Self.chipAt - 0.05,
              let nearest = traffic?
                .filter({ !$0.onGround && $0.callsign?.isEmpty == false })
                .min(by: { a, b in
                    let da = pow(a.lat - lat, 2) + pow((a.lon - lon) * cosLat, 2)
                    let db = pow(b.lat - lat, 2) + pow((b.lon - lon) * cosLat, 2)
                    return da < db
                })
        else { return }
        if let ft = nearest.altGeom ?? nearest.altBaro {
            liveLabel = "\(nearest.callsign!) · \(Int(ft).formatted()) ft"
        } else {
            liveLabel = "\(nearest.callsign!) · overhead now"
        }
    }
}
