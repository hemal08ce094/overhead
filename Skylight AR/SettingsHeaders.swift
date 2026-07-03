//
//  SettingsHeaders.swift
//  Skylight AR
//
//  Full-bleed animated headers for the Profile sheet and every settings screen.
//  The same living-Canvas + Liquid Glass language as `SkyVoyageScene`, but each
//  screen gets its own themed scene drawn behind clear glass: aircraft traffic on
//  a radar scope, a runway with a landing jet, a self-locking compass, a celestial
//  montage, a signalling globe, spatial-audio rings. Pure Canvas — no assets, no
//  dependencies — and every scene freezes to a composed still under Reduce Motion.
//

import SwiftUI

// MARK: - Theme

/// One themed header per surface. Drives the backdrop, the accent used across the
/// scene, and the SF Symbol shown in the floating glass title.
enum HeaderTheme: Equatable {
    case voyage        // Profile / About — the classic solar voyage
    case sky           // View & sky
    case aircraft
    case airport
    case calibration
    case dataSource
    case accessibility

    /// Two-stop night gradient behind the scene.
    var gradient: [Color] {
        switch self {
        case .voyage:        return [Color(red: 0.07, green: 0.09, blue: 0.20), Color(red: 0.02, green: 0.02, blue: 0.07)]
        case .sky:           return [Color(red: 0.06, green: 0.08, blue: 0.20), Theme.nightBottom]
        case .aircraft:      return [Color(red: 0.04, green: 0.09, blue: 0.15), Color(red: 0.01, green: 0.02, blue: 0.05)]
        case .airport:       return [Color(red: 0.09, green: 0.08, blue: 0.14), Color(red: 0.02, green: 0.02, blue: 0.05)]
        case .calibration:   return [Color(red: 0.05, green: 0.08, blue: 0.14), Theme.nightBottom]
        case .dataSource:    return [Color(red: 0.03, green: 0.09, blue: 0.14), Theme.nightBottom]
        case .accessibility: return [Color(red: 0.07, green: 0.06, blue: 0.16), Theme.nightBottom]
        }
    }

    /// Accent used for scene highlights and the glass icon.
    var accent: Color {
        switch self {
        case .voyage, .sky:  return Theme.accent
        case .aircraft:      return Color(red: 0.45, green: 0.85, blue: 0.95)
        case .airport:       return Color(red: 1.00, green: 0.75, blue: 0.40)
        case .calibration:   return Color(red: 0.52, green: 0.92, blue: 0.78)
        case .dataSource:    return Color(red: 0.50, green: 0.85, blue: 0.95)
        case .accessibility: return Color(red: 0.72, green: 0.72, blue: 1.00)
        }
    }

    /// Mark used in the title banner and the pinned bar.
    var icon: String {
        switch self {
        case .voyage:        return "moon.stars.fill"
        case .sky:           return "moon.stars.fill"
        case .aircraft:      return "airplane"
        case .airport:       return "airplane.arrival"
        case .calibration:   return "scope"
        case .dataSource:    return "dot.radiowaves.up.forward"
        case .accessibility: return "accessibility"
        }
    }
}

/// Top safe-area inset of the key window. The scaffold ignores the container
/// safe area (the header bleeds under the status bar), so chrome pinned to the
/// screen's top edge measures the real inset directly.
@MainActor
func windowTopInset() -> CGFloat {
    UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        .first?.safeAreaInsets.top ?? 59
}

// MARK: - Full-bleed header

/// Edge-to-edge animated banner. The living scene plays full-bleed behind the
/// native Liquid Glass nav bar — no custom title object — with a soft scrim at
/// top for the title, a vignette for depth, and a fade into the page below.
struct SettingsHeader: View {
    let theme: HeaderTheme
    /// Extra height drawn above the base so the scene bleeds under the nav bar.
    var topOverscan: CGFloat = 64
    /// Optional glass surface floating over the scene.
    var accessory: AnyView? = nil
    /// Pin the accessory to the top edge (below the status bar) instead of the
    /// bottom — the Profile banner lives up there, in the flight path.
    var accessoryAtTop: Bool = false
    /// Replace the theme's default scene (Profile re-routes the airliner).
    var scene: AnyView? = nil
    /// Extra canvas below the base height (Profile grows to hold its medals).
    var extraHeight: CGFloat = 0
    /// Stop the scene's animation while the header is scrolled out of view.
    var scenePaused: Bool = false

