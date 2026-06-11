//
//  RootView.swift
//  Skylight AR
//
//  Top-level flow: onboarding/permission priming until location is granted,
//  then the live AR sky.
//

import SwiftUI

struct RootView: View {
    @State private var permissions = PermissionsModel()
    @AppStorage("didOnboard") private var didOnboard = false

    var body: some View {
        ZStack {
            if didOnboard && permissions.locationGranted {
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
        .animation(.easeInOut(duration: 0.5), value: permissions.locationGranted)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    RootView()
}
