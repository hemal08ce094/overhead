//
//  OnboardingView.swift
//  Skylight AR
//
//  First-run hero + permission priming. Three calm pages: welcome, location,
//  camera. Each primes the user before the system prompt so grant rates stay high.
//

import SwiftUI
import CoreLocation
import AVFoundation

struct OnboardingView: View {
    var permissions: PermissionsModel
    var onFinished: () -> Void

    @State private var page = {
        #if DEBUG
        if let p = ShotScreen.current?.onboardingPage { return p }
        #endif
        return 0
    }()
    @State private var appear = false

    var body: some View {
        ZStack {
            Theme.skyGradient.ignoresSafeArea()
            Starfield().ignoresSafeArea().opacity(0.9)
            MoonGlow().ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                content
                    .padding(.horizontal, 28)
                    .opacity(appear ? 1 : 0)
                    .offset(y: appear ? 0 : 16)
                Spacer(minLength: 0)
                PageDots(count: 5, index: page)
                    .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { animateIn() }
        // Advance automatically once a step's permission resolves.
        .onChange(of: permissions.location) { _, _ in
            if page == 1, permissions.location != .notDetermined { advance() }
        }
        // Camera resolved (granted or denied) — move on to the closing tips
        // rather than dropping the user straight into an un-primed sky.
        .onChange(of: permissions.camera) { _, _ in
            if page == 2, permissions.camera != .notDetermined { advance() }
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case 0: welcome
        case 1: locationStep
        case 2: cameraStep
        case 3: tierStep
        default: readyStep
        }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 22) {
            SkyVoyageHero()
            VStack(spacing: 10) {
                Text("Overhead")
                    .font(Theme.display(46, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Hold up your phone and see the planes,\nsun, moon and stars where they truly are.")
                    .font(Theme.display(16, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            Button("Begin") { advance() }
                .buttonStyle(PrimaryButtonStyle())
                .starLit()
                .padding(.top, 12)
                .padding(.horizontal, 24)
        }
    }

    private var locationStep: some View {
        // Once denied, requesting again is a no-op — route the primary action to
        // Settings and keep the skip as a way forward so nobody gets stuck here.
        PrimingCard(
            hero: LocationHero(),
            title: String(localized: "Your place under the sky"),
            message: String(localized: "Overhead uses your location to compute exactly where each aircraft and celestial object sits above you."),
            primary: permissions.locationDenied ? String(localized: "Open Settings") : String(localized: "Enable Location"),
            action: { permissions.locationDenied ? openSettings() : permissions.requestLocation() },
            skipTitle: permissions.locationDenied ? String(localized: "Continue with demo sky") : String(localized: "Not now"),
            skipAction: { advance() })
    }

    private var cameraStep: some View {
        // Same trap as location: a previously-denied camera makes the request
        // a silent no-op, so the primary routes to Settings instead.
        PrimingCard(
            hero: CameraHero(),
            title: String(localized: "See through to the real sky"),
            message: String(localized: "The camera lets Overhead place aircraft and stars onto the live sky in augmented reality. You can also use a low-power dark-sky mode."),
            primary: permissions.cameraDenied ? String(localized: "Open Settings") : String(localized: "Enable Camera"),
            action: {
                if permissions.cameraDenied { openSettings() }
                else { Task { await permissions.requestCamera() } }
            },
            skipTitle: String(localized: "Skip — use dark sky"),
            skipAction: { advance() })
    }

    // Tiers & medals: the sky remembers what you find. Three real rungs from
    // the catalog make the ladder concrete without listing all twelve.
    private var tierStep: some View {
        GlassCard {
            VStack(spacing: 18) {
                TierHero()
                    .frame(height: 172)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1))
                    .padding(.bottom, 2)
                Text("Every flight counts")
                    .font(Theme.display(24, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Each plane you spot climbs you through twelve tiers, every one struck as a medal. Find your standing in Profile.")
                    .font(Theme.display(15, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                VStack(spacing: 11) {
                    tierRung(MedalCatalog.tiers.first, detail: String(localized: "where everyone begins"))
                    tierRung(MedalCatalog.tiers.first { $0.finish == .silver },
                             detail: nil)
                    tierRung(MedalCatalog.tiers.last, detail: nil)
                }
                .padding(.horizontal, 6)
                Button("Continue") { advance() }
                    .buttonStyle(PrimaryButtonStyle())
                    .starLit()
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private func tierRung(_ tier: SpotterTier?, detail: String?) -> some View {
        if let tier {
            let c = MedalArt.colors(tier.finish)
            HStack(spacing: 12) {
                Circle()
                    .fill(RadialGradient(colors: [c.thumbLight, c.thumbDark],
                                         center: .init(x: 0.35, y: 0.3),
                                         startRadius: 1, endRadius: 16))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                Text(tier.name)
                    .font(Theme.display(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(detail ?? String(localized: "\(tier.threshold.formatted()) flights"))
                    .font(Theme.display(12, .regular).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // "Aiming the sky": the honest close — how to hold it, how to correct it,
    // and a plain caveat that this is a reference, not an instrument. Doubles as
    // a soft landing before the live sky instead of a cold hand-off.
    private var readyStep: some View {
        GlassCard {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.14)).frame(width: 66, height: 66)
                    Circle().strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1).frame(width: 66, height: 66)
                    Image(systemName: "scope")
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                VStack(spacing: 6) {
                    Text("Aiming the sky")
                        .font(Theme.display(24, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("A living reference — not a precision instrument.")
                        .font(Theme.display(14, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 13) {
                    tip("sun.max", String(localized: "Best outdoors under open sky. The compass gets pulled off inside airports and buildings, so the sky can sit rotated there."))
                    tip("hand.raised.fill", String(localized: "Hold up your phone and stand still, pointing it toward the sky."))
                    tip("scope", String(localized: "If a plane sits a little off, tap it — or the Sun — to snap north back into place."))
                    tip("info.circle", String(localized: "Positions come from public data and your compass, so treat it as a guide, not gospel."))
                }
                Button("Enter the sky") { finish() }
                    .buttonStyle(PrimaryButtonStyle())
                    .starLit()
                    .padding(.top, 2)
            }
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(text)
                .font(Theme.display(13.5, .regular))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Flow

    private func animateIn() {
        appear = false
        withAnimation(.easeOut(duration: 0.6)) { appear = true }
    }

    private func advance() {
        withAnimation(.easeOut(duration: 0.25)) { appear = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            page = min(page + 1, 4)
            animateIn()
        }
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.3)) { appear = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onFinished() }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Star-lit primary button

/// The onboarding CTA's signature: a small gold comet orbits the button's
/// rim — a bright head, a star-mote tail fading along the capsule edge, and
/// sparkles shed outward as it goes. Pure function of time (no state, no
/// allocations); Reduce Motion shows a still, faint sprinkle on the rim.
private struct CometRim: View {
    var tint: Color = Theme.gold
    var lap: Double = 3.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Canvas margin beyond the button, so glow and sparkles clear its edge.
    static let margin: CGFloat = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 1.7 : tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in draw(ctx, size, t, frozen: reduceMotion) }
        }
        .allowsHitTesting(false)
    }

    /// Point + outward normal at parameter u (0…1) around a capsule's rim.
    private func rim(_ u: CGFloat, _ rect: CGRect) -> (p: CGPoint, normal: CGFloat) {
        let r = rect.height / 2
        let straight = max(0, rect.width - rect.height)
        let cap = .pi * r
        let total = 2 * straight + 2 * cap
        var s = (u - floor(u)) * total

        if s < straight {                                    // top edge, →
            return (CGPoint(x: rect.minX + r + s, y: rect.minY), -.pi / 2)
        }
        s -= straight
        if s < cap {                                         // right cap
            let a = -CGFloat.pi / 2 + s / r
            let c = CGPoint(x: rect.maxX - r, y: rect.midY)
            return (CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r), a)
        }
        s -= cap
        if s < straight {                                    // bottom edge, ←
            return (CGPoint(x: rect.maxX - r - s, y: rect.maxY), .pi / 2)
        }
        s -= straight
        let a = CGFloat.pi / 2 + s / r                       // left cap
        let c = CGPoint(x: rect.minX + r, y: rect.midY)
        return (CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r), a)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, frozen: Bool) {
        let m = Self.margin
        let rect = CGRect(x: m, y: m, width: size.width - 2 * m, height: size.height - 2 * m)
        guard rect.width > rect.height, rect.height > 8 else { return }
        let headU = CGFloat((t / lap).truncatingRemainder(dividingBy: 1))

        // Tail: samples trailing the head along the rim, dimming and thinning.
        let tail = 34
        for k in 0..<tail {
            let f = 1 - Double(k) / Double(tail)             // 1 at head → 0
            let (p, _) = rim(headU - CGFloat(k) * 0.006, rect)
            let a = frozen ? 0.25 * f : pow(f, 1.5) * 0.95
            let s = 0.8 + 2.4 * f
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)),
                     with: .color((k < 3 ? Color.white : tint).opacity(a)))
        }

        guard !frozen else { return }

        // Head glow — the comet's coma.
        let (hp, _) = rim(headU, rect)
        ctx.fill(Path(ellipseIn: CGRect(x: hp.x - 9, y: hp.y - 9, width: 18, height: 18)),
                 with: .radialGradient(Gradient(colors: [tint.opacity(0.55), .clear]),
                                       center: hp, startRadius: 1, endRadius: 9))

        // Sparkles shed outward as it passes — born where the head WAS, then
        // drifting off the rim and fading. Whole life derived from the clock.
        for j in 0..<12 {
            var h = UInt64(j) &* 0x9E3779B97F4A7C15
            func rnd() -> Double {
                h ^= h >> 12; h ^= h << 25; h ^= h >> 27
                return Double((h &* 2685821657736338717) >> 40) / Double(1 << 24)
            }
            let r0 = rnd(), r1 = rnd(), r2 = rnd()
            let lifeDur = 0.9 + r0 * 0.8
            let life = ((t / lifeDur) + r1).truncatingRemainder(dividingBy: 1)
            // Where was the head when this sparkle was born?
            let birthU = CGFloat(((t - life * lifeDur) / lap).truncatingRemainder(dividingBy: 1))
            let (bp, n) = rim(birthU, rect)
            let dist = CGFloat(life) * (8 + CGFloat(r2) * 16)
            let p = CGPoint(x: bp.x + cos(n) * dist, y: bp.y + sin(n) * dist)
            let a = sin(.pi * life) * (0.35 + 0.45 * r2)
            let s = 1.0 + r0 * 1.6
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)),
                     with: .color((j % 3 == 0 ? Color.white : tint).opacity(a)))
        }
    }
}

extension View {
    /// The orbiting-comet rim on a primary control. Onboarding's "come this way".
    func starLit() -> some View {
        overlay { CometRim().padding(-CometRim.margin) }
    }
}

// MARK: - Priming card

private struct PrimingCard<Hero: View>: View {
    let hero: Hero
    let title: String
    let message: String
    let primary: String
    let action: () -> Void
    let skipTitle: String
    let skipAction: () -> Void

    var body: some View {
        GlassCard {
            VStack(spacing: 18) {
                hero
                    .frame(height: 172)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1))
                    .padding(.bottom, 2)
                Text(title)
                    .font(Theme.display(24, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(Theme.display(15, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                Button(primary, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .starLit()
                    .padding(.top, 4)
                Button(skipTitle, action: skipAction)
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }
}

// MARK: - Decorative marks

/// A crescent moon orb in liquid glass — the starfield refracts through the
/// glass while a soft lit limb and dark terminator shade the crescent inside.
struct MoonMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.moonlight.opacity(0.55),
                                              Theme.moonlight.opacity(0.08)],
                                     center: .topLeading, startRadius: 4, endRadius: 120))
            Circle()
                .fill(Theme.nightBottom.opacity(0.88))
                .offset(x: 22, y: -14)
                .blur(radius: 1)
                .mask(Circle())
        }
        .glassEffect(.clear.interactive(), in: .circle)
        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: Theme.moonlight.opacity(0.45), radius: 30)
    }
}

/// Big soft glow anchored toward the top of the screen.
struct MoonGlow: View {
    var body: some View {
        GeometryReader { geo in
            Circle()
                .fill(Theme.glow(Theme.indigo))
                .frame(width: geo.size.width * 1.3)
                .position(x: geo.size.width * 0.7, y: geo.size.height * 0.18)
                .blur(radius: 20)
        }
        .allowsHitTesting(false)
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Theme.accent : Theme.textTertiary)
                    .frame(width: i == index ? 22 : 7, height: 7)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: index)
            }
        }
    }
}

// MARK: - Onboarding hero graphics
//
// Pure-Canvas scenes for the permission-priming pages, in the same living-sky
// language as the rest of the app. LocationHero shows the app placing aircraft
// and celestial bodies around *you* at their true bearings; CameraHero shows the
// live sky being augmented through the phone. Both freeze to a still under
// Reduce Motion.

private struct OnbStar { let x: CGFloat, y: CGFloat, r: CGFloat; let phase: Double, speed: Double, base: Double }

private struct OnbRNG: RandomNumberGenerator {
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

private func onbStars(seed: UInt64, count: Int, maxY: CGFloat = 1) -> [OnbStar] {
    var rng = OnbRNG(seed: seed)
    return (0..<count).map { _ in
        OnbStar(x: .random(in: 0...1, using: &rng), y: .random(in: 0...maxY, using: &rng),
                r: .random(in: 0.4...1.4, using: &rng), phase: .random(in: 0...(2 * .pi), using: &rng),
                speed: .random(in: 0.3...1.0, using: &rng), base: .random(in: 0.28...0.68, using: &rng))
    }
}

private func onbDrawStars(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ stars: [OnbStar]) {
    var c = ctx
    for s in stars {
        c.opacity = s.base + (1 - s.base) * (0.5 + 0.5 * sin(t * s.speed + s.phase))
        c.fill(Path(ellipseIn: CGRect(x: s.x * size.width, y: s.y * size.height, width: s.r * 2, height: s.r * 2)),
               with: .color(Color(red: 0.85, green: 0.89, blue: 1.0)))
    }
}

private func onbCircle(_ c: CGPoint, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}

private func onbAltColor(_ t: Double) -> Color {
    Color(hue: 0.08 + t * (0.55 - 0.08), saturation: 0.85, brightness: 1.0)
}

private func onbPlane(_ ctx: GraphicsContext, at pt: CGPoint, heading: Double, scale: CGFloat, color: Color) {
    var resolved = ctx.resolve(Image(systemName: "airplane"))
    resolved.shading = .color(color)
    ctx.drawLayer { layer in
        layer.translateBy(x: pt.x, y: pt.y)
        layer.rotate(by: .radians(heading))
        layer.addFilter(.shadow(color: color.opacity(0.5), radius: 4))
        layer.draw(resolved, in: CGRect(x: -scale / 2, y: -scale / 2, width: scale, height: scale))
    }
}

/// "Your place under the sky": you at the centre of a curved horizon, with
/// aircraft and celestial bodies pinned around you at their real bearings and a
/// geolocation pulse rippling outward.
private struct LocationHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let stars = onbStars(seed: 11, count: 46, maxY: 0.72)

