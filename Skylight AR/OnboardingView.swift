//
//  OnboardingView.swift
//  Skylight AR
//
//  First run: three beats over one continuous night — the promise, location,
//  camera — then the sky itself. The structure is Apple's welcome-flow
//  grammar: a hero with feature rows, then permission priming with an honest
//  footnote, page dots and a fixed action area so nothing jumps between
//  beats. The beats live on a real pager: they track the finger 1:1, rubber-
//  band at the ends, and a release projects momentum to pick the snap — so
//  revisiting an earlier page is one swipe, never a dead end. The material
//  stays ours: advancing bursts the words into star-motes, and the scene's
//  camera — not a slide deck — carries you forward.
//

import SwiftUI
import CoreLocation
import AVFoundation

struct OnboardingView: View {
    var permissions: PermissionsModel
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var page = {
        #if DEBUG
        if let p = ShotScreen.current?.onboardingPage { return p }
        #endif
        return 0
    }()
    @State private var appear = false
    /// The welcome feature rows cascade in once, after the hero settles.
    @State private var rowsShown = false
    /// Increments on every advance; each value plays one mote burst.
    @State private var burst = 0
    /// Set on finish: the photographs fade as the real sky arrives.
    @State private var finaleStart: Date?

    // Pager: the finger's live offset, and whether a drag is in flight.
    // dragActive is GestureState so a system-cancelled drag still resets.
    @State private var dragX: CGFloat = 0
    @GestureState private var dragActive = false
    /// Last known page width, for settling a drag the system cancelled.
    @State private var pageWidth: CGFloat = 390

    /// Live pager position in beats (0…2) — photos crossfade with the finger,
    /// not on page-commit, so the backdrop belongs to the drag like everything
    /// else in the app.
    private var pageProgress: CGFloat {
        CGFloat(page) - dragX / max(pageWidth, 1)
    }

    /// One real photograph per beat: a lunar transit for the promise, the
    /// crescent for place, a daylight crossing for the camera. `overscan`
    /// renders the photo taller than the screen and `anchor` chooses which
    /// slice survives — the camera shot is landscape with its subject centred,
    /// so a 1.35× overscan anchored .bottom lifts the plane into the top
    /// third, clear of the words.
    /// NOTE: verify the license of every shipped photo before release —
    /// these arrived as "open source" but at least one is a credited
    /// photographer's transit shot. Swapping a file in the imageset changes
    /// nothing here.
    private static let beatPhotos: [(name: String, overscan: CGFloat, anchor: Alignment)] = [
        ("OnboardingHero", 1.0, .center),
        ("OnboardingPlace", 1.0, .center),
        ("OnboardingCamera", 1.35, .bottom),
    ]

