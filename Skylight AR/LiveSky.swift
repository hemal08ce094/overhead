//
//  LiveSky.swift
//  Overhead
//
//  Real-time sky events from free, keyless public feeds: the aurora
//  nowcast (NOAA SWPC), upcoming rocket launches (Launch Library 2),
//  recent fireballs (NASA CNEOS), and a reentry watch derived on-device
//  from the same CelesTrak elements the satellite layer already tracks.
//  Every fetch degrades to "no events" silently — the computed calendar
//  never waits on the network.
//

import Foundation

enum LiveSkyEvents {

    struct Feed {
        /// Upcoming, merges into the sky calendar.
        var events: [SkyEvent] = []
        /// Already happened (fireballs are detected, not predicted) —
        /// shown in their own "recently" section.
        var recent: [SkyEvent] = []
    }

    static func fetch(lat: Double, lon: Double) async -> Feed {
        async let aurora = auroraWatch(lat: lat, lon: lon)
        async let launches = rocketLaunches(lat: lat, lon: lon)
        async let reentries = reentryWatch()
        async let fireballs = recentFireballs(lat: lat, lon: lon)
        var feed = Feed()
        feed.events = (await aurora) + (await launches) + (await reentries)
        feed.recent = await fireballs
        return feed
    }

    // MARK: - Shared plumbing

    private static func json(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        return data
    }

    /// Great-circle distance, km.
    static func distanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 6_371 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    private static func utcDate(_ string: String, format: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f.date(from: string)
    }

    // MARK: - Aurora nowcast (NOAA SWPC)

    /// Geomagnetic (centered-dipole) latitude — the auroral oval rings the
    /// magnetic pole (IGRF, epoch 2025: 80.7° N, 72.7° W), not the
    /// geographic one, which is why Minneapolis outscores Reykjavik-envy
    /// London at the same geographic latitude.
    static func geomagneticLatitude(lat: Double, lon: Double) -> Double {
        let poleLat = 80.7 * Double.pi / 180, poleLon = -72.7 * Double.pi / 180
        let la = lat * .pi / 180, lo = lon * .pi / 180
        let s = sin(poleLat) * sin(la) + cos(poleLat) * cos(la) * cos(lo - poleLon)
        return asin(max(-1, min(1, s))) * 180 / .pi
    }

    /// The Kp index needed before auroras become visible on the horizon
    /// from this magnetic latitude. Standard NOAA mapping: the oval's
    /// equatorward edge sits near 66.5° magnetic at Kp 0 and marches
    /// ~2.1° equatorward per Kp step.
    static func requiredKp(geomagneticLat: Double) -> Double {
        (66.5 - abs(geomagneticLat)) / 2.1
    }

    private struct KpForecastRow: Decodable {
        let time_tag: String
        let kp: Double
        let observed: String
    }

    /// One event when the 3-day SWPC forecast (or the live estimated Kp)
    /// reaches this location's visibility threshold — dated at the first
    /// qualifying 3-hour window.
    static func auroraWatch(lat: Double, lon: Double) async -> [SkyEvent] {
        let magLat = geomagneticLatitude(lat: lat, lon: lon)
        let needed = requiredKp(geomagneticLat: magLat)
        guard needed <= 9 else { return [] }   // effectively never at this latitude

        guard let data = await json("https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json"),
              let rows = try? JSONDecoder().decode([KpForecastRow].self, from: data) else { return [] }

        let now = Date()
        var hit: (date: Date, kp: Double)?
        for row in rows where row.observed != "observed" {
            guard let date = utcDate(row.time_tag, format: "yyyy-MM-dd'T'HH:mm:ss"),
                  date > now.addingTimeInterval(-3 * 3600) else { continue }
            if row.kp >= needed { hit = (max(date, now), row.kp); break }
        }
        guard let hit else { return [] }

        let southern = lat < 0
        let horizon = southern ? String(localized: "southern horizon") : String(localized: "northern horizon")
        return [SkyEvent(
            kind: .aurora,
            title: String(localized: "Aurora watch"),
            subtitle: String(localized: "Forecast Kp \(hit.kp, specifier: "%.1f") — possible from your latitude"),
            date: hit.date,
            detail: String(localized: "NOAA's space-weather forecast puts geomagnetic activity at Kp \(hit.kp, specifier: "%.1f") — strong enough for the auroral oval to reach your magnetic latitude. Find a dark spot with a clear \(horizon), let your eyes adapt, and be patient: displays come in surges. Forecasts shift with the solar wind, so treat the hour as approximate."))]
    }

    // MARK: - Rocket launches (Launch Library 2, The Space Devs)