    private struct Placed { let bearing: Double; let alt: Double; let dist: CGFloat; let phase: Double }
    private let placed: [Placed] = [
        Placed(bearing: -2.35, alt: 0.85, dist: 0.62, phase: 0.0),
        Placed(bearing: -1.55, alt: 0.45, dist: 0.74, phase: 2.1),
        Placed(bearing: -0.70, alt: 0.60, dist: 0.56, phase: 4.3),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 4.0 : tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in draw(ctx, size, t) }
        }
        .background(LinearGradient(colors: [Color(red: 0.06, green: 0.08, blue: 0.18), Theme.nightBottom],
                                   startPoint: .top, endPoint: .bottom))
        .overlay {
            GeometryReader { geo in
                HeaderGlassLens(size: 54)
                    .position(x: geo.size.width * 0.62, y: geo.size.height * 0.48)
            }
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        onbDrawStars(ctx, size, t, stars)

        let obs = CGPoint(x: w * 0.5, y: h * 0.86)

        // Ground bloom + curved horizon.
        ctx.fill(Path(CGRect(x: 0, y: obs.y - 2, width: w, height: h - obs.y + 2)),
                 with: .linearGradient(Gradient(colors: [Theme.indigo.opacity(0.28), .clear]),
                                       startPoint: CGPoint(x: 0, y: obs.y), endPoint: CGPoint(x: 0, y: h)))
        let horizonR = w * 1.5
        var horizon = Path()
        horizon.addArc(center: CGPoint(x: w * 0.5, y: obs.y + horizonR - 4), radius: horizonR,
                       startAngle: .degrees(256), endAngle: .degrees(284), clockwise: false)
        ctx.stroke(horizon, with: .color(Theme.accent.opacity(0.35)), lineWidth: 1.2)

        // Sun and a slim crescent moon, placed in the sky.
        let sun = CGPoint(x: w * 0.82, y: h * 0.24)
        ctx.fill(onbCircle(sun, 24),
                 with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.84, blue: 0.55).opacity(0.30), .clear]),
                                       center: sun, startRadius: 2, endRadius: 24))
        ctx.fill(onbCircle(sun, 6), with: .color(Color(red: 1, green: 0.88, blue: 0.60)))
        let moon = CGPoint(x: w * 0.19, y: h * 0.20)
        ctx.fill(onbCircle(moon, 7), with: .color(Theme.moonlight.opacity(0.9)))
        var mc = ctx; mc.opacity = 0.9
        mc.fill(onbCircle(CGPoint(x: moon.x + 2.6, y: moon.y - 1), 6), with: .color(Color(red: 0.06, green: 0.08, blue: 0.18)))

        // Geolocation pulse — elliptical ground rings easing outward.
        for i in 0..<3 {
            let ph = ((t * 0.5 + Double(i) * 0.45).truncatingRemainder(dividingBy: 1.4)) / 1.4
            let e = 1 - pow(1 - ph, 3)
            var rc = ctx; rc.opacity = (1 - ph) * 0.45
            let rr = CGFloat(e) * w * 0.42
            rc.stroke(Path(ellipseIn: CGRect(x: obs.x - rr, y: obs.y - rr * 0.32, width: rr * 2, height: rr * 0.64)),
                      with: .color(Theme.accent), lineWidth: 1.2)
        }

        // Aircraft placed around you, each on a bearing line from the observer.
        for p in placed {
            let drift = reduceMotion ? 0 : 0.10 * sin(t * 0.25 + p.phase)
            let ang = p.bearing + drift
            let R = p.dist * h * 0.82
            let pt = CGPoint(x: obs.x + cos(ang) * R, y: obs.y + sin(ang) * R)
            var bl = ctx; bl.opacity = 0.26
            var lp = Path(); lp.move(to: obs); lp.addLine(to: pt)
            bl.stroke(lp, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            onbPlane(ctx, at: pt, heading: ang + .pi / 2, scale: 15, color: onbAltColor(p.alt))
        }

        // Observer marker: up-beam, glow, dot.
        var beam = ctx; beam.opacity = 0.55
        beam.fill(Path(CGRect(x: obs.x - 1.1, y: obs.y - 32, width: 2.2, height: 32)),
                  with: .linearGradient(Gradient(colors: [.clear, Theme.accent.opacity(0.6)]),
                                        startPoint: CGPoint(x: 0, y: obs.y - 32), endPoint: CGPoint(x: 0, y: obs.y)))
        ctx.fill(onbCircle(obs, 12),
                 with: .radialGradient(Gradient(colors: [Theme.accent.opacity(0.5), .clear]),
                                       center: obs, startRadius: 1, endRadius: 12))
        ctx.fill(onbCircle(obs, 4.6), with: .color(.white))
        ctx.fill(onbCircle(obs, 2.6), with: .color(Theme.accent))
    }
}

