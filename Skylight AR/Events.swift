//
//  Events.swift
//  Overhead
//
//  The sky calendar: solar and lunar eclipses discovered by scanning the
//  actual geometry from the observer's own position (real local
//  circumstances, no bundled tables), planet conjunctions, solstices and
//  equinoxes, the major meteor showers, and the coming named full moons.
//

import Foundation

struct SkyEvent: Identifiable, Equatable {
    enum Kind {
        case eclipse, lunarEclipse, meteorShower, fullMoon, conjunction, season
        // Live + computed additions: the moon covering a planet or star, an
        // aurora window, a launch countdown, an object falling back, and a
        // recorded bolide.
        case occultation, aurora, rocketLaunch, reentry, fireball
    }
    let kind: Kind
    let title: String
    let subtitle: String
    let date: Date
    let detail: String

    var id: String { "\(title)-\(date.timeIntervalSince1970)" }
}

enum EventsCalendar {

    /// A major annual shower (IMO): peak, rate, radiant, and activity window —
    /// enough to put honest meteors in the AR sky, not just rows in a list.
    struct MeteorShower {
        let name: String
        let peakMonth: Int, peakDay: Int
        let zhr: Int
        /// Radiant, J2000 degrees — shower meteors fan out from this point.
        let raDeg: Double, decDeg: Double
        /// Activity window around the peak, days.
        let daysBefore: Int, daysAfter: Int
    }

    static let showerCatalog: [MeteorShower] = [
        MeteorShower(name: String(localized: "Quadrantids"), peakMonth: 1, peakDay: 3, zhr: 110,
                     raDeg: 230, decDeg: 49, daysBefore: 6, daysAfter: 9),
        MeteorShower(name: String(localized: "Lyrids"), peakMonth: 4, peakDay: 22, zhr: 18,
                     raDeg: 271, decDeg: 34, daysBefore: 8, daysAfter: 8),
        MeteorShower(name: String(localized: "Eta Aquariids"), peakMonth: 5, peakDay: 5, zhr: 50,
                     raDeg: 338, decDeg: -1, daysBefore: 16, daysAfter: 23),
        MeteorShower(name: String(localized: "Delta Aquariids"), peakMonth: 7, peakDay: 30, zhr: 25,
                     raDeg: 340, decDeg: -16, daysBefore: 18, daysAfter: 24),
        MeteorShower(name: String(localized: "Perseids"), peakMonth: 8, peakDay: 12, zhr: 100,
                     raDeg: 48, decDeg: 58, daysBefore: 26, daysAfter: 12),
        MeteorShower(name: String(localized: "Orionids"), peakMonth: 10, peakDay: 21, zhr: 20,
                     raDeg: 95, decDeg: 16, daysBefore: 19, daysAfter: 17),
        MeteorShower(name: String(localized: "Leonids"), peakMonth: 11, peakDay: 17, zhr: 15,
                     raDeg: 152, decDeg: 22, daysBefore: 11, daysAfter: 13),
        MeteorShower(name: String(localized: "Geminids"), peakMonth: 12, peakDay: 13, zhr: 150,
                     raDeg: 112, decDeg: 33, daysBefore: 9, daysAfter: 7),
        MeteorShower(name: String(localized: "Ursids"), peakMonth: 12, peakDay: 22, zhr: 10,
                     raDeg: 217, decDeg: 76, daysBefore: 5, daysAfter: 4),
    ]