    /// A string-or-number field — LL2 serves pad coordinates as either.
    private struct FlexDouble: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { value = d }
            else { value = Double((try? c.decode(String.self)) ?? "") }
        }
    }

    private struct LL2Response: Decodable { let results: [LL2Launch] }
    private struct LL2Launch: Decodable {
        struct Status: Decodable { let abbrev: String? }
        struct Provider: Decodable { let name: String? }
        struct Pad: Decodable {
            struct Location: Decodable { let name: String? }
            let latitude: FlexDouble?
            let longitude: FlexDouble?
            let location: Location?
        }
        let name: String
        let net: String?
        let status: Status?
        let pad: Pad?
        let launch_service_provider: Provider?
    }

    /// Confirmed launches in the next three weeks, nearest-in-time first.
    /// LL2's free tier allows 15 requests/hour — one per session is polite.
    static func rocketLaunches(lat: Double, lon: Double) async -> [SkyEvent] {
        guard let data = await json("https://ll.thespacedevs.com/2.2.0/launch/upcoming/?limit=10&mode=normal"),
              let response = try? JSONDecoder().decode(LL2Response.self, from: data) else { return [] }

        let iso = ISO8601DateFormatter()
        let now = Date()
        var events: [SkyEvent] = []
        for launch in response.results {
            guard let net = launch.net, let date = iso.date(from: net),
                  date > now, date < now.addingTimeInterval(21 * 86_400) else { continue }
            // Only launches with a real slot — "Go" (confirmed) or "TBC".
            guard let status = launch.status?.abbrev, ["Go", "TBC"].contains(status) else { continue }

            let padName = launch.pad?.location?.name ?? String(localized: "the pad")
            let provider = launch.launch_service_provider?.name
            var subtitle = padName
            var visibility = ""
            if let padLat = launch.pad?.latitude?.value, let padLon = launch.pad?.longitude?.value {
                let km = distanceKm(lat1: lat, lon1: lon, lat2: padLat, lon2: padLon)
                subtitle = String(localized: "\(padName) · \(Int(km.rounded())) km away")
                if km < 300 {
                    visibility = String(localized: " From \(Int(km.rounded())) km away the climb-out is often visible with clear skies — look toward the pad in the minutes after liftoff.")
                }
            }
            var detail = String(localized: "Liftoff is targeted for the time shown (subject to weather and range holds).")
            if let provider { detail = String(localized: "\(provider) launch. ") + detail }
            events.append(SkyEvent(
                kind: .rocketLaunch,
                title: launch.name,
                subtitle: subtitle,
                date: date,
                detail: detail + visibility))
            if events.count == 6 { break }
        }
        return events
    }

    // MARK: - Reentry watch (derived from CelesTrak elements)

    /// No open feed publishes reentry predictions without an account, so
    /// this is computed honestly from the visual-group elements we already
    /// carry: an object whose mean altitude has sagged below ~250 km with
    /// strongly growing drag is in its final weeks, and the decay rate in
    /// the elements gives a rough date.
    static func reentryWatch() async -> [SkyEvent] {
        let entries = await SatelliteCatalog.shared.entries()
        var events: [SkyEvent] = []
        for entry in entries {
            let alt = entry.meanAltitudeKm
            let nDot = entry.meanMotionDot
            guard alt < 250, nDot > 1e-4 else { continue }
            // Days until mean motion reaches ~16.4 rev/day (~150 km — the
            // steep end of the drag curve), linearized from today's decay rate.
            let days = (16.4 - entry.meanMotion) / nDot
            guard days > 0, days < 45 else { continue }
            events.append(SkyEvent(
                kind: .reentry,
                title: String(localized: "\(entry.name.capitalized) is coming down"),
                subtitle: String(localized: "Orbit down to ~\(Int(alt.rounded())) km and decaying fast"),
                date: Date().addingTimeInterval(days * 86_400),
                detail: String(localized: "This tracked object is in its final orbits — atmospheric drag is now winning, and it should break up as an artificial fireball around the date shown. A prediction this far out is uncertain by days; the window narrows as the orbit sinks.")))
            if events.count == 3 { break }
        }
        return events
    }

    // MARK: - Recent fireballs (NASA CNEOS)

    private struct CNEOSResponse: Decodable {
        let fields: [String]
        let data: [[String?]]
    }

    /// Bright bolides recorded by U.S. government sensors in the last month
    /// — detections, not predictions, so they land in the "recently" list.
    static func recentFireballs(lat: Double, lon: Double) async -> [SkyEvent] {
        guard let data = await json("https://ssd-api.jpl.nasa.gov/fireball.api?limit=8"),
              let response = try? JSONDecoder().decode(CNEOSResponse.self, from: data) else { return [] }

        func index(_ name: String) -> Int? { response.fields.firstIndex(of: name) }
        guard let iDate = index("date"), let iEnergy = index("impact-e"),
              let iLat = index("lat"), let iLatDir = index("lat-dir"),
              let iLon = index("lon"), let iLonDir = index("lon-dir") else { return [] }

        let now = Date()
        var events: [SkyEvent] = []
        for row in response.data {
            guard row.indices.contains(iDate), let dateString = row[iDate],
                  let date = utcDate(dateString, format: "yyyy-MM-dd HH:mm:ss"),
                  now.timeIntervalSince(date) < 31 * 86_400 else { continue }

            let kt = row.indices.contains(iEnergy) ? row[iEnergy].flatMap(Double.init) : nil
            var subtitle = String(localized: "Detected by space sensors")
            if let fbLatRaw = row.indices.contains(iLat) ? row[iLat].flatMap(Double.init) : nil,
               let fbLonRaw = row.indices.contains(iLon) ? row[iLon].flatMap(Double.init) : nil,
               row.indices.contains(iLatDir), row.indices.contains(iLonDir) {
                let fbLat = (row[iLatDir] == "S") ? -fbLatRaw : fbLatRaw
                let fbLon = (row[iLonDir] == "W") ? -fbLonRaw : fbLonRaw
                let km = distanceKm(lat1: lat, lon1: lon, lat2: fbLat, lon2: fbLon)
                subtitle = String(localized: "\(Int(km.rounded())) km from you")
            }
            if let kt {
                subtitle += String(localized: " · ~\(kt, specifier: "%.2g") kt airburst")
            }
            events.append(SkyEvent(
                kind: .fireball,
                title: String(localized: "Bright fireball"),
                subtitle: subtitle,
                date: date,
                detail: String(localized: "A meteoroid hit the atmosphere hard enough for U.S. government space sensors to record the flash — the same network that watches for much larger impacts. Fireballs this bright outshine Venus; a handful are recorded worldwide each month.")))
            if events.count == 3 { break }
        }
        return events
    }
}
