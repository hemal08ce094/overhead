//
//  SkyGlance.swift
//  Skylight AR
//
//  The tiny bridge between the live app and its Home/Lock-Screen widgets.
//  The app writes a compact snapshot of "what's overhead right now" into the
//  shared App Group on each traffic refresh; the widget reads it back and
//  renders it. Keep `SkyGlanceSnapshot`'s coding shape identical to the mirror
//  in `SkylightWidgets/OverheadNowWidget.swift` — they talk through JSON.
//

import Foundation
import WidgetKit

/// A frozen glance of the sky, small enough to hand across the process boundary.
struct SkyGlanceSnapshot: Codable, Equatable {
    /// When the app last refreshed the feed — the widget shows freshness from this.
    var updated: Date
    /// Airborne aircraft currently placed in the sky.
    var count: Int
    /// The feed has been unreachable for a few ticks; the numbers are last-known.
    var offline: Bool
    /// The closest airborne contact, if any (nil = quiet sky).
    var nearest: Plane?
    /// Where the observer was — the seed the widget uses to refresh on its own.
    /// Optional so snapshots written before this field decode cleanly.
    var observerLat: Double?
    var observerLon: Double?

    struct Plane: Codable, Equatable {
        var callsign: String?      // may be blank on the feed
        var type: String?          // ICAO designator, e.g. "B738"
        var destination: String?   // route destination code, if resolved
        var distanceNm: Double
        var altitudeFeet: Double
        var bearingDeg: Double     // true-north bearing from the observer to the plane
        var elevationDeg: Double   // degrees above the horizon
    }
}

/// Shared-container read/write for the glance snapshot.
enum SkyGlance {
    static let appGroup = "group.hemal.Skylight-AR"
    static let key = "glance.v1"
    static let lastLatKey = "glance.lastLat"
    static let lastLonKey = "glance.lastLon"
    /// The widget kind — used by the app to nudge a timeline reload.
    static let widgetKind = "hemal.Skylight-AR.overheadNow"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func write(_ snapshot: SkyGlanceSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: key)
    }

    static func read() -> SkyGlanceSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SkyGlanceSnapshot.self, from: data)
    }

    /// Stash the latest known position so the widget can refresh even before the
    /// next snapshot is written (and even if it never opens the AR view again).
    static func writeLocation(lat: Double, lon: Double) {
        defaults?.set(lat, forKey: lastLatKey)
        defaults?.set(lon, forKey: lastLonKey)
    }
}
