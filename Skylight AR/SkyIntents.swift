//
//  SkyIntents.swift
//  Skylight AR
//
//  Siri / Shortcuts: "What's flying over me?" — answers with live traffic at
//  the last place the app saw you, no UI needed.
//

import AppIntents
import Foundation

struct WhatsFlyingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Flying Over Me"
    static let description = IntentDescription("Counts the aircraft overhead and names the nearest one.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let defaults = UserDefaults.standard
        let lat = defaults.double(forKey: SkyDefaults.lastLat)
        let lon = defaults.double(forKey: SkyDefaults.lastLon)
        guard lat != 0 || lon != 0 else {
            return .result(dialog: "Open Overhead once so I can learn where your sky is.")
        }
        // A fetch failure must not read as "quiet sky" — that's a confident lie
        // when the network is simply down.
        guard let traffic = try? await FallbackSource.freeFeeds().aircraft(lat: lat, lon: lon, radiusNm: 40) else {
            return .result(dialog: "I couldn't reach the sky data just now — try again in a moment.")
        }
        let airborne = traffic.filter { !$0.onGround }
        guard !airborne.isEmpty else {
            return .result(dialog: "Your sky is quiet right now — no aircraft within forty nautical miles.")
        }
        let nearest = airborne.min { a, b in
            let ra = SkyMath.azElRange(observerLat: lat, observerLon: lon, observerAltM: 0,
                                       targetLat: a.lat, targetLon: a.lon, targetAltM: a.altitudeMeters).range
            let rb = SkyMath.azElRange(observerLat: lat, observerLon: lon, observerAltM: 0,
                                       targetLat: b.lat, targetLon: b.lon, targetAltM: b.altitudeMeters).range
            return ra < rb
        }!
        let range = SkyMath.azElRange(observerLat: lat, observerLon: lon, observerAltM: 0,
                                      targetLat: nearest.lat, targetLon: nearest.lon,
                                      targetAltM: nearest.altitudeMeters).range / 1852
        let name = nearest.callsign ?? String(localized: "an unidentified aircraft")
        let miles = Int(range.rounded())
        // Whole-sentence format strings (no glued fragments) so translators can
        // reorder freely; the English output is byte-identical to the old assembly.
        let countSentence = airborne.count == 1
            ? String(localized: "There is one aircraft above you.")
            : String(localized: "There are \(airborne.count) aircraft above you.")
        let nearestSentence = nearest.type.map { type in
            String(localized: "The nearest is \(name), a \(type), about \(miles) nautical miles away.")
        } ?? String(localized: "The nearest is \(name) about \(miles) nautical miles away.")
        return .result(dialog: "\(countSentence) \(nearestSentence)")
    }
}

struct SkylightShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhatsFlyingIntent(),
                    phrases: [
                        "What's flying over me in \(.applicationName)",
                        "Ask \(.applicationName) what's overhead",
                        "What's in the sky in \(.applicationName)",
                    ],
                    shortTitle: "What's overhead",
                    systemImageName: "airplane")
    }
}
