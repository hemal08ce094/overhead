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

    init() {
        #if DEBUG
        ShotScreen.applyPreconditions()
        #endif
    }

    var body: some View {
        ZStack {
            // Onboarding completion alone decides entry: the AR screen requests
            // location itself, so "Not now" there can't strand the user here.
            // Denial lands in the demo sky instead of a dead end.
            if didOnboard {
                ARSkyScreen()
                    .transition(.opacity)
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