    /// The strongest shower active on `date`, with 0…1 strength that ramps up
    /// toward the peak night and away again. Nil outside every window.
    nonisolated static func activeShower(on date: Date) -> (shower: MeteorShower, strength: Double)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let year = calendar.component(.year, from: date)
        var best: (MeteorShower, Double)?
        for shower in showerCatalog {
            for y in (year - 1)...(year + 1) {
                guard let peak = calendar.date(from: DateComponents(year: y, month: shower.peakMonth,
                                                                    day: shower.peakDay, hour: 22)) else { continue }
                let delta = date.timeIntervalSince(peak) / 86_400
                guard delta >= Double(-shower.daysBefore), delta <= Double(shower.daysAfter) else { continue }
                let span = Double(shower.daysBefore + shower.daysAfter)
                let strength = max(0.12, exp(-0.5 * pow(delta / (span / 5), 2)))
                if strength > (best?.1 ?? 0) { best = (shower, strength) }
            }
        }
        return best
    }

    /// Everything coming up in the next year, soonest first.
    /// Heavy (the eclipse scan computes thousands of ephemerides) — call off
    /// the main thread.
    nonisolated static func upcoming(lat: Double, lon: Double, from now: Date = Date()) -> [SkyEvent] {
        var events: [SkyEvent] = []
        events.append(contentsOf: eclipses(lat: lat, lon: lon, from: now))
        events.append(contentsOf: lunarEclipses(lat: lat, lon: lon, from: now))
        events.append(contentsOf: meteorShowers(from: now))
        events.append(contentsOf: fullMoons(lat: lat, lon: lon, from: now, count: 4))
        events.append(contentsOf: conjunctions(lat: lat, lon: lon, from: now))
        events.append(contentsOf: seasons(lat: lat, lon: lon, from: now))
        return events.sorted { $0.date < $1.date }
    }

    /// Moon distance (km), principal Meeus terms — good to ~0.05%.
    nonisolated static func moonDistanceKm(at date: Date) -> Double {
        let d = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0
        let elong = (297.8502 + 12.19074912 * d) * .pi / 180
        let anomaly = (134.9634 + 13.06499295 * d) * .pi / 180
        return 385_000.56 - 20_905.355 * cos(anomaly)
            - 3_699.111 * cos(2 * elong - anomaly)
            - 2_955.968 * cos(2 * elong) - 569.925 * cos(2 * anomaly)
    }

    // MARK: Solar eclipses (local circumstances)

    /// Apparent solar and lunar disc radii at `date`, degrees. Distance-
    /// corrected (the moon's apparent size swings ±6% perigee→apogee — at a
    /// totality boundary that's the difference between 99% and 100%).
    nonisolated static func discRadii(at date: Date) -> (sun: Double, moon: Double) {
        let d = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0  // days since J2000
        // Sun–Earth distance from orbital eccentricity.
        let g = (357.529 + 0.98560028 * d) * .pi / 180
        let rAU = 1.00014 - 0.01671 * cos(g) - 0.00014 * cos(2 * g)
        let sunR = asin(696_000 / (rAU * 149_597_870.7)) * 180 / .pi
        let moonR = asin(1_737.4 / moonDistanceKm(at: date)) * 180 / .pi
        return (sunR, moonR)
    }

    /// Fraction of the solar disc covered by the moon at angular separation `d`.
    nonisolated static func obscuration(separationDeg d: Double, sunR a: Double, moonR b: Double) -> Double {
        if d >= a + b { return 0 }
        if d <= abs(a - b) { return min(1, (b * b) / (a * a)) }
        let d2 = d * d
        let alpha = acos((d2 + a * a - b * b) / (2 * d * a))
        let beta = acos((d2 + b * b - a * a) / (2 * d * b))
        let overlap = a * a * alpha + b * b * beta
            - 0.5 * sqrt(max(0, (-d + a + b) * (d + a - b) * (d - a + b) * (d + a + b)))
        return min(1, overlap / (.pi * a * a))
    }

    /// Scan the next year for moments the moon bites the sun as seen from
    /// here. Coarse 6-hour sweep finds candidates; minute refinement finds
    /// the local maximum.
    nonisolated static func eclipses(lat: Double, lon: Double, from now: Date) -> [SkyEvent] {
        var results: [SkyEvent] = []
        var t = now
        let end = now.addingTimeInterval(400 * 86_400)
        let coarse: TimeInterval = 6 * 3600
        while t < end {
            let sun = Celestial.sun(date: t, lat: lat, lon: lon)
            let moon = Celestial.moon(date: t, lat: lat, lon: lon)
            let sep = TransitPredictor.separation(az1: sun.az, el1: sun.el,
                                                  az2: moon.az, el2: moon.el)
            if sep < 3.0 {
                if let event = refineEclipse(around: t, lat: lat, lon: lon) {
                    results.append(event)
                    t = t.addingTimeInterval(20 * 86_400)   // skip past this syzygy
                    continue
                }
            }
            t = t.addingTimeInterval(coarse)
        }
        return results
    }

    nonisolated private static func refineEclipse(around center: Date, lat: Double, lon: Double) -> SkyEvent? {
        let radii = discRadii(at: center)   // varies negligibly over the window
        var best: (date: Date, obscuration: Double, separation: Double)?
        var t = center.addingTimeInterval(-8 * 3600)
        let end = center.addingTimeInterval(8 * 3600)
        while t < end {
            let sun = Celestial.sun(date: t, lat: lat, lon: lon)
            if sun.el > -1 {
                let moon = Celestial.moon(date: t, lat: lat, lon: lon)
                let sep = TransitPredictor.separation(az1: sun.az, el1: sun.el,
                                                      az2: moon.az, el2: moon.el)
                let obs = obscuration(separationDeg: sep, sunR: radii.sun, moonR: radii.moon)
                if obs > 0, obs > (best?.obscuration ?? 0) {
                    best = (t, obs, sep)
                }
            }
            t = t.addingTimeInterval(60)
        }
        guard let best, best.obscuration > 0.005 else { return nil }
        let percent = Int((best.obscuration * 100).rounded())
        let annular = radii.moon < radii.sun && best.separation <= radii.sun - radii.moon
        let kindWord = annular ? String(localized: "Annular solar eclipse")
                     : best.obscuration > 0.999 ? String(localized: "Total solar eclipse")
                     : best.obscuration > 0.6 ? String(localized: "Deep partial solar eclipse")
                     : String(localized: "Partial solar eclipse")
        return SkyEvent(
            kind: .eclipse,
            title: kindWord,
            subtitle: String(localized: "\(percent)% of the sun covered, from where you are"),
            date: best.date,
            detail: String(localized: "Maximum at this exact spot. Never look at the sun without proper eclipse glasses."))
    }

    // MARK: Lunar eclipses (local visibility)

    /// Scan the next year for the moon entering Earth's umbra, as seen from
    /// here. The geometry is Earth-centred: the umbra sits exactly at the
    /// anti-solar point, so we test the geocentric moon against it and only
    /// keep eclipses whose maximum happens with the moon above this horizon.
    nonisolated static func lunarEclipses(lat: Double, lon: Double, from now: Date) -> [SkyEvent] {
        var results: [SkyEvent] = []
        var t = now
        let end = now.addingTimeInterval(400 * 86_400)
        while t < end {
            let sep = shadowSeparation(at: t, lat: lat, lon: lon).separation
            if sep < 3.5 {                               // near a full moon
                if let event = refineLunarEclipse(around: t, lat: lat, lon: lon) {
                    results.append(event)
                }
                t = t.addingTimeInterval(20 * 86_400)   // past this syzygy either way
                continue
            }
            t = t.addingTimeInterval(4 * 3600)
        }
        return results
    }

    /// Angular distance between the (geocentric) moon and the umbra's centre.
    nonisolated private static func shadowSeparation(at date: Date, lat: Double, lon: Double)
        -> (separation: Double, moonEl: Double, parallax: Double) {
        let sun = Celestial.sun(date: date, lat: lat, lon: lon)
        let moon = Celestial.moon(date: date, lat: lat, lon: lon)
        let sep = TransitPredictor.separation(az1: sun.az + 180, el1: -sun.el,
                                              az2: moon.az, el2: moon.elGeocentric)
        return (sep, moon.el, moon.parallaxDeg)
    }

    nonisolated private static func refineLunarEclipse(around center: Date, lat: Double, lon: Double) -> SkyEvent? {
        // Coarse bracket: 30-min steps across the syzygy find the minimum
        // cheaply; most full moons miss the umbra and stop here.
        var coarse: (date: Date, separation: Double)?
        var t = center.addingTimeInterval(-9 * 3600)
        while t <= center.addingTimeInterval(9 * 3600) {
            let s = shadowSeparation(at: t, lat: lat, lon: lon).separation
            if s < (coarse?.separation ?? .infinity) { coarse = (t, s) }
            t = t.addingTimeInterval(1800)
        }
        guard let coarse, coarse.separation < 1.7 else { return nil }

        // Fine pass, minutes, only around a genuine umbral approach.
        var best: (date: Date, separation: Double, moonEl: Double, parallax: Double)?
        t = coarse.date.addingTimeInterval(-45 * 60)
        while t <= coarse.date.addingTimeInterval(45 * 60) {
            let s = shadowSeparation(at: t, lat: lat, lon: lon)
            if s.separation < (best?.separation ?? .infinity) {
                best = (t, s.separation, s.moonEl, s.parallax)
            }
            t = t.addingTimeInterval(180)
        }
        guard let best else { return nil }
        // Umbra radius at the moon's distance (Danjon's 2% enlargement).
        let radii = discRadii(at: best.date)
        let umbra = 1.02 * (best.parallax + 0.00245 - radii.sun)
        let magnitude = (umbra + radii.moon - best.separation) / (2 * radii.moon)
        guard magnitude > 0.02 else { return nil }          // penumbral-only: invisible
        guard best.moonEl > -1 else { return nil }          // below this horizon at max
        let total = magnitude >= 1
        return SkyEvent(
            kind: .lunarEclipse,
            title: total ? String(localized: "Total lunar eclipse") : String(localized: "Partial lunar eclipse"),
            subtitle: total ? String(localized: "A blood moon, from where you are")
                            : String(localized: "\(min(99, Int(magnitude * 100)))% of the moon in shadow"),
            date: best.date,
            detail: total
                ? String(localized: "The full moon slides into Earth's shadow and glows copper-red — every sunrise and sunset on Earth, cast onto the moon at once. Perfectly safe to watch with bare eyes.")
                : String(localized: "Earth's shadow takes a dark bite out of the full moon. Perfectly safe to watch with bare eyes; binoculars make the shadow's edge crisp."))
    }

    // MARK: Meteor showers

    nonisolated static func meteorShowers(from now: Date) -> [SkyEvent] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let year = calendar.component(.year, from: now)
        var events: [SkyEvent] = []
        for shower in showerCatalog {
            for y in [year, year + 1] {
                guard let peak = calendar.date(from: DateComponents(year: y, month: shower.peakMonth,
                                                                    day: shower.peakDay, hour: 22)),
                      peak > now, peak < now.addingTimeInterval(370 * 86_400) else { continue }
                events.append(SkyEvent(
                    kind: .meteorShower,
                    title: String(localized: "\(shower.name) peak"),
                    subtitle: String(localized: "Up to \(shower.zhr) meteors per hour"),
                    date: peak,
                    detail: String(localized: "Best after midnight under a dark sky, away from city light.")))
                break
            }
        }
        return events
    }

    // MARK: Full moons

    /// Traditional North American names, by month — the names everyone's
    /// weather app now uses, and they make each full moon its own occasion.
    private static let moonNames = [
        1: String(localized: "Wolf Moon"), 2: String(localized: "Snow Moon"),
        3: String(localized: "Worm Moon"), 4: String(localized: "Pink Moon"),
        5: String(localized: "Flower Moon"), 6: String(localized: "Strawberry Moon"),
        7: String(localized: "Buck Moon"), 8: String(localized: "Sturgeon Moon"),
        9: String(localized: "Harvest Moon"), 10: String(localized: "Hunter's Moon"),
        11: String(localized: "Beaver Moon"), 12: String(localized: "Cold Moon"),
    ]

    nonisolated static func fullMoons(lat: Double, lon: Double, from now: Date, count: Int) -> [SkyEvent] {
        var events: [SkyEvent] = []
        var t = now
        let step: TimeInterval = 6 * 3600
        var previous = Celestial.moon(date: t, lat: lat, lon: lon)
        while events.count < count, t < now.addingTimeInterval(150 * 86_400) {
            let next = Celestial.moon(date: t.addingTimeInterval(step), lat: lat, lon: lon)
            if previous.waxing, !next.waxing {
                // The flip is only bracketed to 6 h — pin the true maximum.
                var peak = t
                var bestIllum = 0.0
                var p = t.addingTimeInterval(-step)
                while p <= t.addingTimeInterval(step) {
                    let illum = Celestial.moon(date: p, lat: lat, lon: lon).illumination
                    if illum > bestIllum { bestIllum = illum; peak = p }
                    p = p.addingTimeInterval(600)
                }
                let month = Calendar.current.component(.month, from: peak)
                let name = moonNames[month] ?? String(localized: "Full moon")
                // Within ~1.6% of perigee counts as a supermoon (~361,000 km).
                let supermoon = moonDistanceKm(at: peak) < 361_000
                events.append(SkyEvent(
                    kind: .fullMoon,
                    title: name,
                    subtitle: supermoon ? String(localized: "A supermoon — the year's biggest and brightest")
                                        : String(localized: "\(monthName(month))'s full moon"),
                    date: peak,
                    detail: supermoon
                        ? String(localized: "This full moon lands near perigee, the moon's closest point to Earth — noticeably bigger and brighter, especially just after moonrise.")
                        : String(localized: "Rises near sunset and stays up all night. \(name) is the traditional name for \(monthName(month))'s full moon.")))
            }
            previous = next
            t = t.addingTimeInterval(step)
        }
        return events
    }

    nonisolated private static func monthName(_ month: Int) -> String {
        DateFormatter().monthSymbols[max(0, min(11, month - 1))]
    }

    // MARK: Planet conjunctions

    /// Naked-eye planets, brightest first — the brighter one leads the title.
    private static let planetRank = ["Venus", "Jupiter", "Mercury", "Mars", "Saturn"]

    /// Pairs of planets passing within 2° of each other in the next year —
    /// the "two lanterns almost touching" moments that make people look up.
    nonisolated static func conjunctions(lat: Double, lon: Double, from now: Date) -> [SkyEvent] {
        // Daily positions for the sweep; refined per candidate below.
        var daily: [[String: (az: Double, el: Double)]] = []
        var sunDaily: [(az: Double, el: Double)] = []
        for day in 0...370 {
            let date = now.addingTimeInterval(Double(day) * 86_400)
            var fixes: [String: (az: Double, el: Double)] = [:]
            for p in Celestial.planets(date: date, lat: lat, lon: lon) {
                fixes[p.name] = (p.az, p.el)
            }
            daily.append(fixes)
            sunDaily.append(Celestial.sun(date: date, lat: lat, lon: lon))
        }

        var events: [SkyEvent] = []
        for i in 0..<planetRank.count {
            for j in (i + 1)..<planetRank.count {
                let (a, b) = (planetRank[i], planetRank[j])
                var lastHit = -100
                for day in 1..<(daily.count - 1) {
                    guard day - lastHit > 30,
                          let pa0 = daily[day - 1][a], let pb0 = daily[day - 1][b],
                          let pa1 = daily[day][a], let pb1 = daily[day][b],
                          let pa2 = daily[day + 1][a], let pb2 = daily[day + 1][b] else { continue }
                    let s0 = TransitPredictor.separation(az1: pa0.az, el1: pa0.el, az2: pb0.az, el2: pb0.el)
                    let s1 = TransitPredictor.separation(az1: pa1.az, el1: pa1.el, az2: pb1.az, el2: pb1.el)
                    let s2 = TransitPredictor.separation(az1: pa2.az, el1: pa2.el, az2: pb2.az, el2: pb2.el)
                    guard s1 < 2.0, s1 <= s0, s1 <= s2 else { continue }
                    // Too close to the sun to see — a conjunction nobody gets.
                    let sunSep = TransitPredictor.separation(az1: pa1.az, el1: pa1.el,
                                                             az2: sunDaily[day].az, el2: sunDaily[day].el)
                    guard sunSep > 12 else { lastHit = day; continue }
                    let date = now.addingTimeInterval(Double(day) * 86_400)
                    let evening = skySide(of: a, on: date, lat: lat, lon: lon) == "evening"
                    events.append(SkyEvent(
                        kind: .conjunction,
                        title: String(localized: "\(Celestial.localizedName(a)) meets \(Celestial.localizedName(b))"),
                        subtitle: evening
                            ? String(localized: "\(s1, specifier: "%.1f")° apart in the evening sky")
                            : String(localized: "\(s1, specifier: "%.1f")° apart in the morning sky"),
                        date: date,
                        detail: String(localized: "Two planets share one small patch of sky — a line-of-sight coincidence hundreds of millions of kilometres deep. Find the brighter one first; its companion sits right beside it.")))
                    lastHit = day
                }
            }
        }
        return events
    }

    // MARK: Lunar occultations

    /// J2000 catalog coordinates precessed to date. The equinox has drifted
    /// ~0.36° since 2000 — wider than the moon's whole disc — so occultation
    /// geometry cannot use raw catalog positions the way star *plotting* can.
    nonisolated private static func precessed(raDeg: Double, decDeg: Double, at date: Date)
        -> (ra: Double, dec: Double) {
        let years = (date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0) / 365.25
        let ra = raDeg * .pi / 180, dec = decDeg * .pi / 180
        let m = 46.1245 / 3600, n = 20.0431 / 3600      // precession rates, deg/yr
        return (raDeg + (m + n * sin(ra) * tan(dec)) * years,
                decDeg + n * cos(ra) * years)
    }

    /// Scan the coming year for the moon covering a naked-eye planet or one
    /// of the bright named stars, from this exact position — the same
    /// "gold shutter" moment as an aircraft transit, delivered by celestial
    /// mechanics instead of a flight plan. Occultations are fiercely local
    /// (lunar parallax swings the moon a full degree between cities), which
    /// is exactly why they're computed here and not read from a table.
    /// Heavy like the eclipse scan — call off the main thread.
    nonisolated static func occultations(lat: Double, lon: Double, from now: Date) -> [SkyEvent] {
        struct Target { let name: String; let isStar: Bool; let ra: Double; let dec: Double }
        var targets: [Target] = planetRank.map { Target(name: $0, isStar: false, ra: 0, dec: 0) }
        // Stars beyond the moon's declination reach can never be covered.
        for star in StarCatalog.namedStars where abs(star.dec) < 29 {
            targets.append(Target(name: star.name, isStar: true, ra: star.ra, dec: star.dec))
        }

        func targetFix(_ t: Target, _ date: Date) -> (az: Double, el: Double)? {
            if t.isStar {
                let p = precessed(raDeg: t.ra, decDeg: t.dec, at: date)
                let h = SkyMath.equatorialToHorizontal(raDeg: p.ra, decDeg: p.dec,
                                                       latDeg: lat, lonDeg: lon, date: date)
                return (h.azimuth, h.elevation)
            }
            return Celestial.planet(t.name, date: date, lat: lat, lon: lon).map { ($0.az, $0.el) }
        }

        var events: [SkyEvent] = []
        let step: TimeInterval = 3 * 3600
        let end = now.addingTimeInterval(380 * 86_400)
        // Local-minimum tracking per target on the coarse grid, exactly like
        // the aircraft transit predictor: refine each dip under the gate.
        var prev = [Double](repeating: .infinity, count: targets.count)
        var prev2 = prev
        var skipUntil = [Date](repeating: .distantPast, count: targets.count)
        var t = now
        while t <= end.addingTimeInterval(step) {
            let date = min(t, end)
            let moon = Celestial.moon(date: date, lat: lat, lon: lon)
            for (i, target) in targets.enumerated() {
                guard date >= skipUntil[i] else { prev2[i] = .infinity; prev[i] = .infinity; continue }
                let s: Double
                if let fix = targetFix(target, date) {
                    s = TransitPredictor.separation(az1: moon.az, el1: moon.el,
                                                    az2: fix.az, el2: fix.el)
                } else { s = .infinity }
                if prev[i] <= prev2[i], prev[i] <= s, prev[i] < 4.0 {
                    if let event = refineOccultation(name: target.name, isStar: target.isStar,
                                                     around: t.addingTimeInterval(-step),
                                                     lat: lat, lon: lon,
                                                     fix: { targetFix(target, $0) }) {
                        events.append(event)
                    }
                    skipUntil[i] = date.addingTimeInterval(5 * 86_400)   // past this lunation
                }
                prev2[i] = prev[i]; prev[i] = s
            }
            t = t.addingTimeInterval(step)
        }
        return events
    }

    /// Pin the moment of minimum separation (5-minute pass, then 20-second
    /// polish) and keep it only if the moon's disc actually covers the
    /// target while both are genuinely watchable from here.
    nonisolated private static func refineOccultation(
        name: String, isStar: Bool, around center: Date, lat: Double, lon: Double,
        fix: (Date) -> (az: Double, el: Double)?) -> SkyEvent? {

        func separation(_ date: Date) -> (sep: Double, moonEl: Double)? {
            guard let f = fix(date) else { return nil }
            let m = Celestial.moon(date: date, lat: lat, lon: lon)
            return (TransitPredictor.separation(az1: m.az, el1: m.el, az2: f.az, el2: f.el), m.el)
        }

        var best: (date: Date, sep: Double, moonEl: Double)?
        var t = center.addingTimeInterval(-3.5 * 3600)
        while t <= center.addingTimeInterval(3.5 * 3600) {
            if let s = separation(t), s.sep < (best?.sep ?? .infinity) {
                best = (t, s.sep, s.moonEl)
            }
            t = t.addingTimeInterval(300)
        }
        guard var found = best, found.sep < 1.2 else { return nil }
        t = found.date.addingTimeInterval(-300)
        let fineEnd = found.date.addingTimeInterval(300)
        while t <= fineEnd {
            if let s = separation(t), s.sep < found.sep { found = (t, s.sep, s.moonEl) }
            t = t.addingTimeInterval(20)
        }

        // Distance-corrected disc radius — perigee vs apogee is a 12% swing,
        // easily the difference between a miss and a cover.
        let moonR = asin(1_737.4 / moonDistanceKm(at: found.date)) * 180 / .pi
        guard found.sep < moonR + 0.06 else { return nil }
        let graze = found.sep > moonR * 0.9
        guard found.moonEl > 3 else { return nil }              // happens below this horizon
        let sunEl = Celestial.sun(date: found.date, lat: lat, lon: lon).el
        guard sunEl < (isStar ? -6 : -1) else { return nil }    // washed out by daylight

        let moon = Celestial.moon(date: found.date, lat: lat, lon: lon)
        let display = Celestial.localizedName(name)
        let vanish = moon.waxing
            ? String(localized: "It vanishes at the moon's dark leading edge — an instant blink, one of astronomy's cleanest tricks.")
            : String(localized: "It slips behind the bright limb and pops back out of the dark edge up to an hour later.")
        return SkyEvent(
            kind: .occultation,
            title: graze ? String(localized: "\(display) grazes the moon")
                         : String(localized: "Moon covers \(display)"),
            subtitle: isStar ? String(localized: "The star winks out behind the moon, from where you are")
                             : String(localized: "The planet slips behind the moon, from where you are"),
            date: found.date,
            detail: graze
                ? String(localized: "From your exact position \(display) skims the moon's limb — a few kilometres north or south and it would miss entirely. Binoculars make the edge dance visible.")
                : String(localized: "The moon slides exactly in front of \(display), timed for your coordinates — observers one city over see it minutes earlier or later. \(vanish) The time shown is mid-cover; start watching half an hour early."))
    }

    /// "evening" if the body is up after dusk, "morning" if before dawn.
    nonisolated private static func skySide(of planet: String, on date: Date,
                                            lat: Double, lon: Double) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        if let evening = calendar.date(bySettingHour: 21, minute: 30, second: 0, of: date),
           let fix = Celestial.planets(date: evening, lat: lat, lon: lon).first(where: { $0.name == planet }),
           fix.el > 3 {
            return "evening"
        }
        return "morning"
    }

    // MARK: Solstices & equinoxes

    /// The year's four turning points, from the sun's declination: zero
    /// crossings are the equinoxes, the extremes are the solstices.
    nonisolated static func seasons(lat: Double, lon: Double, from now: Date) -> [SkyEvent] {
        func declination(_ date: Date) -> Double {
            let s = Celestial.sun(date: date, lat: lat, lon: lon)
            let el = s.el * .pi / 180, az = s.az * .pi / 180, phi = lat * .pi / 180
            return asin(max(-1, min(1, sin(phi) * sin(el) + cos(phi) * cos(el) * cos(az)))) * 180 / .pi
        }
        let north = lat >= 0
        var events: [SkyEvent] = []
        var previous = declination(now)
        var previousSlope = 0.0
        for day in 1...370 {
            let date = now.addingTimeInterval(Double(day) * 86_400)
            let dec = declination(date)
            let slope = dec - previous
            defer { previous = dec; previousSlope = slope }

            // Equinox: declination crosses zero. Refine by bisection to minutes.
            if previous.sign != dec.sign, abs(previous) < 1 || abs(dec) < 1 {
                var lo = date.addingTimeInterval(-86_400), hi = date
                for _ in 0..<16 {
                    let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
                    if declination(mid).sign == previous.sign { lo = mid } else { hi = mid }
                }
                let spring = dec > previous   // sun heading north
                events.append(SkyEvent(
                    kind: .season,
                    title: spring ? String(localized: "March equinox") : String(localized: "September equinox"),
                    subtitle: (spring == north) ? String(localized: "Daylight overtakes the night")
                                                : String(localized: "Night overtakes the daylight"),
                    date: lo,
                    detail: (spring == north)
                        ? String(localized: "The sun crosses the celestial equator, and day and night run nearly equal everywhere on Earth. From here on, days stretch longer until the solstice.")
                        : String(localized: "The sun crosses the celestial equator, and day and night run nearly equal everywhere on Earth. From here on, nights draw longer until the solstice.")))
            }

            // Solstice: the slope flips sign at the extremes.
            if day > 1, previousSlope != 0, slope.sign != previousSlope.sign, abs(previous) > 20 {
                var bestDate = date, bestDec = abs(dec)
                var t = date.addingTimeInterval(-2 * 86_400)
                while t <= date.addingTimeInterval(86_400) {
                    let d = abs(declination(t))
                    if d > bestDec { bestDec = d; bestDate = t }
                    t = t.addingTimeInterval(1800)
                }
                let june = previous > 0
                events.append(SkyEvent(
                    kind: .season,
                    title: june ? String(localized: "June solstice") : String(localized: "December solstice"),
                    subtitle: (june == north) ? String(localized: "The longest day of the year")
                                              : String(localized: "The shortest day of the year"),
                    date: bestDate,
                    detail: String(localized: "Solstice — \"sun stands still.\" The sun pauses at its extreme height before turning back, and sunrise and sunset drift the other way for the next six months.")))
            }
        }
        return events
    }
}
