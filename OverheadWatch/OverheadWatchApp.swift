//
//  OverheadWatchApp.swift
//  OverheadWatch
//
//  Overhead on the wrist: tonight's moon and the next ISS pass, computed
//  entirely on-watch (own location fix, Celestrak TLE, SGP4 propagation).
//

import SwiftUI
import CoreLocation
import SatelliteKit

@main
struct OverheadWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchHomeView()
        }
    }
}

// MARK: - Math (self-contained mirror of the phone app's SkyMath)

enum WatchSkyMath {
    static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400.0 + 2_440_587.5
    }

    /// Elevation of a target above the observer's horizon, degrees.
    static func elevation(observerLat: Double, observerLon: Double,
                          targetLat: Double, targetLon: Double, targetAltM: Double) -> Double {
        func ecef(_ latDeg: Double, _ lonDeg: Double, _ altM: Double) -> (x: Double, y: Double, z: Double) {
            let a = 6_378_137.0, e2 = 6.694_379_990_14e-3
            let lat = latDeg * .pi / 180, lon = lonDeg * .pi / 180
            let n = a / sqrt(1 - e2 * sin(lat) * sin(lat))
            return ((n + altM) * cos(lat) * cos(lon),
                    (n + altM) * cos(lat) * sin(lon),
                    (n * (1 - e2) + altM) * sin(lat))
        }
        let obs = ecef(observerLat, observerLon, 0)
        let tgt = ecef(targetLat, targetLon, targetAltM)
        let dx = tgt.x - obs.x, dy = tgt.y - obs.y, dz = tgt.z - obs.z
        let lat = observerLat * .pi / 180, lon = observerLon * .pi / 180
        // ENU components; elevation = angle of the up-component vs horizontal.
        let east = -sin(lon) * dx + cos(lon) * dy
        let north = -sin(lat) * cos(lon) * dx - sin(lat) * sin(lon) * dy + cos(lat) * dz
        let up = cos(lat) * cos(lon) * dx + cos(lat) * sin(lon) * dy + sin(lat) * dz
        let horizontal = sqrt(east * east + north * north)
        return atan2(up, horizontal) * 180 / .pi
    }
}

// MARK: - Moon phase (same mean-synodic math as the iOS widget)

enum WatchMoon {
    static let synodic = 29.530588853 * 86_400
    static let epoch = Date(timeIntervalSince1970: 947_182_440)   // 2000-01-06 18:14 UTC new moon

    static func state(at date: Date) -> (fraction: Double, waxing: Bool, name: String) {
        let age = date.timeIntervalSince(epoch).truncatingRemainder(dividingBy: synodic)
        let phase = age / synodic
        let fraction = (1 - cos(2 * .pi * phase)) / 2
        let name: String
        switch phase {
        case ..<0.03, 0.97...: name = "New moon"
        case ..<0.22: name = "Waxing crescent"
        case ..<0.28: name = "First quarter"
        case ..<0.47: name = "Waxing gibbous"
        case ..<0.53: name = "Full moon"
        case ..<0.72: name = "Waning gibbous"
        case ..<0.78: name = "Last quarter"
        default: name = "Waning crescent"
        }
        return (fraction, phase < 0.5, name)
    }
}

// MARK: - ISS pass model

@MainActor
@Observable
final class ISSPassModel: NSObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case locating
        case fetching
        case pass(rise: Date, maxElevation: Int)
        case noPass
        case needLocation
        case offline
    }
    var state: State = .locating

    private let manager = CLLocationManager()
    private var location: CLLocation?

    func start() {
        manager.delegate = self
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            state = .needLocation
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            case .denied, .restricted: self.state = .needLocation
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.location = location
            self.state = .fetching
            await self.computePass()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.location == nil { self.state = .needLocation }
        }
    }

    private func computePass() async {
        guard let location else { return }
        guard let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=tle"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let text = String(data: data, encoding: .utf8) else {
            state = .offline
            return
        }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 3, let satellite = try? Satellite(lines[0], lines[1], lines[2]) else {
            state = .offline
            return
        }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        // Scan 24 h ahead in 30 s steps for the next rise above 10°.
        let start = Date()
        var t = 30.0
        var rise: Date?
        var maxEl = 0.0
        while t < 24 * 3600 {
            let date = start.addingTimeInterval(t)
            guard let lla = try? satellite.geoPosition(julianDays: WatchSkyMath.julianDay(date)) else {
                t += 30; continue
            }
            let el = WatchSkyMath.elevation(observerLat: lat, observerLon: lon,
                                            targetLat: lla.lat, targetLon: lla.lon,
                                            targetAltM: lla.alt * 1000)
            if el > 10 {
                if rise == nil { rise = date }
                maxEl = max(maxEl, el)
            } else if rise != nil {
                break       // pass ended
            }
            t += 30
        }
        if let rise {
            state = .pass(rise: rise, maxElevation: Int(maxEl.rounded()))
        } else {
            state = .noPass
        }
    }
}

// MARK: - View

struct WatchHomeView: View {
    @State private var model = ISSPassModel()

    private let moonlight = Color(red: 0.96, green: 0.96, blue: 0.91)
    private let accent = Color(red: 0.60, green: 0.74, blue: 1.00)
    private let cyan = Color(red: 0.5, green: 1.0, blue: 1.0)

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                moonSection
                Divider().overlay(.white.opacity(0.15))
                issSection
            }
            .padding(.horizontal, 4)
        }
        .background(Color(red: 0.01, green: 0.01, blue: 0.04))
        .task { model.start() }
    }

    private var moonSection: some View {
        let moon = WatchMoon.state(at: Date())
        return HStack(spacing: 10) {
            moonDisc(fraction: moon.fraction, waxing: moon.waxing)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(moon.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(moonlight)
                Text("\(Int((moon.fraction * 100).rounded()))% lit")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder private var issSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(cyan)
                    .frame(width: 7, height: 7)
                    .rotationEffect(.degrees(45))
                Text("Next ISS pass")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            switch model.state {
            case .locating:
                Text("Finding your sky…")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
            case .fetching:
                Text("Reading the orbit…")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
            case .pass(let rise, let maxEl):
                Text(timerInterval: Date()...rise, countsDown: true)
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(cyan)
                Text("\(rise.formatted(date: .omitted, time: .shortened)) · up to \(maxEl)° high")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            case .noPass:
                Text("No pass in the next 24 h")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
            case .needLocation:
                Text("Allow location to find your passes")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
            case .offline:
                Text("No connection — try again later")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func moonDisc(fraction: Double, waxing: Bool) -> some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                                width: 2 * r, height: 2 * r)),
                         with: .color(Color(red: 0.10, green: 0.11, blue: 0.16)))
            guard fraction > 0.01 else { return }
            let sign: CGFloat = waxing ? 1 : -1
            let rx = r * CGFloat(1 - 2 * fraction)
            var path = Path()
            let n = 48
            for i in 0...n {
                let phi = CGFloat.pi * CGFloat(i) / CGFloat(n)
                let p = CGPoint(x: center.x + sign * r * sin(phi), y: center.y - r * cos(phi))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            for i in 0...n {
                let phi = CGFloat.pi * CGFloat(n - i) / CGFloat(n)
                path.addLine(to: CGPoint(x: center.x + sign * rx * sin(phi),
                                         y: center.y - r * cos(phi)))
            }
            path.closeSubpath()
            context.fill(path, with: .color(moonlight))
        }
        .shadow(color: moonlight.opacity(0.4), radius: 6)
    }
}
