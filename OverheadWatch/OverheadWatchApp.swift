//
//  OverheadWatchApp.swift
//  OverheadWatch
//
//  Overhead on the wrist: tonight's moon, the next ISS pass, Tiangong and
//  Hubble passes, the aurora nowcast, the next rocket launch, and the next
//  meteor shower — all computed or fetched on-watch (own location fix,
//  Celestrak TLEs, SGP4, NOAA SWPC, Launch Library 2). The heavy SwiftAA
//  scans (eclipses, occultations) stay on the phone; the wrist gets the
//  glanceable subset.
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
        case ..<0.03, 0.97...: name = String(localized: "New moon")
        case ..<0.22: name = String(localized: "Waxing crescent")
        case ..<0.28: name = String(localized: "First quarter")
        case ..<0.47: name = String(localized: "Waxing gibbous")
        case ..<0.53: name = String(localized: "Full moon")
        case ..<0.72: name = String(localized: "Waning gibbous")
        case ..<0.78: name = String(localized: "Last quarter")
        default: name = String(localized: "Waning crescent")
        }
        return (fraction, phase < 0.5, name)
    }

    /// Whole days until the next full moon (0 = full tonight). The "tonight"
    /// window matches `state(at:)`'s "Full moon" naming band (phase < 0.53),
    /// so the card can never say "Full moon" and "in 30d" at the same time.
    static func daysToFull(from date: Date) -> Int {
        let age = date.timeIntervalSince(epoch).truncatingRemainder(dividingBy: synodic)
        var toFull = synodic * 0.5 - age
        if toFull < -0.03 * synodic { toFull += synodic }   // past the full band → next cycle
        return max(0, Int((toFull / 86_400).rounded()))
    }
}

// MARK: - Meteor showers (self-contained mirror of the phone's shower table)

enum WatchShowers {
    struct Shower { let name: String; let month: Int; let day: Int; let zhr: Int }

    static let catalog: [Shower] = [
        Shower(name: String(localized: "Quadrantids"), month: 1, day: 3, zhr: 110),
        Shower(name: String(localized: "Lyrids"), month: 4, day: 22, zhr: 18),
        Shower(name: String(localized: "Eta Aquariids"), month: 5, day: 5, zhr: 50),
        Shower(name: String(localized: "Delta Aquariids"), month: 7, day: 30, zhr: 25),
        Shower(name: String(localized: "Perseids"), month: 8, day: 12, zhr: 100),
        Shower(name: String(localized: "Orionids"), month: 10, day: 21, zhr: 20),
        Shower(name: String(localized: "Leonids"), month: 11, day: 17, zhr: 15),
        Shower(name: String(localized: "Geminids"), month: 12, day: 13, zhr: 150),
        Shower(name: String(localized: "Ursids"), month: 12, day: 22, zhr: 10),
    ]

    /// The next peak night from `date` (peaks are dated 22:00 local, matching
    /// the phone's calendar).
    static func next(from date: Date) -> (name: String, peak: Date, zhr: Int)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let year = calendar.component(.year, from: date)
        var best: (String, Date, Int)?
        for shower in catalog {
            for y in [year, year + 1] {
                guard let peak = calendar.date(from: DateComponents(year: y, month: shower.month,
                                                                    day: shower.day, hour: 22)),
                      peak > date else { continue }
                if best == nil || peak < best!.1 { best = (shower.name, peak, shower.zhr) }
                break
            }
        }
        return best
    }
}

// MARK: - Aurora nowcast (mirror of the phone's LiveSky math, watch-sized)

enum WatchAurora {
    struct Nowcast: Equatable {
        var currentKp: Double
        /// First forecast window strong enough for this latitude, if any.
        var watchAt: Date?
        var watchKp: Double = 0
    }

    /// Geomagnetic (centered-dipole) latitude — the oval rings the magnetic
    /// pole (IGRF, epoch 2025: 80.7° N, 72.7° W), not the geographic one.
    static func geomagneticLatitude(lat: Double, lon: Double) -> Double {
        let poleLat = 80.7 * Double.pi / 180, poleLon = -72.7 * Double.pi / 180
        let la = lat * .pi / 180, lo = lon * .pi / 180
        let s = sin(poleLat) * sin(la) + cos(poleLat) * cos(la) * cos(lo - poleLon)
        return asin(max(-1, min(1, s))) * 180 / .pi
    }

