//
//  ScreenshotHooks.swift
//  Skylight AR
//
//  DEBUG-only launch-argument hooks for deterministic App Store screenshot
//  capture (the fastlane-snapshot pattern). Pass e.g. `-shot events` when
//  launching in the simulator to jump straight to a given screen. Entirely
//  compiled out of Release builds, so it never ships.
//

#if DEBUG
import Foundation

enum ShotScreen: String {
    case onboard0, onboard1, onboard2
    case sky, events, profile, search

    /// Reads the `-shot <name>` launch argument (parsed into UserDefaults).
    static var current: ShotScreen? {
        guard let v = UserDefaults.standard.string(forKey: "shot") else { return nil }
        return ShotScreen(rawValue: v)
    }

    /// Onboarding page index for the onboarding shots, else nil.
    var onboardingPage: Int? {
        switch self {
        case .onboard0: return 0
        case .onboard1: return 1
        case .onboard2: return 2
        default: return nil
        }
    }

    /// Force the right entry point: onboarding shots show onboarding, in-app
    /// shots skip it. Order-independent across successive launches.
    static func applyPreconditions() {
        guard let s = current else { return }
        UserDefaults.standard.set(s.onboardingPage == nil, forKey: "didOnboard")
    }
}
#endif
