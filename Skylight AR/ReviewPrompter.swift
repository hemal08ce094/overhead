//
//  ReviewPrompter.swift
//  Skylight AR
//
//  Gate logic for the App Store rating prompt. The system prompt fires at one
//  genuinely good moment — admiring a freshly earned medal — and only for
//  users who are invested (several flights over several nights), never in the
//  first session, and at most once every four months. Apple caps the prompt
//  at three shows a year regardless; these gates keep us well inside that and
//  make sure the ask lands when the user is happiest.
//

import Foundation

enum ReviewGate {
    static let appStoreID = "6782262384"
    private static let lastAskKey = "review.lastAskAt"

    /// True when the user is invested and we haven't asked recently.
    @MainActor
    static func shouldAsk(spots: Int, nights: Int) -> Bool {
        guard spots >= 5, nights >= 2 else { return false }
        if let last = UserDefaults.standard.object(forKey: lastAskKey) as? Date,
           Date().timeIntervalSince(last) < 120 * 86_400 {
            return false
        }
        return true
    }

    @MainActor
    static func recordAsk() {
        UserDefaults.standard.set(Date(), forKey: lastAskKey)
    }

    /// Deep link straight into the App Store review sheet, for the explicit
    /// "Rate Overhead" row in About — always available, never rate-limited.
    static var writeReviewURL: URL {
        URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")!
    }
}
