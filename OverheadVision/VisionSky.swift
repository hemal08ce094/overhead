//
//  VisionSky.swift
//  OverheadVision
//
//  Self-contained sky engine for visionOS: location, traffic polling,
//  ephemeris, and the geometry that places everything on a room-scale dome.
//

import Foundation
import CoreLocation
import SwiftAA
import SatelliteKit
import simd

// MARK: - Math

enum VSkyMath {
    static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400.0 + 2_440_587.5
    }

    /// Azimuth/elevation/range to a target from the observer (degrees, meters).
    static func azElRange(observerLat: Double, observerLon: Double,
                          targetLat: Double, targetLon: Double, targetAltM: Double)
        -> (azimuth: Double, elevation: Double, range: Double) {
        func ecef(_ latDeg: Double, _ lonDeg: Double, _ altM: Double) -> SIMD3<Double> {
            let a = 6_378_137.0, e2 = 6.694_379_990_14e-3
            let lat = latDeg * .pi / 180, lon = lonDeg * .pi / 180
            let n = a / sqrt(1 - e2 * sin(lat) * sin(lat))
            return SIMD3((n + altM) * cos(lat) * cos(lon),
                         (n + altM) * cos(lat) * sin(lon),
                         (n * (1 - e2) + altM) * sin(lat))
        }
        let obs = ecef(observerLat, observerLon, 0)
        let d = ecef(targetLat, targetLon, targetAltM) - obs
        let lat = observerLat * .pi / 180, lon = observerLon * .pi / 180
        let east = -sin(lon) * d.x + cos(lon) * d.y
        let north = -sin(lat) * cos(lon) * d.x - sin(lat) * sin(lon) * d.y + cos(lat) * d.z
        let up = cos(lat) * cos(lon) * d.x + cos(lat) * sin(lon) * d.y + sin(lat) * d.z
        let range = simd_length(d)
        let azimuth = (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let elevation = asin(max(-1, min(1, up / range))) * 180 / .pi
        return (azimuth, elevation, range)
    }

    /// RealityKit position on the dome: x east, y up, -z north (radius meters).
    static func domePosition(azimuthDeg: Double, elevationDeg: Double,
                             radius: Double, northOffsetDeg: Double) -> SIMD3<Float> {
        let a = (azimuthDeg + northOffsetDeg) * .pi / 180
        let e = elevationDeg * .pi / 180
        return SIMD3(Float(radius * cos(e) * sin(a)),
                     Float(radius * sin(e)),
                     Float(-radius * cos(e) * cos(a)))
    }

    /// Equatorial → horizontal, same fast form as the iOS app.
    static func equatorialToHorizontal(raDeg: Double, decDeg: Double,
                                       latDeg: Double, lonDeg: Double,
                                       date: Date) -> (azimuth: Double, elevation: Double) {
        let d = julianDay(date) - 2_451_545.0
        let gmst = (280.460_618_37 + 360.985_647_366_29 * d).truncatingRemainder(dividingBy: 360)
        let lst = (gmst + lonDeg).truncatingRemainder(dividingBy: 360)
        let ha = (lst - raDeg).truncatingRemainder(dividingBy: 360) * .pi / 180
        let dec = decDeg * .pi / 180, lat = latDeg * .pi / 180
        let sinAlt = sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(ha)
        let alt = asin(max(-1, min(1, sinAlt)))
        let cosAz = (sin(dec) - sin(lat) * sinAlt) / (cos(lat) * cos(alt))
        var az = acos(max(-1, min(1, cosAz)))
        if sin(ha) > 0 { az = 2 * .pi - az }
        return (az * 180 / .pi, alt * 180 / .pi)
    }
}

// MARK: - Data

struct VAircraft: Identifiable {
    let hex: String
    let callsign: String?
    let lat: Double
    let lon: Double
    let altM: Double
    var id: String { hex }
}

struct VStar: Decodable { let ra: Double; let dec: Double; let mag: Double }

enum VCelestial {
    static func sun(date: Date, lat: Double, lon: Double) -> (az: Double, el: Double) {
        let geo = GeographicCoordinates(positivelyWestwardLongitude: Degree(-lon), latitude: Degree(lat))
        let h = Sun(julianDay: JulianDay(date)).makeHorizontalCoordinates(with: geo)
        return (h.northBasedAzimuth.value, h.altitude.value)
    }

    static func moon(date: Date, lat: Double, lon: Double) -> (az: Double, el: Double) {
        let geo = GeographicCoordinates(positivelyWestwardLongitude: Degree(-lon), latitude: Degree(lat))
        let jd = JulianDay(date)
        let moon = Moon(julianDay: jd)
        let h = moon.makeHorizontalCoordinates(with: geo)
        let elGeo = h.altitude.value
        let elTopo = elGeo - moon.horizontalParallax.value * cos(elGeo * .pi / 180)
        return (h.northBasedAzimuth.value, elTopo)
    }
}

// MARK: - Model

@MainActor
@Observable
final class VisionSkyModel: NSObject, CLLocationManagerDelegate {
    var skyOpen = false
    var northOffsetDeg: Double = 0
    var statusLine = "Waiting for location…"

    private(set) var location: CLLocation?
    private(set) var traffic: [VAircraft] = []
    private(set) var issSatellite: Satellite?
    private(set) var stars: [VStar] = []
    private(set) var constellations: [[[Double]]] = []

    private let manager = CLLocationManager()
    private var polling = false

    func start() {
        if stars.isEmpty,
           let url = Bundle.main.url(forResource: "stars", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            stars = (try? JSONDecoder().decode([VStar].self, from: data)) ?? []
        }
        if constellations.isEmpty,
           let url = Bundle.main.url(forResource: "constellations", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            constellations = (try? JSONDecoder().decode([[[Double]]].self, from: data)) ?? []
        }
        manager.delegate = self
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: statusLine = "Location denied — using demo sky"
            location = CLLocation(latitude: 37.6213, longitude: -122.3790)
        }
        startPolling()
        Task { await fetchTLE() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            case .denied, .restricted:
                self.statusLine = "Location denied — using demo sky"
                self.location = CLLocation(latitude: 37.6213, longitude: -122.3790)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.location = loc }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func startPolling() {
        guard !polling else { return }
        polling = true
        Task { [weak self] in
            while let self, self.polling {
                await self.pollOnce()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pollOnce() async {
        guard let here = location else { return }
        let lat = here.coordinate.latitude, lon = here.coordinate.longitude
        guard let url = URL(string: "https://api.airplanes.live/v2/point/\(lat)/\(lon)/80") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = obj["ac"] as? [[String: Any]] else { return }
        traffic = records.compactMap { r in
            guard let hex = r["hex"] as? String,
                  let lat = r["lat"] as? Double, let lon = r["lon"] as? Double else { return nil }
            let altFt = (r["alt_geom"] as? Double) ?? (r["alt_baro"] as? Double) ?? 0
            return VAircraft(hex: hex,
                             callsign: (r["flight"] as? String)?.trimmingCharacters(in: .whitespaces),
                             lat: lat, lon: lon, altM: altFt * 0.3048)
        }
        statusLine = "\(traffic.count) aircraft overhead"
    }

    private func fetchTLE() async {
        guard let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=tle"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 3 else { return }
        issSatellite = try? Satellite(lines[0], lines[1], lines[2])
    }
}
