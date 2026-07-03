//
//  OverheadFetch.swift
//  SkylightWidgets
//
//  Lets the widget refresh on its own — even if the app hasn't run for hours.
//  A deliberately minimal mirror of the app's `ADSBClient` (airplanes.live v2)
//  and `SkyMath.azElRange`: just enough to count airborne traffic around a point
//  and find the nearest one. The app and widget targets use Xcode synchronized
//  folders, so — as with `FlightActivityAttributes` and `SkyGlanceSnapshot` —
//  the shared shape is mirrored here rather than compiled from one file.
//

import Foundation

enum OverheadFetch {

    /// Fetch live traffic around (lat, lon) and reduce it to a glance snapshot.
    /// Returns nil on any network/decoding failure so the caller can fall back
    /// to the last stored snapshot.
    static func glance(lat: Double, lon: Double, radiusNm: Int = 40) async -> SkyGlanceSnapshot? {
        let r = min(max(radiusNm, 1), 250)
        guard let url = URL(string: "https://api.airplanes.live/v2/point/\(lat)/\(lon)/\(r)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }

        var count = 0
        var nearest: SkyGlanceSnapshot.Plane?
        var nearestRange = Double.greatestFiniteMagnitude

        for a in decoded.records {
            guard let alat = a.lat, let alon = a.lon else { continue }
            if a.alt_baro?.isGround ?? false { continue }          // airborne only
            let altFeet = a.alt_geom ?? a.alt_baro?.feet ?? 0
            let g = azElRange(obsLat: lat, obsLon: lon, obsAltM: 0,
                              tgtLat: alat, tgtLon: alon, tgtAltM: altFeet * 0.3048)
            count += 1
            if g.range < nearestRange {
                nearestRange = g.range
                let cs = a.flight?.trimmingCharacters(in: .whitespaces)
                nearest = SkyGlanceSnapshot.Plane(
                    callsign: (cs?.isEmpty == false) ? cs : nil,
                    type: a.t, destination: nil,          // route lookup lives in the app
                    distanceNm: g.range / 1852,
                    altitudeFeet: altFeet,
                    bearingDeg: g.azimuth, elevationDeg: g.elevation)
            }
        }

        return SkyGlanceSnapshot(updated: Date(), count: count, offline: false,
                                 nearest: nearest, observerLat: lat, observerLon: lon)
    }

    // MARK: - Decoding (subset of the readsb schema shared by airplanes.live)

    private struct Response: Decodable {
        let ac: [Raw]?
        let aircraft: [Raw]?
        var records: [Raw] { ac ?? aircraft ?? [] }
    }

    private struct Raw: Decodable {
        let lat: Double?
        let lon: Double?
        let alt_baro: AltBaro?
        let alt_geom: Double?
        let flight: String?
        let t: String?
    }

    /// `alt_baro` is either a number (feet) or the string `"ground"`.
    private enum AltBaro: Decodable {
        case feet(Double)
        case ground
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .feet(d) } else { self = .ground }
        }
        var isGround: Bool { if case .ground = self { return true }; return false }
        var feet: Double? { if case .feet(let f) = self { return f }; return nil }
    }

    // MARK: - Geometry (mirror of SkyMath.azElRange, tuple-based, no SIMD)

    /// Azimuth (deg from north, clockwise), elevation (deg), range (m).
    private static func azElRange(obsLat: Double, obsLon: Double, obsAltM: Double,
                                  tgtLat: Double, tgtLon: Double, tgtAltM: Double)
        -> (azimuth: Double, elevation: Double, range: Double) {
        let o = ecef(obsLat, obsLon, obsAltM)
        let t = ecef(tgtLat, tgtLon, tgtAltM)
        let lat = obsLat * .pi / 180, lon = obsLon * .pi / 180
        let sinLat = sin(lat), cosLat = cos(lat), sinLon = sin(lon), cosLon = cos(lon)
        let dx = t.0 - o.0, dy = t.1 - o.1, dz = t.2 - o.2
        let east  = -sinLon * dx + cosLon * dy
        let north = -sinLat * cosLon * dx - sinLat * sinLon * dy + cosLat * dz
        let up    =  cosLat * cosLon * dx + cosLat * sinLon * dy + sinLat * dz
        let range = (east * east + north * north + up * up).squareRoot()
        guard range > 0 else { return (0, 0, 0) }
        var az = atan2(east, north) * 180 / .pi
        if az < 0 { az += 360 }
        let el = asin(up / range) * 180 / .pi
        return (az, el, range)
    }

    /// Geodetic (deg, deg, m) → ECEF (m) on the WGS84 ellipsoid.
    private static func ecef(_ latDeg: Double, _ lonDeg: Double, _ altM: Double) -> (Double, Double, Double) {
        let a = 6_378_137.0, f = 1.0 / 298.257_223_563
        let e2 = f * (2 - f)
        let lat = latDeg * .pi / 180, lon = lonDeg * .pi / 180
        let sinLat = sin(lat), cosLat = cos(lat)
        let n = a / (1 - e2 * sinLat * sinLat).squareRoot()
        return ((n + altM) * cosLat * cos(lon),
                (n + altM) * cosLat * sin(lon),
                (n * (1 - e2) + altM) * sinLat)
    }
}
