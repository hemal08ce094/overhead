//
//  AppInfo.swift
//  Skylight AR
//
//  Single source of truth for the app's public identity: name, store links,
//  website, contact, and the share copy that mentions them. Marketing-facing
//  strings and URLs change here and nowhere else.
//

import Foundation

enum AppInfo {

    /// Public-facing app name, as used inside copy (the App Store listing
    /// name "Overhead : Skylight AR" lives in App Store Connect, not here).
    static let name = "Overhead"

    // MARK: Store

    static let appStoreID = "6782262384"

    static let appStoreURL = URL(string: "https://apps.apple.com/app/id\(appStoreID)")!

    /// Deep link straight into the App Store review sheet — always available,
    /// never rate-limited (unlike the in-app system prompt).
    static let writeReviewURL = URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")!

    // MARK: Web + contact

    /// Marketing site / referral landing page (hosted on Lovable for now —
    /// swap once a custom domain is attached).
    static let websiteURL = URL(string: "https://immaculate-display-copy.lovable.app")!

    static let feedbackEmail = "hemalmodi3@gmail.com"

    // MARK: Share copy

    /// The brag line for the native share sheet — proud, personal, and it
    /// names the app so the screenshot alone can sell it.
    static func tierShareMessage(tier: String, spots: Int) -> String {
        if spots > 0 {
            return String(localized: "I'm a \(tier) in \(name) — \(spots) flights spotted straight out of the sky above me. 🛩️✨ Think you can out-spot me?")
        } else {
            return String(localized: "I just joined \(name) — every plane, planet and star above me, labeled live in AR. 🛩️✨ Come look up with me.")
        }
    }
}
