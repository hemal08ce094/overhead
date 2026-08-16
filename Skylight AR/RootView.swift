//
//  RootView.swift
//  Skylight AR
//
//  Top-level flow: onboarding/permission priming until location is granted,
//  then the live AR sky.
//

import SwiftUI
import CoreLocation

struct RootView: View {
    @State private var permissions = PermissionsModel()
    @AppStorage("didOnboard") private var didOnboard = false
    /// The cold-launch entrance plays only when this launch starts already
    /// onboarded — first runs get onboarding's own finale instead — and never
    /// under the screenshot harness. Captured at init so finishing onboarding
    /// mid-session can't retrigger it.
    @State private var showIntro: Bool
    /// Sky Scan is home; the AR sky opens above it and closes back to it.
    /// Screenshot runs land straight in AR so the shot harness keeps working.
    @State private var showAR: Bool

    init() {
        var screenshotRun = false
        #if DEBUG
        ShotScreen.applyPreconditions()
        screenshotRun = ShotScreen.current != nil
        #endif
        _showIntro = State(initialValue:
            UserDefaults.standard.bool(forKey: "didOnboard") && !screenshotRun)
        _showAR = State(initialValue: screenshotRun)
    }

    var body: some View {
        ZStack {
            // Onboarding completion alone decides entry: the AR screen requests
            // location itself, so "Not now" there can't strand the user here.
            // Denial lands in the demo sky instead of a dead end.
            if didOnboard {
                Group {
                    if showAR {
                        ARSkyScreen()
                            // The way back to the scope, floating over the AR
                            // chrome. Bottom-right — clear of the chrome-cluster
                            // orb (top-left) and the status pill (bottom-left).
                            .overlay(alignment: .bottomTrailing) {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.35)) { showAR = false }
                                } label: {
                                    Image(systemName: "dot.scope")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .frame(width: 38, height: 38)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("Back to Sky Scan"))
                                .padding(.trailing, 16)
                                .padding(.bottom, 24)
                            }
                            .transition(.opacity)
                    } else {
                        SkyScanHome {
                            withAnimation(.easeInOut(duration: 0.35)) { showAR = true }
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: showAR)
                .overlay {
                    // AR warms up beneath the entrance, so the dissolve
                    // lands on a live sky, not a camera feed still waking.
                    // A bundled LaunchSplash.mp4 (owned/licensed footage
                    // only) takes over from the drawn entrance.
                    if showIntro {
                        if let splash = LaunchVideoView.bundledURL {
                            LaunchVideoView(url: splash) { showIntro = false }
                        } else {
                            LaunchIntroView { showIntro = false }
                        }
                    }
                }
            } else {
                OnboardingView(permissions: permissions) {
                    withAnimation(.easeInOut(duration: 0.5)) { didOnboard = true }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: didOnboard)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    RootView()
}