    private let baseHeight: CGFloat = 158

    var body: some View {
        ZStack {
            LinearGradient(colors: theme.gradient, startPoint: .top, endPoint: .bottom)

            if let scene {
                scene
            } else {
                SettingsHeaderScene(theme: theme, paused: scenePaused)
            }

            // Legibility scrim beneath the nav-bar title.
            LinearGradient(colors: [Theme.nightBottom.opacity(0.60), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 104)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

            // Fade the scene into the page background along the bottom edge.
            LinearGradient(colors: [.clear, .clear, Theme.nightBottom],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 88)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            // Soft vignette — a hand-finished sense of depth, not a flat render.
            RadialGradient(colors: [.clear, .black.opacity(0.26)],
                           center: .center, startRadius: 70, endRadius: 360)
                .allowsHitTesting(false)

            // A screen-supplied glass surface floating over the scene.
            if let accessory {
                accessory
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: accessoryAtTop ? .top : .bottom)
                    .padding(.top, accessoryAtTop ? topOverscan + 6 : 0)
                    .padding(.bottom, accessoryAtTop ? 0 : 16)
            }
        }
        .frame(height: baseHeight + topOverscan + extraHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// A clear Liquid Glass lens: whatever is drawn behind it bends through the
/// glass; the styling stays restrained (a thin fresnel rim, a faint top-lit
/// volume, one small specular catch) so it reads as an integrated lens rather
/// than a shiny marble dropped on top of a scene. Used by the onboarding
/// pages; the settings headers no longer float one.
/// Purely decorative; never intercepts touches.
struct HeaderGlassLens: View {
    var size: CGFloat
    var tint: Color = Theme.accent

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .glassEffect(.clear, in: .circle)
            // Faint top-lit volume so it reads as a body without going opaque.
            .overlay(
                Circle().fill(RadialGradient(
                    colors: [.white.opacity(0.12), .clear, .black.opacity(0.14)],
                    center: UnitPoint(x: 0.36, y: 0.30),
                    startRadius: size * 0.05, endRadius: size * 0.70))
            )
            // A single small specular catch where the light grazes the glass.
            .overlay(
                Circle().fill(.white.opacity(0.7))
                    .frame(width: size * 0.10, height: size * 0.10)
                    .blur(radius: size * 0.045)
                    .offset(x: -size * 0.20, y: -size * 0.22)
                    .blendMode(.screen)
            )
            // Thin fresnel rim, tinted to the scene's accent — just enough edge.
            .overlay(
                Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.50), tint.opacity(0.22), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.16), radius: 5, y: 3)
            .accessibilityHidden(true)
    }
}

// MARK: - Title banner + pinned bar

/// Default in-header title banner: the theme's mark and the screen's name in a
/// clear glass capsule, floating over the scene. It IS the screen's title —
/// the system nav-bar title stays empty.
struct HeaderTitleBanner: View {
    let theme: HeaderTheme
    let title: String
    /// The spotter's tier medal, carried into every screen's banner.
    var badge: AnyView? = nil