    /// Kp needed before auroras reach this magnetic latitude's horizon —
    /// oval edge ≈ 66.5° magnetic at Kp 0, marching ~2.1° per Kp step.
    static func requiredKp(geomagneticLat: Double) -> Double {
        (66.5 - abs(geomagneticLat)) / 2.1
    }

    private struct Row: Decodable {
        let time_tag: String
        let kp: Double
        let observed: String
    }

    /// One fetch serves both numbers: the last observed row is "Kp now",
    /// the first qualifying predicted row is the watch window.
    static func fetch(lat: Double, lon: Double) async -> Nowcast? {
        guard let url = URL(string: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        var nowcast = Nowcast(currentKp: rows.last(where: { $0.observed == "observed" })?.kp ?? 0)
        let needed = requiredKp(geomagneticLat: geomagneticLatitude(lat: lat, lon: lon))
        let now = Date()
        for row in rows where row.observed != "observed" {
            guard let date = formatter.date(from: row.time_tag),
                  date > now.addingTimeInterval(-3 * 3600) else { continue }
            if row.kp >= needed {
                nowcast.watchAt = max(date, now)
                nowcast.watchKp = row.kp
                break
            }
        }
        return nowcast
    }
}

// MARK: - Next rocket launch (Launch Library 2)

enum WatchLaunches {
    struct Next: Equatable { let name: String; let at: Date }

    private struct Response: Decodable { let results: [Launch] }
    private struct Launch: Decodable {
        struct Status: Decodable { let abbrev: String? }
        let name: String
        let net: String?
        let status: Status?
    }

    /// The soonest confirmed launch. LL2's free tier allows 15 requests an
    /// hour — the model throttles refreshes to keep this polite.
    static func fetch() async -> Next? {
        guard let url = URL(string: "https://ll.thespacedevs.com/2.2.0/launch/upcoming/?limit=5&mode=normal") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let iso = ISO8601DateFormatter()
        let now = Date()
        for launch in decoded.results {
            guard let net = launch.net, let date = iso.date(from: net), date > now,
                  let status = launch.status?.abbrev, ["Go", "TBC"].contains(status) else { continue }
            return Next(name: launch.name, at: date)
        }
        return nil
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

    /// Passes of the other marquee satellites (Tiangong, Hubble) in the next
    /// 24 h — empty rows are simply not shown.
    struct ExtraPass: Equatable { let name: String; let rise: Date; let maxElevation: Int }
    var extraPasses: [ExtraPass] = []

    /// Aurora nowcast; nil until fetched (card hidden while unknown).
    var aurora: WatchAurora.Nowcast?
    /// Which horizon to face — the oval sits poleward.
    var southernHemisphere = false

    /// The next confirmed rocket launch; nil until fetched or none upcoming.
    var nextLaunch: WatchLaunches.Next?

    /// Network feeds (SWPC, LL2) refresh at most every 15 minutes — wrist
    /// raises re-run the pipeline, and LL2's free tier is 15 requests/hour.
    private var lastFeedRefresh: Date?

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
            self.southernHemisphere = location.coordinate.latitude < 0
            self.state = .fetching
            await self.computeAll()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.location == nil { self.state = .needLocation }
        }
    }

    /// The whole wrist pipeline: the ISS headline first (it drives `state`),
    /// then the other satellites, with the network feeds racing alongside.
    private func computeAll() async {
        guard let location else { return }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        let feedsStale = lastFeedRefresh.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true
        if feedsStale {
            lastFeedRefresh = Date()
            async let auroraFetch = WatchAurora.fetch(lat: lat, lon: lon)
            async let launchFetch = WatchLaunches.fetch()
            await computePass()
            await computeExtras()
            if let nowcast = await auroraFetch { aurora = nowcast }
            nextLaunch = await launchFetch
        } else {
            await computePass()
            await computeExtras()
        }
    }

