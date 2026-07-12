//
//  OnboardingView.swift
//  Skylight AR
//
//  First run, kept almost silent: three beats of typography over the night
//  gradient — the promise, location, camera — and then the sky itself.
//  No dioramas, no page dots, no tips essay. Each advance dissolves the
//  words into star-motes (the same particle language as the medal strike),
//  because in Overhead, interface becomes sky.
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
    /// Increments on every advance; each value plays one mote burst.
    @State private var burst = 0

    var body: some View {
        ZStack {
            Theme.skyGradient.ignoresSafeArea()
            Starfield().ignoresSafeArea().opacity(0.75)

            content
                .padding(.horizontal, 34)
                .frame(maxWidth: 480)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 14)
                .blur(radius: appear ? 0 : 6)

            if burst > 0 {
                StarBurst().id(burst)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { animateIn() }
        // Advance automatically once a step's permission resolves.
        .onChange(of: permissions.location) { _, _ in
            if page == 1, permissions.location != .notDetermined { advance() }
        }
        // Camera resolved (granted or denied) — the sky is next either way.
        .onChange(of: permissions.camera) { _, _ in
            if page == 2, permissions.camera != .notDetermined { finish() }
        }
    }

    @ViewBuilder private var content: some View {
        switch page {
        case 0: welcome
        case 1: locationStep
        default: cameraStep
        }
    }

    // MARK: Beats

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(verbatim: "1 · 3").kicker
            Text("Overhead")
                .font(Theme.display(52, .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 10)
            Text("Hold up your phone and see the planes,\nsun, moon and stars where they truly are.")
                .font(Theme.display(17, .regular))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 14)
            Spacer()
            Button("Begin") { advance() }
                .buttonStyle(PrimaryButtonStyle())
            Spacer().frame(height: 72)
        }
    }

    private var locationStep: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(verbatim: "2 · 3").kicker
            Text("Your place under the sky")
                .font(Theme.display(32, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            Text("Overhead uses your location to compute exactly where each aircraft and celestial object sits above you.")
                .font(Theme.display(16, .regular))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 14)
            Spacer()
            // Once denied, requesting again is a no-op — route the primary
            // action to Settings and keep a way forward so nobody gets stuck.
            Button(permissions.locationDenied ? String(localized: "Open Settings")
                                              : String(localized: "Enable Location")) {
                permissions.locationDenied ? openSettings() : permissions.requestLocation()
            }
            .buttonStyle(PrimaryButtonStyle())
            Button(permissions.locationDenied ? String(localized: "Continue with demo sky")
                                              : String(localized: "Not now")) { advance() }
                .buttonStyle(GhostButtonStyle())
                .padding(.top, 10)
            Spacer().frame(height: 62)
        }
    }

    private var cameraStep: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(verbatim: "3 · 3").kicker
            Text("See through to the real sky")
                .font(Theme.display(32, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            Text("The camera lets Overhead place aircraft and stars onto the live sky in augmented reality. You can also use a low-power dark-sky mode.")
                .font(Theme.display(16, .regular))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 14)
            Spacer()
            VStack(spacing: 8) {
                Text("Best outdoors, under open sky. If a plane sits a little off, tap it to snap everything into place.")
                Text("Every flight you spot counts — you begin as an Observer.")
            }
            .font(Theme.display(12.5, .regular))
            .foregroundStyle(Theme.textTertiary)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.bottom, 22)
            Button(permissions.cameraDenied ? String(localized: "Open Settings")
                                            : String(localized: "Enable Camera")) {
                if permissions.cameraDenied { openSettings() }
                else { Task { await permissions.requestCamera() } }
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Skip — use dark sky") { finish() }
                .buttonStyle(GhostButtonStyle())
                .padding(.top, 10)
            Spacer().frame(height: 62)
        }
    }

    // MARK: Flow

    private func animateIn() {
        appear = false
        withAnimation(.easeOut(duration: 0.55)) { appear = true }
    }

    private func advance() {
        burst += 1                                   // words → star-motes
        withAnimation(.easeIn(duration: 0.22)) { appear = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            page = min(page + 1, 2)
            animateIn()
        }
    }

    private func finish() {
        burst += 1
        withAnimation(.easeIn(duration: 0.28)) { appear = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { onFinished() }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

private extension Text {
    /// The beat counter — quiet, tracked-out, honest about the sequence.
    var kicker: some View {
        font(Theme.display(12, .semibold))
            .tracking(3)
            .foregroundStyle(Theme.textTertiary)
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