    var body: some View {
        ZStack {
            Theme.skyGradient.ignoresSafeArea()
            // Real sky photographs behind the three beats, cross-blended by
            // the live pager position with a whisper of parallax.
            GeometryReader { geo in
                ZStack {
                    ForEach(Array(Self.beatPhotos.enumerated()), id: \.offset) { i, photo in
                        let distance = pageProgress - CGFloat(i)
                        let weight = max(0, 1 - abs(distance))
                        if weight > 0 {
                            Image(photo.name)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width,
                                       height: geo.size.height * photo.overscan)
                                .offset(x: reduceMotion ? 0 : -distance * 36)
                                .frame(width: geo.size.width, height: geo.size.height,
                                       alignment: photo.anchor)
                                .clipped()
                                .opacity(weight)
                        }
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            // The finale fades the photographs back into the app's own night
            // as the real sky arrives beneath.
            .opacity(finaleStart == nil ? 1 : 0)
            .animation(.easeIn(duration: 0.4), value: finaleStart != nil)
            // Legibility scrim: day photos are bright — hold the words and the
            // status bar against them without flattening the picture.
            LinearGradient(stops: [
                .init(color: Theme.nightBottom.opacity(0.35), location: 0),
                .init(color: .clear, location: 0.22),
                .init(color: .clear, location: 0.45),
                .init(color: Theme.nightBottom.opacity(0.82), location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // The pager. The action area below never moves, so the
                // primary button is always where the thumb last found it.
                GeometryReader { geo in
                    let w = geo.size.width
                    HStack(spacing: 0) {
                        pageColumn(w) { welcome }
                        pageColumn(w) { locationStep }
                        pageColumn(w) { cameraStep }
                    }
                    .offset(x: -CGFloat(page) * w + dragX)
                    .contentShape(Rectangle())
                    .gesture(pagerDrag(width: w))
                }

                actionArea
                    .padding(.horizontal, 30)
                    .frame(maxWidth: 480)
            }
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 14)
            .blur(radius: appear ? 0 : 6)

            if burst > 0 {
                StarBurst().id(burst)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.impact(weight: .light), trigger: page)
        .sensoryFeedback(.success, trigger: permissions.locationGranted) { _, new in new }
        .sensoryFeedback(.success, trigger: permissions.cameraGranted) { _, new in new }
        // A cancelled drag (system gesture, incoming call) never reaches
        // onEnded — settle from wherever the finger left things.
        .onChange(of: dragActive) { _, active in
            if !active, dragX != 0 {
                settle(width: pageWidth, predicted: dragX, velocity: 0)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) { appear = true }
            rowsShown = true
        }
        // Advance automatically once a step's permission resolves.
        .onChange(of: permissions.location) { _, _ in
            if page == 1, permissions.location != .notDetermined { advance() }
        }
        // Camera resolved (granted or denied) — the sky is next either way.
        .onChange(of: permissions.camera) { _, _ in
            if page == 2, permissions.camera != .notDetermined { finish() }
        }
    }

    // MARK: Pager

    private func pageColumn<V: View>(_ width: CGFloat,
                                     @ViewBuilder content: () -> V) -> some View {
        content()
            .padding(.horizontal, 30)
            .frame(maxWidth: 480)
            .frame(width: width)
    }

    private func pagerDrag(width: CGFloat) -> some Gesture {
        // ~12 pt of hysteresis before the pager claims the touch.
        DragGesture(minimumDistance: 12)
            .updating($dragActive) { _, state, _ in state = true }
            .onChanged { v in
                guard finaleStart == nil else { return }
                pageWidth = width
                let x = rubberbanded(v.translation.width, width: width)
                dragX = min(width, max(-width, x))
            }
            .onEnded { v in
                guard finaleStart == nil else { return }
                settle(width: width,
                       predicted: v.predictedEndTranslation.width,
                       velocity: v.velocity.width)
            }
    }

    /// Past either end the night resists progressively instead of stopping
    /// hard — there's nothing further, but the interface is still listening.
    private func rubberbanded(_ x: CGFloat, width: CGFloat) -> CGFloat {
        guard (page == 0 && x > 0) || (page == 2 && x < 0) else { return x }
        let c: CGFloat = 0.55
        return x * c * width / (width + c * abs(x))
    }

    /// Release: project the gesture's momentum to a resting point, snap to
    /// the nearest beat, and hand the finger's velocity to the spring so
    /// there is no seam between dragging and animating.
    private func settle(width: CGFloat, predicted: CGFloat, velocity: CGFloat) {
        var target = page
        if predicted < -width / 2 { target = min(page + 1, 2) }
        else if predicted > width / 2 { target = max(page - 1, 0) }
        if target > page { burst += 1 }                 // words → star-motes

        let from = -CGFloat(page) * width + dragX
        let to = -CGFloat(target) * width
        let rel = to == from ? 0 : Double(velocity / (to - from))
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 280, damping: 28,
                                           initialVelocity: rel)) {
            page = target
            dragX = 0
        }
    }

    // MARK: Beats

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("Welcome to").kicker
            Text(verbatim: "Overhead")
                .font(Theme.display(52, .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 20) {
                featureRow(0, "airplane", Theme.accent,
                           "Every flight overhead",
                           "Point at a plane to see its route, aircraft and destination.")
                featureRow(1, "moon.stars.fill", Theme.gold,
                           "The living sky",
                           "Sun, moon, planets and stars — exactly where they truly are.")
                featureRow(2, "camera.viewfinder", Theme.moonlight,
                           "Through your camera",
                           "Hold up your phone and see it all placed on the real sky.")
            }
            .padding(22)
            .nightCard(cornerRadius: 24)
            .padding(.top, 32)
            Spacer()
        }
    }

    private var locationStep: some View {
        VStack(spacing: 0) {
            Spacer()
            PermissionBadge(symbol: "location.fill")
            Text("Your place under the sky")
                .font(Theme.display(32, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 26)
            Text("Overhead uses your location to compute exactly where each aircraft and celestial object sits above you.")
                .font(Theme.display(16, .regular))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 12)
            Spacer()
            footnote("lock.fill",
                     "Used only while the app is open. You can change this anytime in Settings.")
                .padding(.bottom, 18)
        }
    }

    private var cameraStep: some View {
        VStack(spacing: 0) {
            Spacer()
            PermissionBadge(symbol: "camera.fill")
            Text("See through to the real sky")
                .padding(.top, 26)
                .font(Theme.display(32, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("The camera places aircraft and stars onto your live sky in augmented reality. Prefer not to? A low-power dark-sky mode works too.")
                .font(Theme.display(16, .regular))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 12)
            Spacer()
            footnote("sparkles",
                     "Best outdoors, under open sky. If a plane sits a little off, tap it to snap everything into place.")
                .padding(.bottom, 18)
        }
    }

    // MARK: Pieces

    /// One What's-New-style row: a tinted symbol and two lines of type.
    /// Rows cascade in on first appearance — the hero speaks, then the
    /// promises arrive one by one.
    private func featureRow(_ index: Int, _ symbol: String, _ tint: Color,
                            _ title: LocalizedStringKey,
                            _ detail: LocalizedStringKey) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.display(16, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.display(14, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .opacity(rowsShown ? 1 : 0)
        .offset(y: rowsShown || reduceMotion ? 0 : 14)
        .animation(.spring(response: 0.6, dampingFraction: 0.85)
                    .delay(0.3 + Double(index) * 0.12), value: rowsShown)
    }

    /// Small print under a permission ask — honest, quiet, with its own mark.
    private func footnote(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.display(12.5, .regular))
                .lineSpacing(3)
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 6)
    }

    /// Dots + primary + secondary, fixed at the bottom of every beat. The
    /// secondary slot is height-reserved when there is nothing to skip, so
    /// the primary button never shifts.
    private var actionArea: some View {
        VStack(spacing: 0) {
            PageDots(current: page) { goTo($0) }
                .padding(.bottom, 24)
            Button(primaryTitle) { primaryAction() }
                .buttonStyle(PrimaryButtonStyle())
            secondaryButton
                .padding(.top, 8)
        }
        .padding(.bottom, 16)
    }

    private var primaryTitle: String {
        switch page {
        case 0:
            return String(localized: "Continue")
        case 1:
            if permissions.locationDenied { return String(localized: "Open Settings") }
            if permissions.locationGranted { return String(localized: "Continue") }
            return String(localized: "Enable Location")
        default:
            if permissions.cameraDenied { return String(localized: "Open Settings") }
            if permissions.cameraGranted { return String(localized: "Continue") }
            return String(localized: "Enable Camera")
        }
    }

    private func primaryAction() {
        switch page {
        case 0:
            advance()
        case 1:
            // Revisited after granting: the ask is done, just move on.
            // Once denied, requesting again is a no-op — route the primary
            // action to Settings and keep a way forward so nobody gets stuck.
            if permissions.locationGranted { advance() }
            else if permissions.locationDenied { openSettings() }
            else { permissions.requestLocation() }
        default:
            if permissions.cameraGranted { finish() }
            else if permissions.cameraDenied { openSettings() }
            else { Task { await permissions.requestCamera() } }
        }
    }

    @ViewBuilder private var secondaryButton: some View {
        switch page {
        case 0:
            secondaryPlaceholder
        case 1:
            if permissions.locationGranted {
                secondaryPlaceholder
            } else {
                Button(permissions.locationDenied ? String(localized: "Continue with demo sky")
                                                  : String(localized: "Not now")) { advance() }
                    .buttonStyle(GhostButtonStyle())
            }
        default:
            if permissions.cameraGranted {
                secondaryPlaceholder
            } else {
                Button("Skip — use dark sky") { finish() }
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }

    /// Slot keeper: same height as a ghost button, nothing to do.
    private var secondaryPlaceholder: some View {
        Button("Not now") {}
            .buttonStyle(GhostButtonStyle())
            .hidden()
    }

    // MARK: Flow

    private func advance() {
        goTo(page + 1)
    }

    private func goTo(_ target: Int) {
        let clamped = min(max(target, 0), 2)
        guard clamped != page else { return }
        if clamped > page { burst += 1 }             // words → star-motes
        withAnimation(.spring(response: 0.55, dampingFraction: 0.9)) { page = clamped }
    }

    private func finish() {
        // The finale: words fade, the whole night dissolves into star-motes,
        // and the real sky is already arriving beneath them.
        finaleStart = Date()
        withAnimation(.easeIn(duration: 0.28)) { appear = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { onFinished() }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

private extension Text {
    /// Quiet tracked-caps lead-in above a hero title.
    var kicker: some View {
        font(Theme.display(12, .semibold))
            .tracking(3)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textTertiary)
    }
}

// MARK: - Page dots

/// The standard progress affordance, in the app's palette: the current beat
/// stretches into a small capsule and springs between positions. Dots are
/// also targets — tapping one travels there, same as swiping.
private struct PageDots: View {
    var current: Int
    var count: Int = 3
    var jump: (Int) -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Theme.textPrimary : .white.opacity(0.28))
                    .frame(width: i == current ? 22 : 7, height: 7)
                    .contentShape(Rectangle().inset(by: -10))
                    .onTapGesture { jump(i) }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: current)
        .accessibilityElement()
        .accessibilityLabel(Text("Step \(current + 1) of \(count)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: jump(current + 1)
            case .decrement: jump(current - 1)
            @unknown default: break
            }
        }
    }
}

// MARK: - Permission badge

/// A permission beat opens with the ask made visible: the symbol breathing
/// inside a small liquid-glass orb — an invitation, not a demand.
private struct PermissionBadge: View {
    var symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(Theme.accent)
            .symbolEffect(.breathe)
            .frame(width: 74, height: 74)
            .background {
                Circle().fill(RadialGradient(
                    colors: [Theme.accent.opacity(0.28), .clear],
                    center: .center, startRadius: 2, endRadius: 44))
            }
            .glassEffect(.clear, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .shadow(color: Theme.accent.opacity(0.35), radius: 22)
            .accessibilityHidden(true)
    }
}

// MARK: - Mote burst (one-shot)

/// The page-turn: a breath of star-motes rising from where the words were,
/// swirling apart and fading — content dissolving into night sky. Plays once
/// per identity (`.id(burst)`) and renders nothing when done or under
/// Reduce Motion. Pure function of its start instant; no per-frame state.
private struct StarBurst: View {
    var tint: Color = Theme.gold
    var count: Int = 64
    var duration: Double = 0.85

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { tl in
                Canvas { ctx, size in
                    let p = tl.date.timeIntervalSince(start) / duration
                    guard p < 1 else { return }
                    let cx = size.width / 2, cy = size.height * 0.44
                    for i in 0..<count {
                        var h = UInt64(i) &* 0x9E3779B97F4A7C15
                        func rnd() -> Double {
                            h ^= h >> 12; h ^= h << 25; h ^= h >> 27
                            return Double((h &* 2685821657736338717) >> 40) / Double(1 << 24)
                        }
                        let r0 = rnd(), r1 = rnd(), r2 = rnd(), r3 = rnd()
                        // Born scattered where the content sat, then rising
                        // and drifting apart on a gentle spiral.
                        let delay = r0 * 0.25
                        let u = min(max((p - delay) / (1 - delay), 0), 1)
                        let e = 1 - pow(1 - u, 2.2)
                        let bornX = cx + (r1 - 0.5) * size.width * 0.62
                        let bornY = cy + (r2 - 0.5) * size.height * 0.34
                        let ang = -.pi / 2 + (r3 - 0.5) * 1.5
                        let dist = e * (46 + r2 * 90)
                        let x = bornX + cos(ang) * dist + sin(u * 6 + r1 * 6.28) * 3
                        let y = bornY + sin(ang) * dist
                        let a = sin(.pi * u) * (0.3 + 0.55 * r3)
                        let spark = i % 5 == 0
                        let s = (spark ? 1.6 : 1.1) + r2 * 1.8
                        ctx.fill(Path(ellipseIn: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)),
                                 with: .color((spark ? Color.white : tint).opacity(a)))
                    }
                }
            }
        }
    }
}

// MARK: - Decorative marks

/// A crescent moon orb in liquid glass — the starfield refracts through the
/// glass while a soft lit limb and dark terminator shade the crescent inside.
/// (Shared: the sky screen and voyage scene both place it.)
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
