//
//  Analytics.swift
//  Skylight AR
//
//  Privacy-preserving, aggregate product analytics via TelemetryDeck's ingest
//  API — no third-party SDK, no advertising identifier, no personal data. We
//  send only an anonymous per-install hash so we can see *what features are
//  used and liked*, never who used them. This keeps the App Store "no tracking"
//  claim honest (TelemetryDeck is non-tracking by Apple's definition).
//
//  Fully inert (zero network) until `appID` and `namespace` are filled in, and
//  it honours a user opt-out. Because this folder is a synchronized group, this
//  file joins the app target automatically — no project-file changes needed.
//

import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

enum Analytics {

    // MARK: - Configuration
    // Paste these two values from your TelemetryDeck dashboard (Settings → app).
    // Until BOTH are non-empty, nothing is ever sent.
    private static let appID     = ""   // e.g. "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private static let namespace = ""   // your organisation's namespace slug

    private static let ingestBase = "https://nom.telemetrydeck.com/v2/namespace/"
    private static let optOutKey  = "analyticsOptOut"
    private static let installKey = "analyticsInstallID"

    /// Off if unconfigured or the user has opted out.
    static var isEnabled: Bool {
        !appID.isEmpty && !namespace.isEmpty
            && !UserDefaults.standard.bool(forKey: optOutKey)
    }

    /// Wire a Settings toggle to this so users can turn analytics off.
    static func setOptedOut(_ optedOut: Bool) {
        UserDefaults.standard.set(optedOut, forKey: optOutKey)
    }
    static var isOptedOut: Bool { UserDefaults.standard.bool(forKey: optOutKey) }

    // MARK: - Identity (anonymous)

    /// Stable-per-install, but not a person: a random UUID minted once and stored
    /// locally, then SHA-256 hashed. No account, no IDFA, no reversible ID.
    private static let clientUser: String = {
        let d = UserDefaults.standard
        let raw = d.string(forKey: installKey) ?? {
            let fresh = UUID().uuidString
            d.set(fresh, forKey: installKey)
            return fresh
        }()
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }()

    /// One id per launch, so sessions can be counted without identifying anyone.
    private static let sessionID = UUID().uuidString

    private static var defaultPayload: [String: String] {
        var p: [String: String] = ["locale": Locale.current.identifier]
        let info = Bundle.main.infoDictionary
        if let v = info?["CFBundleShortVersionString"] as? String { p["appVersion"] = v }
        if let b = info?["CFBundleVersion"] as? String { p["buildNumber"] = b }
        #if canImport(UIKit)
        p["osVersion"] = UIDevice.current.systemVersion
        p["systemName"] = UIDevice.current.systemName
        #endif
        return p
    }

    // MARK: - Sending

    /// Call once at launch.
    static func start() { log("App.launched") }

    /// Fire-and-forget a named signal with optional string parameters. Safe from
    /// any thread; never blocks the UI and silently drops on failure.
    static func log(_ type: String, _ params: [String: String] = [:]) {
        guard isEnabled, let url = URL(string: ingestBase + namespace + "/") else { return }
        let payload = defaultPayload.merging(params) { _, new in new }
        let signal: [String: Any] = [
            "appID": appID,
            "clientUser": clientUser,
            "sessionID": sessionID,
            "type": type,
            "payload": payload,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: [signal]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }
}
