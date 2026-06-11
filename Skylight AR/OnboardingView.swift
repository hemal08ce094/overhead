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

    @State private var page = 0
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
                PageDots(count: 3, index: page)
                    .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { animateIn() }
        // Advance automatically once a step's permission resolves.
        .onChange(of: permissions.location) { _, _ in
            if page == 1, permissions.location != .notDetermined { advance() }
        }
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

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 22) {
            MoonMark().frame(width: 116, height: 116)
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
        PrimingCard(
            icon: "location.fill",
            title: "Your place under the sky",
            message: "Overhead uses your location to compute exactly where each aircraft and celestial object sits above you.",
            primary: "Enable Location",
            action: { permissions.requestLocation() },
            skipTitle: permissions.locationDenied ? "Open Settings" : "Not now",
            skipAction: { permissions.locationDenied ? openSettings() : advance() })
    }

    private var cameraStep: some View {
        PrimingCard(
            icon: "camera.fill",
            title: "See through to the real sky",
            message: "The camera lets Overhead place aircraft and stars onto the live sky in augmented reality. You can also use a low-power dark-sky mode.",
            primary: "Enable Camera",
            action: { Task { await permissions.requestCamera() } },
            skipTitle: "Skip — use dark sky",
            skipAction: { finish() })
    }

    // MARK: Flow

    private func animateIn() {
        appear = false
        withAnimation(.easeOut(duration: 0.6)) { appear = true }
    }

    private func advance() {
        withAnimation(.easeOut(duration: 0.25)) { appear = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            page = min(page + 1, 2)
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

private struct PrimingCard: View {
    let icon: String
    let title: String
    let message: String
    let primary: String
    let action: () -> Void
    let skipTitle: String
    let skipAction: () -> Void

    var body: some View {
        GlassCard {
            VStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Theme.accent.opacity(0.12)))
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