    private func computePass() async {
        guard let location else { return }
        guard let satellite = await satellite(catnr: 25_544, cacheKey: "issTLE") else {
            state = .offline
            return
        }
        if let pass = Self.nextPass(of: satellite,
                                    lat: location.coordinate.latitude,
                                    lon: location.coordinate.longitude) {
            state = .pass(rise: pass.rise, maxElevation: pass.maxEl)
        } else {
            state = .noPass
        }
    }

    /// The other spacecraft everyone knows by name. Hubble's 28.5°-inclined
    /// orbit never rises for high-latitude observers — its row simply never
    /// appears there, which is the honest answer.
    private static let extraSatellites: [(name: String, catnr: Int, cacheKey: String)] = [
        (String(localized: "Tiangong"), 48_274, "cssTLE"),
        (String(localized: "Hubble"), 20_580, "hstTLE"),
    ]

    private func computeExtras() async {
        guard let location else { return }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        var found: [ExtraPass] = []
        for entry in Self.extraSatellites {
            guard let satellite = await satellite(catnr: entry.catnr, cacheKey: entry.cacheKey),
                  let pass = Self.nextPass(of: satellite, lat: lat, lon: lon) else { continue }
            found.append(ExtraPass(name: entry.name, rise: pass.rise, maxElevation: pass.maxEl))
        }
        extraPasses = found.sorted { $0.rise < $1.rise }
    }

    /// Scan 24 h ahead in 30 s steps for the next rise above 10°.
    private static func nextPass(of satellite: Satellite,
                                 lat: Double, lon: Double) -> (rise: Date, maxEl: Int)? {
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
        guard let rise else { return nil }
        return (rise, Int(maxEl.rounded()))
    }

    private func satellite(catnr: Int, cacheKey: String) async -> Satellite? {
        guard let text = await fetchTLE(catnr: catnr, cacheKey: cacheKey) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 3 else { return nil }
        return try? Satellite(lines[0], lines[1], lines[2])
    }

    /// Celestrak blocks IPs that re-query the same catalog number more than
    /// about once every two hours, so each TLE is cached for a day (the
    /// elements barely move in that window) and stale data beats a block page.
    private func fetchTLE(catnr: Int, cacheKey: String) async -> String? {
        let defaults = UserDefaults.standard
        let cached = defaults.string(forKey: cacheKey)
        let fetchedAt = defaults.object(forKey: "\(cacheKey)Date") as? Date
        if let cached, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 24 * 3600 {
            return cached
        }
        guard let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=\(catnr)&FORMAT=tle"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let text = String(data: data, encoding: .utf8) else {
            return cached   // stale elements still predict tonight's pass fine
        }
        defaults.set(text, forKey: cacheKey)
        defaults.set(Date(), forKey: "\(cacheKey)Date")
        return text
    }
}

// MARK: - Screenshot hooks (DEBUG only, compiled out of Release)

#if DEBUG
/// `-wshot <name>` launch arg forces a deterministic moon + ISS state so the
/// single watch screen can be captured in its distinct, compelling states for
/// App Store screenshots. Never ships (Release strips this).
enum WatchShot: String {
    case live, tonight, soon
    static var current: WatchShot? {
        guard let v = UserDefaults.standard.string(forKey: "wshot") else { return nil }
        return WatchShot(rawValue: v)
    }
    var forcedState: ISSPassModel.State {
        switch self {
        case .live: return .pass(rise: Date().addingTimeInterval(-30), maxElevation: 71)
        case .tonight: return .pass(rise: Date().addingTimeInterval(3 * 3600 + 24 * 60 + 52), maxElevation: 68)
        case .soon: return .pass(rise: Date().addingTimeInterval(52 * 60 + 10), maxElevation: 43)
        }
    }
    /// (fraction lit, waxing, name)
    var moon: (fraction: Double, waxing: Bool, name: String) {
        switch self {
        case .live: return (1.0, false, "Full moon")
        case .tonight: return (0.84, false, "Waning gibbous")
        case .soon: return (0.18, true, "Waxing crescent")
        }
    }
    var fullMoonText: String {
        switch self {
        case .live: return "Full tonight"
        case .tonight: return "Full moon in 3d"
        case .soon: return "Full moon in 10d"
        }
    }
}
#endif

