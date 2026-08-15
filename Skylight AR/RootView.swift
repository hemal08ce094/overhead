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

    init() {
        var screenshotRun = false
        #if DEBUG
        ShotScreen.applyPreconditions()
        screenshotRun = ShotScreen.current != nil
        #endif
        _showIntro = State(initialValue:
            UserDefaults.standard.bool(forKey: "didOnboard") && !screenshotRun)
    }

    var body: some View {
        ZStack {
            // Onboarding completion alone decides entry: the AR screen requests
            // location itself, so "Not now" there can't strand the user here.
            // Denial lands in the demo sky instead of a dead end.
            if didOnboard {
                ARSkyScreen()
                    .transition(.opacity)
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