    var body: some View {
        HStack(spacing: 9) {
            if let badge { badge }
            Image(systemName: theme.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(title)
                .font(Theme.display(17, .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassEffect(.clear, in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
    }
}

/// The bar the banner becomes once it scrolls away: full-width Liquid Glass
/// pinned to the top edge, carrying the same mark and title.
private struct PinnedTitleBar: View {
    let title: String
    let leading: AnyView
    var trailing: AnyView? = nil

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                leading
                Text(title)
                    .font(Theme.display(16, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            if let trailing {
                HStack { Spacer(); trailing }
                    .padding(.trailing, 16)
            }
        }
        .padding(.vertical, 10)
        .padding(.top, windowTopInset())
        .background {
            Rectangle().fill(.clear)
                .glassEffect(.regular.tint(Theme.nightBottom.opacity(0.5)), in: .rect)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.7)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Scaffold

/// Standard settings screen: a full-bleed animated header flush to the top
/// with a glass title banner floating in it. Scrolling past the banner pins a
/// full-width Liquid Glass title bar to the top edge — the banner becomes the
/// navigation bar. No system nav-bar title anywhere.
struct SettingsScaffold<Content: View>: View {
    let theme: HeaderTheme
    var title: String
    /// Custom banner (Profile's identity card); defaults to the title capsule.
    var headerAccessory: AnyView? = nil
    /// Pin the banner to the header's top instead of its bottom.
    var headerAccessoryAtTop: Bool = false
    /// Replace the theme's default header scene.
    var headerScene: AnyView? = nil
    /// Extra header canvas (Profile grows to hold its medals).
    var headerExtraHeight: CGFloat = 0
    /// Tier medal shown in the default title banner.
    var titleBadge: AnyView? = nil
    /// Leading mark in the pinned bar (defaults to the theme icon).
    var compactLeading: AnyView? = nil
    /// Trailing control in the pinned bar (Profile's close button).
    var compactTrailing: AnyView? = nil
    @ViewBuilder var content: Content

    @State private var pinned = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SettingsHeader(theme: theme,
                               accessory: headerAccessory
                                   ?? AnyView(HeaderTitleBanner(theme: theme, title: title,
                                                                badge: titleBadge)),
                               accessoryAtTop: headerAccessoryAtTop,
                               scene: headerScene,
                               extraHeight: headerExtraHeight,
                               scenePaused: pinned)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        // Pin once the banner itself has scrolled up under the bar's zone.
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top > (headerAccessoryAtTop ? 84 : 128)
        } action: { _, nowPinned in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { pinned = nowPinned }
        }
        .overlay(alignment: .top) {
            if pinned {
                PinnedTitleBar(
                    title: title,
                    leading: compactLeading ?? AnyView(
                        Image(systemName: theme.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.accent)),
                    trailing: compactTrailing)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.skyGradient.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Scene dispatch

/// The animated scene for a theme. Voyage reuses the original solar hero; every
/// other theme is a bespoke Canvas below.
struct SettingsHeaderScene: View {
    let theme: HeaderTheme
    /// Stop drawing while the header is scrolled away under the pinned bar.
    var paused: Bool = false

    var body: some View {
        if theme == .voyage {
            SkyVoyageScene(paused: paused)
        } else {
            HeaderCanvas(theme: theme, paused: paused)
        }
    }
}

// MARK: - Canvas

private struct HStar {
    let x: CGFloat, y: CGFloat, r: CGFloat, phase: Double, speed: Double, base: Double
}

/// Seeded RNG so each scene's static layout is stable across redraws.
private struct HeaderRNG: RandomNumberGenerator {
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

private struct Flyer {
    let y: CGFloat, cycle: Double, phase: Double, altT: Double, scale: CGFloat
}

private struct HeaderCanvas: View {
    let theme: HeaderTheme
    var paused: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let stars: [HStar]

    init(theme: HeaderTheme, paused: Bool = false) {
        self.theme = theme
        self.paused = paused
        var rng = HeaderRNG(seed: 42)
        stars = (0..<56).map { _ in
            HStar(x: .random(in: 0...1, using: &rng),
                  y: .random(in: 0...0.85, using: &rng),
                  r: .random(in: 0.4...1.4, using: &rng),
                  phase: .random(in: 0...(2 * .pi), using: &rng),
                  speed: .random(in: 0.3...1.0, using: &rng),
                  base: .random(in: 0.25...0.65, using: &rng))
        }
    }

    var body: some View {
        // 30 fps — ambient scenes read identically and cost half as much.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || paused)) { tl in
            let t = reduceMotion ? 6.0 : tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                drawStars(ctx, size, t)
                switch theme {
                case .voyage:        break
                case .sky:           drawSky(ctx, size, t)
                case .aircraft:      drawAircraft(ctx, size, t)
                case .airport:       drawAirport(ctx, size, t)
                case .calibration:   drawCalibration(ctx, size, t)
                case .dataSource:    drawDataSource(ctx, size, t)
                case .accessibility: drawAccessibility(ctx, size, t)
                }
            }
        }
    }

    // MARK: Shared helpers

    private func circlePath(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private func pointOn(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
    }

    /// Altitude colour ramp — orange (low) to cyan (high) — matching the sky.
    private func altColor(_ t: Double) -> Color {
        Color(hue: 0.08 + t * (0.55 - 0.08), saturation: 0.85, brightness: 1.0)
    }

    private func drawStars(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        var c = ctx
        for s in stars {
            let tw = s.base + (1 - s.base) * (0.5 + 0.5 * sin(t * s.speed + s.phase))
            c.opacity = tw
            c.fill(Path(ellipseIn: CGRect(x: s.x * size.width, y: s.y * size.height,
                                          width: s.r * 2, height: s.r * 2)),
                   with: .color(Color(red: 0.85, green: 0.89, blue: 1.0)))
        }
    }

    private func planePoint(_ u: Double, _ size: CGSize, _ yFrac: CGFloat) -> CGPoint {
        let x = CGFloat(u) * (size.width + 80) - 40
        let y = size.height * yFrac - size.height * 0.06 * CGFloat(sin(u * .pi))
        return CGPoint(x: x, y: y)
    }

    private func drawPlaneSymbol(_ ctx: GraphicsContext, at pt: CGPoint,
                                 heading: Double, scale: CGFloat, color: Color) {
        var resolved = ctx.resolve(Image(systemName: "airplane"))
        resolved.shading = .color(color)
        ctx.drawLayer { layer in
            layer.translateBy(x: pt.x, y: pt.y)
            layer.rotate(by: .radians(heading))
            layer.addFilter(.shadow(color: color.opacity(0.5), radius: 4))
            layer.draw(resolved, in: CGRect(x: -scale / 2, y: -scale / 2, width: scale, height: scale))
        }
    }

    private func drawFlyer(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, _ f: Flyer) {
        let color = altColor(f.altT)
        let u = ((t + f.phase).truncatingRemainder(dividingBy: f.cycle)) / (f.cycle * 0.82)
        guard u <= 1.03 else { return }
        let pt = planePoint(u, size, f.y)
        let ahead = planePoint(min(u + 0.01, 1.05), size, f.y)
        let heading = atan2(ahead.y - pt.y, ahead.x - pt.x)

        var trail = ctx
        for i in 1...22 {
            let uu = u - Double(i) * 0.012
            guard uu > 0 else { break }
            let p = planePoint(uu, size, f.y)
            let fade = 1 - Double(i) / 22
            let puff = 0.8 + CGFloat(i) * 0.09
            trail.opacity = fade * 0.28
            trail.fill(Path(ellipseIn: CGRect(x: p.x - puff, y: p.y - puff,
                                              width: puff * 2, height: puff * 2)),
                       with: .color(color))
        }
        drawPlaneSymbol(ctx, at: pt, heading: heading, scale: f.scale, color: color)
    }

    // MARK: Sky (View & sky)

    private func drawSky(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        let gold = Color(red: 1.0, green: 0.84, blue: 0.55)

        // Sun, top-trailing
        let sun = CGPoint(x: w * 0.84, y: h * 0.32)
        ctx.fill(circlePath(sun, 34),
                 with: .radialGradient(Gradient(colors: [gold.opacity(0.34), .clear]),
                                       center: sun, startRadius: 2, endRadius: 34))
        ctx.fill(circlePath(sun, 8),
                 with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.97, blue: 0.88), gold]),
                                       center: CGPoint(x: sun.x - 2, y: sun.y - 2), startRadius: 1, endRadius: 10))

        // Moon — its body IS the glass lens (0.62, 0.46); here we lay only the
        // moonlit glow behind it so the glass reads as a lit moon, not a bubble.
        let moon = CGPoint(x: w * 0.62, y: h * 0.46)
        ctx.fill(circlePath(moon, 42),
                 with: .radialGradient(Gradient(colors: [Theme.moonlight.opacity(0.22), .clear]),
                                       center: CGPoint(x: moon.x - 4, y: moon.y - 5), startRadius: 8, endRadius: 42))

        // Drifting planets
        let planets: [(y: CGFloat, size: CGFloat, speed: Double, phase: Double, color: Color)] = [
            (0.62, 3.0, 0.010, 0.0, Color(red: 0.60, green: 0.74, blue: 1.00)),
            (0.74, 4.0, 0.007, 2.2, Color(red: 0.95, green: 0.72, blue: 0.52)),
            (0.52, 2.4, 0.009, 4.4, Color(red: 0.58, green: 0.86, blue: 0.80)),
        ]
        for p in planets {
            let raw = t * p.speed + p.phase
            let fx = raw - floor(raw)
            let pt = CGPoint(x: CGFloat(fx) * w, y: p.y * h)
            ctx.fill(circlePath(pt, p.size),
                     with: .radialGradient(Gradient(colors: [p.color, p.color.opacity(0.55)]),
                                           center: CGPoint(x: pt.x - p.size * 0.4, y: pt.y - p.size * 0.4),
                                           startRadius: 0.5, endRadius: p.size * 1.6))
        }

        // ISS diamond streak
        let issCycle = 13.0
        let ph = (t.truncatingRemainder(dividingBy: issCycle)) / issCycle
        if ph < 0.5 {
            let u = ph / 0.5
            let pos = CGPoint(x: w * (-0.1 + 1.2 * CGFloat(u)), y: h * (0.16 + 0.42 * CGFloat(u)))
            var tc = ctx
            for i in 1...8 {
                let uu = u - Double(i) * 0.02
                guard uu > 0 else { break }
                let p = CGPoint(x: w * (-0.1 + 1.2 * CGFloat(uu)), y: h * (0.16 + 0.42 * CGFloat(uu)))
                tc.opacity = (1 - Double(i) / 8) * 0.4
                tc.fill(circlePath(p, 1.4), with: .color(Theme.accent))
            }
            diamond(ctx, at: pos, r: 4, color: Color(red: 0.85, green: 0.92, blue: 1.0))
        }
    }

    private func diamond(_ ctx: GraphicsContext, at c: CGPoint, r: CGFloat, color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addLine(to: CGPoint(x: c.x + r, y: c.y))
        p.addLine(to: CGPoint(x: c.x, y: c.y + r))
        p.addLine(to: CGPoint(x: c.x - r, y: c.y))
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
    }

    // MARK: Aircraft (traffic scope)

    private func drawAircraft(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        let accent = theme.accent
        let scope = CGPoint(x: w * 0.5, y: h * 1.18)

        // Range rings
        var rc = ctx
        for k in 1...3 {
            let r = h * (0.5 + CGFloat(k) * 0.28)
            rc.opacity = 0.10
            rc.stroke(circlePath(scope, r), with: .color(accent),
                      style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
        }
        // Sweep line
        let sweep = t * 0.8 - .pi / 2
        var wc = ctx; wc.opacity = 0.16
        var sp = Path()
        sp.move(to: scope)
        sp.addLine(to: pointOn(scope, h * 1.5, sweep))
        wc.stroke(sp, with: .color(accent), lineWidth: 2)

        // Traffic
        let flyers = [
            Flyer(y: 0.30, cycle: 13, phase: 0.0, altT: 0.9, scale: 17),
            Flyer(y: 0.46, cycle: 17, phase: 5.0, altT: 0.55, scale: 20),
            Flyer(y: 0.60, cycle: 10, phase: 8.0, altT: 0.2, scale: 15),
        ]
        for f in flyers { drawFlyer(ctx, size, t, f) }
    }

    // MARK: Airport (runway)

    private func drawAirport(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        let amber = theme.accent

        // Warm horizon bloom
        ctx.fill(Path(CGRect(x: 0, y: h * 0.5, width: w, height: h * 0.5)),
                 with: .linearGradient(Gradient(colors: [.clear, amber.opacity(0.10)]),
                                       startPoint: CGPoint(x: 0, y: h * 0.5), endPoint: CGPoint(x: 0, y: h)))

        // Glow behind the glass lens (0.5, 0.42) so it reads as an orb rising
        // over the runway, on the centerline the jet flies toward.
        let orb = CGPoint(x: w * 0.5, y: h * 0.42)
        ctx.fill(circlePath(orb, 36),
                 with: .radialGradient(Gradient(colors: [amber.opacity(0.22), .clear]),
                                       center: orb, startRadius: 6, endRadius: 36))

        // Runway trapezoid
        let cx = w * 0.5
        let farY = h * 0.52, nearY = h * 1.02
        let farHalf = w * 0.03, nearHalf = w * 0.24
        var rw = Path()
        rw.move(to: CGPoint(x: cx - farHalf, y: farY))
        rw.addLine(to: CGPoint(x: cx + farHalf, y: farY))
        rw.addLine(to: CGPoint(x: cx + nearHalf, y: nearY))
        rw.addLine(to: CGPoint(x: cx - nearHalf, y: nearY))
        rw.closeSubpath()
        ctx.fill(rw, with: .linearGradient(Gradient(colors: [Color(white: 0.09), Color(white: 0.17)]),
                                           startPoint: CGPoint(x: 0, y: farY), endPoint: CGPoint(x: 0, y: nearY)))
        ctx.stroke(rw, with: .color(.white.opacity(0.12)), lineWidth: 1)

        // Perspective centerline dashes
        var cl = ctx; cl.opacity = 0.5
        for k in 0..<8 {
            let a0 = CGFloat(k) / 8, a1 = a0 + 0.05
            let y0 = farY + (nearY - farY) * a0, y1 = farY + (nearY - farY) * a1
            var d = Path(); d.move(to: CGPoint(x: cx, y: y0)); d.addLine(to: CGPoint(x: cx, y: y1))
            cl.stroke(d, with: .color(.white.opacity(0.85)), lineWidth: 1 + a0 * 3)
        }

        // Sequenced edge lights
        for k in 0...8 {
            let a = CGFloat(k) / 8
            let y = farY + (nearY - farY) * a
            let half = farHalf + (nearHalf - farHalf) * a
            let bright = 0.30 + 0.70 * max(0, sin(t * 1.6 - Double(k) * 0.18))
            let rr = 1.2 + a * 2.4
            var e = ctx; e.opacity = bright
            e.fill(circlePath(CGPoint(x: cx - half, y: y), rr), with: .color(amber))
            e.fill(circlePath(CGPoint(x: cx + half, y: y), rr), with: .color(amber))
        }

        // Control tower
        let tx = w * 0.87
        let baseY = h * 0.86, cabY = h * 0.50
        var mast = Path(); mast.move(to: CGPoint(x: tx, y: baseY)); mast.addLine(to: CGPoint(x: tx, y: cabY + 8))
        ctx.stroke(mast, with: .color(Color(white: 0.28)), lineWidth: 3)
        ctx.fill(Path(roundedRect: CGRect(x: tx - 9, y: cabY - 6, width: 18, height: 14), cornerRadius: 3),
                 with: .color(Color(white: 0.22)))
        ctx.fill(Path(roundedRect: CGRect(x: tx - 7, y: cabY - 4, width: 14, height: 6), cornerRadius: 2),
                 with: .color(amber.opacity(0.5)))
        // Rotating beacon
        let beaconAng = t * 2.2
        var bc = ctx; bc.opacity = 0.3 + 0.7 * max(0, cos(beaconAng))
        bc.fill(circlePath(CGPoint(x: tx + cos(beaconAng) * 14, y: cabY - 9), 2), with: .color(.white))

        // Landing jet on final approach
        let cyc = 9.0
        let a = CGFloat((t.truncatingRemainder(dividingBy: cyc)) / cyc)
        func approach(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx - (w * 0.18) * (1 - a),
                    y: (farY - h * 0.22) + (nearY - 40 - (farY - h * 0.22)) * a)
        }
        let pt = approach(a)
        let ahead = approach(min(a + 0.02, 1.0))
        let heading = atan2(ahead.y - pt.y, ahead.x - pt.x)
        drawPlaneSymbol(ctx, at: pt, heading: heading, scale: 12 + 15 * a, color: .white)
    }

    // MARK: Calibration (compass lock)

    private func drawCalibration(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        let mint = theme.accent
        let red = Color(red: 1.0, green: 0.50, blue: 0.45)
        let gold = Color(red: 1.0, green: 0.84, blue: 0.55)
        let center = CGPoint(x: w * 0.5, y: h * 0.56)
        let R = h * 0.34

        ctx.stroke(circlePath(center, R), with: .color(mint.opacity(0.5)), lineWidth: 1.5)
        ctx.stroke(circlePath(center, R * 0.72), with: .color(.white.opacity(0.12)), lineWidth: 1)

        // Rotating tick ring + cardinals (a slow, calm "search")
        let spin = t * 0.12
        for i in 0..<36 {
            let ang = Double(i) * (.pi / 18) + spin
            let major = i % 9 == 0
            var tk = Path()
            tk.move(to: pointOn(center, R * (major ? 0.86 : 0.93), ang))
            tk.addLine(to: pointOn(center, R, ang))
            ctx.stroke(tk, with: .color(.white.opacity(major ? 0.5 : 0.22)), lineWidth: major ? 1.6 : 1)
        }
        let cards: [(String, Double)] = [("N", -.pi / 2), ("E", 0), ("S", .pi / 2), ("W", .pi)]
        for (lab, base) in cards {
            let p = pointOn(center, R * 0.68, base + spin)
            ctx.draw(Text(lab).font(Theme.display(11, .bold))
                        .foregroundColor(lab == "N" ? red : Theme.textSecondary), at: p)
        }

        // Reticle
        var rc = ctx; rc.opacity = 0.5
        for a in stride(from: 0.0, to: 2 * .pi, by: .pi / 2) {
            var cp = Path()
            cp.move(to: pointOn(center, R * 1.14, a))
            cp.addLine(to: pointOn(center, R * 1.28, a))
            rc.stroke(cp, with: .color(mint), lineWidth: 1)
        }

        // Needle: sweep, decelerate, then lock onto the Sun and dwell — the real
        // calibration gesture, not a mechanical spin.
        let sunBearing = -3 * Double.pi / 4
        let cyc = 7.0
        let ph = (t.truncatingRemainder(dividingBy: cyc)) / cyc
        let sweepEnd = 0.66
        let needle: Double
        let locked: Bool
        if ph < sweepEnd {
            let e = ph / sweepEnd
            let eased = 1 - pow(1 - e, 3)                       // easeOutCubic
            needle = sunBearing + (1 - eased) * (2 * .pi * 2.25) // 2¼ turns → lock
            locked = false
        } else {
            needle = sunBearing
            locked = true
        }
        // Faint motion-blur ghost trailing the north tip while it's still moving.
        if !locked {
            var ghost = ctx; ghost.opacity = 0.18
            var gp = Path(); gp.move(to: center)
            gp.addLine(to: pointOn(center, R * 0.86, needle - 0.16))
            ghost.stroke(gp, with: .color(red), lineWidth: 2.4)
        }
        var nN = Path(); nN.move(to: center); nN.addLine(to: pointOn(center, R * 0.86, needle))
        ctx.stroke(nN, with: .color(red), lineWidth: 2.4)
        var nS = Path(); nS.move(to: center); nS.addLine(to: pointOn(center, R * 0.5, needle + .pi))
        ctx.stroke(nS, with: .color(.white.opacity(0.7)), lineWidth: 2.4)
        ctx.fill(circlePath(center, 3.4), with: .color(.white))
        ctx.fill(circlePath(center, 1.6), with: .color(red))

        // Sun target + lock beam once the needle settles.
        let sunPt = pointOn(center, R * 1.4, sunBearing)
        ctx.fill(circlePath(sunPt, 15),
                 with: .radialGradient(Gradient(colors: [gold.opacity(locked ? 0.6 : 0.35), .clear]),
                                       center: sunPt, startRadius: 1, endRadius: 15))
        ctx.fill(circlePath(sunPt, 5), with: .color(gold))
        if locked {
            let settle = min(1, (ph - sweepEnd) / 0.12)         // fade the lock in
            var beam = ctx; beam.opacity = 0.85 * settle
            var bp = Path(); bp.move(to: center); bp.addLine(to: sunPt)
            beam.stroke(bp, with: .color(gold.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            let pulse = R * 0.18 * CGFloat(1 + sin(t * 5))
            beam.stroke(circlePath(sunPt, 8 + pulse), with: .color(gold.opacity(0.45)), lineWidth: 1.5)
        }
    }

    // MARK: Data source (globe + signals)

    private func drawDataSource(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        let cyan = theme.accent
        let center = CGPoint(x: w * 0.34, y: h * 0.56)
        let R = h * 0.34

        ctx.stroke(circlePath(center, R), with: .color(cyan.opacity(0.5)), lineWidth: 1.5)
        ctx.fill(circlePath(center, R),
                 with: .radialGradient(Gradient(colors: [cyan.opacity(0.10), .clear]),
                                       center: CGPoint(x: center.x - R * 0.3, y: center.y - R * 0.3),
                                       startRadius: 1, endRadius: R * 1.2))

        var g = ctx; g.opacity = 0.28
        // Latitudes
        for yy in [-0.6, -0.3, 0.0, 0.3, 0.6] {
            let hw = R * CGFloat((1 - yy * yy).squareRoot())
            let cy = center.y + CGFloat(yy) * R
            g.stroke(Path(ellipseIn: CGRect(x: center.x - hw, y: cy - 2, width: hw * 2, height: 4)),
                     with: .color(cyan), lineWidth: 0.8)
        }
        // Central meridian + a wider longitude ellipse
        var mer = Path(); mer.move(to: CGPoint(x: center.x, y: center.y - R)); mer.addLine(to: CGPoint(x: center.x, y: center.y + R))
        g.stroke(mer, with: .color(cyan), lineWidth: 0.8)
        for xf in [0.55, 1.0] {
            let ew = R * CGFloat(xf)
            g.stroke(Path(ellipseIn: CGRect(x: center.x - ew, y: center.y - R, width: ew * 2, height: R * 2)),
                     with: .color(cyan), lineWidth: 0.8)
        }

        // Ground pings with expanding rings
        let pingPts = [CGPoint(x: center.x - R * 0.4, y: center.y - R * 0.2),
                       CGPoint(x: center.x + R * 0.35, y: center.y + R * 0.25)]
        for (idx, pp) in pingPts.enumerated() {
            for ringi in 0..<3 {
                let ph = ((t * 0.7 + Double(idx) * 0.5 + Double(ringi) * 0.45).truncatingRemainder(dividingBy: 1.4)) / 1.4
                var pc = ctx; pc.opacity = (1 - ph) * 0.5
                pc.stroke(circlePath(pp, CGFloat(ph) * R * 0.6), with: .color(cyan), lineWidth: 1.2)
            }
            ctx.fill(circlePath(pp, 2), with: .color(cyan))
        }

        // Orbiting satellite + downlink
        let orbA = t * 0.7
        let sat = CGPoint(x: center.x + cos(orbA) * R * 1.4, y: center.y + sin(orbA) * R * 0.6)
        if sin(orbA) < 0 {
            var dl = ctx; dl.opacity = 0.4
            var bp = Path(); bp.move(to: sat); bp.addLine(to: pingPts[1])
            dl.stroke(bp, with: .color(cyan), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
        var panel = Path(); panel.move(to: CGPoint(x: sat.x - 9, y: sat.y)); panel.addLine(to: CGPoint(x: sat.x + 9, y: sat.y))
        ctx.stroke(panel, with: .color(cyan.opacity(0.8)), lineWidth: 2)
        ctx.fill(Path(roundedRect: CGRect(x: sat.x - 3, y: sat.y - 2, width: 6, height: 4), cornerRadius: 1),
                 with: .color(.white))
    }

    // MARK: Accessibility (spatial audio)

    private func drawAccessibility(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = size.width, h = size.height
        let violet = theme.accent
        let c = CGPoint(x: w * 0.5, y: h * 0.50)

        // Expanding rings
        for ringi in 0..<4 {
            let ph = ((t * 0.6 + Double(ringi) * 0.35).truncatingRemainder(dividingBy: 1.4)) / 1.4
            var rc = ctx; rc.opacity = (1 - ph) * 0.5
            rc.stroke(circlePath(c, CGFloat(ph) * h * 0.5), with: .color(violet), lineWidth: 1.4)
        }
        // Pulsing core
        let pulse = 1 + 0.3 * sin(t * 3)
        ctx.fill(circlePath(c, 6),
                 with: .radialGradient(Gradient(colors: [violet, violet.opacity(0.4)]),
                                       center: c, startRadius: 0, endRadius: 8 * CGFloat(pulse)))
        ctx.fill(circlePath(c, 3.5), with: .color(.white))

        // Waveform strip
        let by = h * 0.9
        let bars = 22
        var wf = ctx; wf.opacity = 0.6
        for i in 0..<bars {
            let x = w * (0.1 + 0.8 * Double(i) / Double(bars - 1))
            let amp = (h * 0.06) * abs(sin(t * 3 + Double(i) * 0.5))
            var bp = Path(); bp.move(to: CGPoint(x: x, y: by - amp)); bp.addLine(to: CGPoint(x: x, y: by + amp))
            wf.stroke(bp, with: .color(violet.opacity(0.7)), lineWidth: 2)
        }
    }
}

#Preview("Aircraft") {
    NavigationStack {
        SettingsScaffold(theme: .aircraft, title: "Aircraft") {
            ForEach(0..<6) { _ in
                RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.05)).frame(height: 60)
            }
        }
    }
}

#Preview("Calibration") {
    NavigationStack {
        SettingsScaffold(theme: .calibration, title: "Calibration") {
            RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.05)).frame(height: 400)
        }
    }
}