/// "Every flight counts": a climb-out arc rising across the night, with the
/// tier metals struck along it — bronze, silver, gold coins growing as the
/// path ascends — and a small plane forever climbing the line. The same
/// living-sky Canvas language as the other heroes; still under Reduce Motion.
private struct TierHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let stars = onbStars(seed: 37, count: 44)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 5.0 : tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in draw(ctx, size, t) }
        }
        .background(LinearGradient(colors: [Color(red: 0.06, green: 0.08, blue: 0.18), Theme.nightBottom],
                                   startPoint: .top, endPoint: .bottom))
        .accessibilityHidden(true)
    }

    /// Quadratic climb-out: low at the left, easing up to the right.
    private func climb(_ u: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPoint {
        let p0 = CGPoint(x: w * 0.08, y: h * 0.84)
        let c  = CGPoint(x: w * 0.48, y: h * 0.88)
        let p1 = CGPoint(x: w * 0.90, y: h * 0.20)
        let v = 1 - u
        return CGPoint(x: v * v * p0.x + 2 * v * u * c.x + u * u * p1.x,
                       y: v * v * p0.y + 2 * v * u * c.y + u * u * p1.y)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        onbDrawStars(ctx, size, t, stars)

        // The climb line, dotted like a route on a chart.
        var route = Path()
        route.move(to: climb(0, w, h))
        for i in 1...36 { route.addLine(to: climb(CGFloat(i) / 36, w, h)) }
        var rl = ctx; rl.opacity = 0.30
        rl.stroke(route, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))

        // The metals along the way — each coin struck a little larger.
        let rungs: [(Medal.Finish, CGFloat, CGFloat)] = [(.bronze, 0.22, 13), (.silver, 0.55, 17), (.gold, 0.88, 22)]
        for (finish, u, r) in rungs {
            let c = MedalArt.colors(finish)
            let pt = climb(u, w, h)
            // Halo, body, rim, inner engraving ring.
            ctx.fill(onbCircle(pt, r * 1.9),
                     with: .radialGradient(Gradient(colors: [c.thumbLight.opacity(0.22), .clear]),
                                           center: pt, startRadius: r * 0.5, endRadius: r * 1.9))
            ctx.fill(onbCircle(pt, r),
                     with: .radialGradient(Gradient(colors: [c.thumbLight, c.thumbDark]),
                                           center: CGPoint(x: pt.x - r * 0.35, y: pt.y - r * 0.4),
                                           startRadius: 1, endRadius: r * 1.9))
            ctx.stroke(onbCircle(pt, r), with: .color(.white.opacity(0.30)), lineWidth: 1)
            var ring = ctx; ring.opacity = 0.45
            ring.stroke(onbCircle(pt, r * 0.68), with: .color(c.thumbDark), lineWidth: 1)
        }

        // A glint sweeping the gold — the ladder's summit catches the light.
        let gold = climb(0.88, w, h)
        let gp = (t * 0.45).truncatingRemainder(dividingBy: 2 * .pi)
        var glint = ctx
        glint.opacity = max(0, sin(gp)) * 0.9
        let gpt = CGPoint(x: gold.x + 22 * 0.62, y: gold.y - 22 * 0.62)
        for (len, lw) in [(CGFloat(7), CGFloat(1.6)), (CGFloat(3.6), CGFloat(1.1))] {
            var s = Path()
            s.move(to: CGPoint(x: gpt.x - len, y: gpt.y)); s.addLine(to: CGPoint(x: gpt.x + len, y: gpt.y))
            s.move(to: CGPoint(x: gpt.x, y: gpt.y - len)); s.addLine(to: CGPoint(x: gpt.x, y: gpt.y + len))
            glint.stroke(s, with: .color(.white), lineWidth: lw)
        }

        // The plane, forever climbing.
        let pu = reduceMotion ? 0.42 : CGFloat((t * 0.11).truncatingRemainder(dividingBy: 1.3)) // runs past the top
        guard pu <= 1.04 else { return }
        let u = min(pu, 1)
        let pt = climb(u, w, h)
        let ahead = climb(min(u + 0.02, 1), w, h)
        let heading = atan2(ahead.y - pt.y, ahead.x - pt.x)
        onbPlane(ctx, at: pt, heading: heading + .pi / 2, scale: 15, color: onbAltColor(Double(u)))
    }
}