// MARK: - View

struct WatchHomeView: View {
    @State private var model = ISSPassModel()
    @Environment(\.scenePhase) private var scenePhase

    private let moonlight = Color(red: 0.96, green: 0.96, blue: 0.91)
    private let accent = Color(red: 0.60, green: 0.74, blue: 1.00)
    private let cyan = Color(red: 0.5, green: 1.0, blue: 1.0)
    private let auroraGreen = Color(red: 0.40, green: 0.85, blue: 0.62)
    private let flame = Color(red: 0.98, green: 0.62, blue: 0.30)

    var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                header
                moonCard
                issCard
                satellitesCard
                auroraCard
                launchCard
                showerCard
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 6)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.02, green: 0.02, blue: 0.07),
                                    Color(red: 0.005, green: 0.005, blue: 0.02)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .task {
            #if DEBUG
            if let shot = WatchShot.current { model.state = shot.forcedState; return }
            #endif
            model.start()
        }
        // Recompute on wrist raise so an elapsed pass rolls to the next one.
        .onChange(of: scenePhase) { _, phase in
            #if DEBUG
            if WatchShot.current != nil { return }
            #endif
            if phase == .active { model.start() }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text("OVERHEAD")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(moonlight)
            Spacer()
            Image(systemName: "location.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: Moon

    private var moonCard: some View {
        #if DEBUG
        let moon = WatchShot.current?.moon ?? WatchMoon.state(at: Date())
        let fullText = WatchShot.current?.fullMoonText ?? fullMoonText()
        #else
        let moon = WatchMoon.state(at: Date())
        let fullText = fullMoonText()
        #endif
        return card {
            HStack(spacing: 11) {
                moonDisc(fraction: moon.fraction, waxing: moon.waxing)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 1) {
                    Text(moon.name)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(moonlight)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text("\(Int((moon.fraction * 100).rounded()))% lit")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(fullText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(accent)
                        .padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func fullMoonText() -> String {
        let d = WatchMoon.daysToFull(from: Date())
        return d == 0 ? String(localized: "Full tonight") : String(localized: "Full moon in \(d)d")
    }

    // MARK: ISS

    @ViewBuilder private var issCard: some View {
        card {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(cyan)
                    Text("NEXT ISS PASS")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                issBody
            }
        }
    }

    @ViewBuilder private var issBody: some View {
        switch model.state {
        case .locating:
            issPlaceholder(String(localized: "Finding your sky…"))
        case .fetching:
            issPlaceholder(String(localized: "Reading the orbit…"))
        case .pass(let rise, let maxEl):
            // The pass state can go stale on the wrist; a past `rise` would make
            // the countsDown range trap, so branch on it. Countdown leads so it
            // stays in the viewport; the sky-arc sits beneath it.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let live = rise <= context.date
                VStack(alignment: .leading, spacing: 5) {
                    if live {
                        Text("Above the horizon now")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(cyan)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text("Look up · peaks \(maxEl)° high")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(timerInterval: context.date...rise, countsDown: true)
                            .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(cyan)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text("\(rise.formatted(date: .omitted, time: .shortened)) · peaks \(maxEl)° high")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    passArc(maxEl: maxEl, live: live)
                        .frame(height: 38)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 1)
                }
            }
        case .noPass:
            issPlaceholder(String(localized: "No pass in the next 24 h"))
        case .needLocation:
            issPlaceholder(String(localized: "Allow location to find passes"))
        case .offline:
            issPlaceholder(String(localized: "No connection — try later"))
        }
    }

    private func issPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    /// A little sky dome: the horizon line and the pass trajectory arcing to its
    /// peak elevation, with the station marked. Height ∝ max elevation.
    private func passArc(maxEl: Int, live: Bool) -> some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let horizonY = h - 3
            let leftX = 5.0, rightX = w - 5
            let peakX = (leftX + rightX) / 2
            let peakY = horizonY - (h - 8) * min(1, Double(maxEl) / 90.0)

            // horizon
            var horizon = Path()
            horizon.move(to: CGPoint(x: leftX, y: horizonY))
            horizon.addLine(to: CGPoint(x: rightX, y: horizonY))
            ctx.stroke(horizon, with: .color(.white.opacity(0.16)), lineWidth: 1)

            // trajectory (quadratic whose apex sits at peakY)
            var arc = Path()
            arc.move(to: CGPoint(x: leftX, y: horizonY))
            arc.addQuadCurve(to: CGPoint(x: rightX, y: horizonY),
                             control: CGPoint(x: peakX, y: 2 * peakY - horizonY))
            ctx.stroke(arc, with: .color(cyan.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // station marker at apex
            let dot = CGRect(x: peakX - 4.5, y: peakY - 4.5, width: 9, height: 9)
            ctx.fill(Path(ellipseIn: dot.insetBy(dx: -3, dy: -3)), with: .color(cyan.opacity(0.22)))
            ctx.fill(Path(ellipseIn: dot), with: .color(live ? cyan : moonlight))

            // peak-elevation label
            ctx.draw(Text("\(maxEl)°")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85)),
                     at: CGPoint(x: peakX, y: peakY - 12))
        }
    }

    // MARK: More satellites

    /// Tiangong and Hubble, soonest first — rows only exist when a pass is
    /// actually coming in the next 24 h.
    @ViewBuilder private var satellitesCard: some View {
        if !model.extraPasses.isEmpty {
            card {
                VStack(alignment: .leading, spacing: 7) {
                    cardHeader("ALSO OVERHEAD", icon: "smallcircle.filled.circle", tint: cyan)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.extraPasses, id: \.name) { pass in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(pass.name)
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                        .foregroundStyle(moonlight)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if pass.rise <= context.date {
                                        Text("Up now · \(pass.maxElevation)°")
                                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                                            .foregroundStyle(cyan)
                                    } else {
                                        Text("\(pass.rise.formatted(date: .omitted, time: .shortened)) · \(pass.maxElevation)°")
                                            .font(.system(size: 12, design: .rounded).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Aurora

    @ViewBuilder private var auroraCard: some View {
        if let aurora = model.aurora {
            card {
                VStack(alignment: .leading, spacing: 5) {
                    cardHeader("AURORA", icon: "sparkles", tint: auroraGreen)
                    if let at = aurora.watchAt {
                        Text(at.timeIntervalSinceNow < 3600
                             ? String(localized: "Possible now")
                             : String(localized: "Possible \(at.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(auroraGreen)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(model.southernHemisphere
                             ? String(localized: "Kp \(aurora.watchKp, specifier: "%.1f") forecast — face south after dark")
                             : String(localized: "Kp \(aurora.watchKp, specifier: "%.1f") forecast — face north after dark"))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Quiet · Kp \(aurora.currentKp, specifier: "%.1f") now")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Next launch

    @ViewBuilder private var launchCard: some View {
        if let launch = model.nextLaunch {
            card {
                VStack(alignment: .leading, spacing: 5) {
                    cardHeader("NEXT LAUNCH", icon: "flame.fill", tint: flame)
                    Text(launch.name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(moonlight)
                        .lineLimit(2).minimumScaleFactor(0.8)
                    HStack(spacing: 5) {
                        Text(launch.at, style: .relative)
                            .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(flame)
                        Text("· \(launch.at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
            }
        }
    }

    // MARK: Meteor shower

    @ViewBuilder private var showerCard: some View {
        if let shower = WatchShowers.next(from: Date()) {
            card {
                VStack(alignment: .leading, spacing: 5) {
                    cardHeader("METEOR SHOWER", icon: "wind", tint: accent)
                    Text(shower.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(moonlight)
                    Text(daysUntil(shower.peak) == 0
                         ? String(localized: "Peaks tonight · up to \(shower.zhr)/hr")
                         : String(localized: "Peaks in \(daysUntil(shower.peak))d · up to \(shower.zhr)/hr"))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func daysUntil(_ date: Date) -> Int {
        max(0, Int(date.timeIntervalSinceNow / 86_400))
    }

    private func cardHeader(_ title: LocalizedStringKey, icon: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Card chrome

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.09), lineWidth: 1)
            )
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
