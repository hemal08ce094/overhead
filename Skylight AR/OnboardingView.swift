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
                PageDots(count: 4, index: page)
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
                .padding(.top, 12)
                .padding(.horizontal, 24)
        }
    }

    private var locationStep: some View {
        // Once denied, requesting again is a no-op — route the primary action to
        // Settings and keep the skip as a way forward so nobody gets stuck here.
        PrimingCard(
            hero: LocationHero(),
            title: "Your place under the sky",
            message: "Overhead uses your location to compute exactly where each aircraft and celestial object sits above you.",
            primary: permissions.locationDenied ? "Open Settings" : "Enable Location",
            action: { permissions.locationDenied ? openSettings() : permissions.requestLocation() },
            skipTitle: permissions.locationDenied ? "Continue with demo sky" : "Not now",
            skipAction: { advance() })
    }

    private var cameraStep: some View {
        // Same trap as location: a previously-denied camera makes the request
        // a silent no-op, so the primary routes to Settings instead.
        PrimingCard(
            hero: CameraHero(),
            title: "See through to the real sky",
            message: "The camera lets Overhead place aircraft and stars onto the live sky in augmented reality. You can also use a low-power dark-sky mode.",
            primary: permissions.cameraDenied ? "Open Settings" : "Enable Camera",
            action: {
                if permissions.cameraDenied { openSettings() }
                else { Task { await permissions.requestCamera() } }
            },
            skipTitle: "Skip — use dark sky",
            skipAction: { advance() })
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
                    tip("sun.max", "Best outdoors under open sky. The compass gets pulled off inside airports and buildings, so the sky can sit rotated there.")
                    tip("hand.raised.fill", "Hold up your phone and stand still, pointing it toward the sky.")
                    tip("scope", "If a plane sits a little off, tap it — or the Sun — to snap north back into place.")
                    tip("info.circle", "Positions come from public data and your compass, so treat it as a guide, not gospel.")
                }
                Button("Enter the sky") { finish() }
                    .buttonStyle(PrimaryButtonStyle())
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
            page = min(page + 1, 3)
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
                drawChip(screen, at: chip, text: "BA212 · 38,000 ft")
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