/// "See through to the real sky": the live star sky, revealed and augmented
/// through a tilted phone — a plane framed by an AR reticle with an info tag,
/// and a glass sheen sweeping the screen.
private struct CameraHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let stars = onbStars(seed: 23, count: 54)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 3.0 : tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in draw(ctx, size, t) }
        }
        .background(LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.16), Theme.nightBottom],
                                   startPoint: .top, endPoint: .bottom))
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        // The real sky, everywhere.
        onbDrawStars(ctx, size, t, stars)

        let center = CGPoint(x: w * 0.5, y: h * 0.52)
        let pw = min(w * 0.42, 132), phh = h * 0.86
        let bodyRect = CGRect(x: center.x - pw / 2, y: center.y - phh / 2, width: pw, height: phh)
        let body = Path(roundedRect: bodyRect, cornerRadius: 22, style: .continuous)

        ctx.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .degrees(-9))
            layer.translateBy(x: -center.x, y: -center.y)

            // Darken behind the glass so the augmented content reads.
            layer.fill(body, with: .color(.black.opacity(0.28)))

            // Augmented content, clipped to the screen.
            layer.drawLayer { screen in
                screen.clip(to: body)
                let u = reduceMotion ? 0.5 : (t.truncatingRemainder(dividingBy: 8)) / 8
                let plane = CGPoint(x: bodyRect.minX + bodyRect.width * CGFloat(0.16 + 0.68 * u),
                                    y: bodyRect.minY + bodyRect.height * CGFloat(0.40 - 0.04 * sin(u * .pi)))
                // Contrail.
                var trail = screen
                for i in 1...12 {
                    let uu = u - Double(i) * 0.015
                    guard uu > 0 else { break }
                    let p = CGPoint(x: bodyRect.minX + bodyRect.width * CGFloat(0.16 + 0.68 * uu),
                                    y: bodyRect.minY + bodyRect.height * CGFloat(0.40 - 0.04 * sin(uu * .pi)))
                    trail.opacity = (1 - Double(i) / 12) * 0.35
                    trail.fill(onbCircle(p, 0.8 + CGFloat(i) * 0.12), with: .color(.white))
                }
                drawReticle(screen, at: plane, span: 30, color: Theme.accent)
                onbPlane(screen, at: plane, heading: 0.06, scale: 19, color: onbAltColor(0.7))
                // Info tag with a leader line.
                let chip = CGPoint(x: bodyRect.minX + bodyRect.width * 0.34,
                                   y: bodyRect.minY + bodyRect.height * 0.68)
                var lead = screen; lead.opacity = 0.6
                var lp = Path(); lp.move(to: plane); lp.addLine(to: chip)
                lead.stroke(lp, with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                drawChip(screen, at: chip, text: String(localized: "BA212 · 38,000 ft"))
            }

            // Glass frame + inner highlight.
            layer.stroke(body, with: .color(.white.opacity(0.38)), lineWidth: 1.6)
            layer.stroke(Path(roundedRect: bodyRect.insetBy(dx: 2.5, dy: 2.5), cornerRadius: 19, style: .continuous),
                         with: .color(.white.opacity(0.08)), lineWidth: 1)
            // Dynamic-island pill.
            layer.fill(Path(roundedRect: CGRect(x: center.x - 15, y: bodyRect.minY + 10, width: 30, height: 8), cornerRadius: 4),
                       with: .color(.black.opacity(0.6)))

            // Sweeping sheen.
            let sx = reduceMotion ? 0.35 : (t.truncatingRemainder(dividingBy: 5)) / 5
            var sheen = layer; sheen.opacity = 0.13
            sheen.clip(to: body)
            let bandX = bodyRect.minX + bodyRect.width * CGFloat(-0.4 + 1.7 * sx)
            var band = Path()
            band.move(to: CGPoint(x: bandX, y: bodyRect.minY))
            band.addLine(to: CGPoint(x: bandX + 34, y: bodyRect.minY))
            band.addLine(to: CGPoint(x: bandX + 34 - 54, y: bodyRect.maxY))
            band.addLine(to: CGPoint(x: bandX - 54, y: bodyRect.maxY))
            band.closeSubpath()
            sheen.fill(band, with: .linearGradient(Gradient(colors: [.clear, .white, .clear]),
                                                   startPoint: CGPoint(x: bandX - 27, y: 0),
                                                   endPoint: CGPoint(x: bandX + 34, y: 0)))
        }
    }

    private func drawReticle(_ ctx: GraphicsContext, at c: CGPoint, span s: CGFloat, color: Color) {
        let half = s / 2, len = s * 0.32
        var c2 = ctx; c2.opacity = 0.9
        for sx in [-1.0, 1.0] {
            for sy in [-1.0, 1.0] {
                let corner = CGPoint(x: c.x + CGFloat(sx) * half, y: c.y + CGFloat(sy) * half)
                var p = Path()
                p.move(to: CGPoint(x: corner.x - CGFloat(sx) * len, y: corner.y))
                p.addLine(to: corner)
                p.addLine(to: CGPoint(x: corner.x, y: corner.y - CGFloat(sy) * len))
                c2.stroke(p, with: .color(color), lineWidth: 1.6)
            }
        }
    }

    private func drawChip(_ ctx: GraphicsContext, at c: CGPoint, text: String) {
        let resolved = ctx.resolve(Text(text).font(Theme.display(9, .semibold)).foregroundColor(.white))
        let ts = resolved.measure(in: CGSize(width: 220, height: 40))
        let padX: CGFloat = 8, dot: CGFloat = 8
        let rect = CGRect(x: c.x - (ts.width + dot) / 2 - padX, y: c.y - ts.height / 2 - 4,
                          width: ts.width + dot + padX * 2, height: ts.height + 8)
        let pill = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        ctx.fill(pill, with: .color(.black.opacity(0.55)))
        ctx.stroke(pill, with: .color(.white.opacity(0.25)), lineWidth: 1)
        ctx.fill(onbCircle(CGPoint(x: rect.minX + padX + dot / 2, y: rect.midY), 2.6), with: .color(Theme.accent))
        ctx.draw(resolved, at: CGPoint(x: rect.minX + padX + dot + ts.width / 2, y: rect.midY))
    }
}
