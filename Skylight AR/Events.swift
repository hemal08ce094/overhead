//
//  Events.swift
//  Overhead
//
//  The sky calendar: solar eclipses discovered by scanning sun–moon disc
//  overlaps from the observer's own position (real local circumstances, no
//  bundled tables), the major meteor showers, and the coming full moons.
//

import Foundation

struct SkyEvent: Identifiable, Equatable {
    enum Kind { case eclipse, meteorShower, fullMoon }
    let kind: Kind
    let title: String
    let subtitle: String
    let date: Date
    let detail: String

    var id: String { "\(title)-\(date.timeIntervalSince1970)" }
}

enum EventsCalendar {

    /// Major annual showers (IMO): name, peak month/day, ZHR.
    private static let showers: [(String, Int, Int, Int)] = [
        ("Quadrantids", 1, 3, 110), ("Lyrids", 4, 22, 18),
        ("Eta Aquariids", 5, 5, 50), ("Delta Aquariids", 7, 30, 25),
        ("Perseids", 8, 12, 100), ("Orionids", 10, 21, 20),
        ("Leonids", 11, 17, 15), ("Geminids", 12, 13, 150),
        ("Ursids", 12, 22, 10),
    ]

    /// Everything coming up in the next year, soonest first.
    /// Heavy (the eclipse scan computes thousands of ephemerides) — call off
    /// the main thread.
    nonisolated static func upcoming(lat: Double, lon: Double, from now: Date = Date()) -> [SkyEvent] {
        var events: [SkyEvent] = []
        events.append(contentsOf: eclipses(lat: lat, lon: lon, from: now))
        events.append(contentsOf: meteorShowers(from: now))
        events.append(contentsOf: fullMoons(lat: lat, lon: lon, from: now, count: 3))
        return events.sorted { $0.date < $1.date }
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
        // Moon distance, principal Meeus terms (km) — good to ~0.05%.
        let elong = (297.8502 + 12.19074912 * d) * .pi / 180
        let anomaly = (134.9634 + 13.06499295 * d) * .pi / 180
        let dist = 385_000.56 - 20_905.355 * cos(anomaly)
            - 3_699.111 * cos(2 * elong - anomaly)
            - 2_955.968 * cos(2 * elong) - 569.925 * cos(2 * anomaly)
        let moonR = asin(1_737.4 / dist) * 180 / .pi
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
        let kindWord = annular ? "Annular solar eclipse"
                     : best.obscuration > 0.999 ? "Total solar eclipse"
                     : best.obscuration > 0.6 ? "Deep partial solar eclipse"
                     : "Partial solar eclipse"
        return SkyEvent(
            kind: .eclipse,
            title: kindWord,
            subtitle: "\(percent)% of the sun covered, from where you are",
            date: best.date,
            detail: "Maximum at this exact spot. Never look at the sun without proper eclipse glasses.")
    }

    // MARK: Meteor showers

    nonisolated static func meteorShowers(from now: Date) -> [SkyEvent] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let year = calendar.component(.year, from: now)
        var events: [SkyEvent] = []
        for (name, month, day, zhr) in showers {
            for y in [year, year + 1] {
                guard let peak = calendar.date(from: DateComponents(year: y, month: month, day: day, hour: 22)),
                      peak > now, peak < now.addingTimeInterval(370 * 86_400) else { continue }
                events.append(SkyEvent(
                    kind: .meteorShower,
                    title: "\(name) peak",
                    subtitle: "Up to \(zhr) meteors per hour",
                    date: peak,
                    detail: "Best after midnight under a dark sky, away from city light."))
                break
            }
        }
        return events
    }

    // MARK: Full moons

    nonisolated static func fullMoons(lat: Double, lon: Double, from now: Date, count: Int) -> [SkyEvent] {
        var events: [SkyEvent] = []
        var t = now
        let step: TimeInterval = 6 * 3600
        var previous = Celestial.moon(date: t, lat: lat, lon: lon)
        while events.count < count, t < now.addingTimeInterval(120 * 86_400) {
            let next = Celestial.moon(date: t.addingTimeInterval(step), lat: lat, lon: lon)
            if previous.waxing, !next.waxing {
                events.append(SkyEvent(
                    kind: .fullMoon,
                    title: "Full moon",
                    subtitle: "The disc at one hundred percent",
                    date: t,
                    detail: "Rises near sunset and stays up all night."))
            }
            previous = next
            t = t.addingTimeInterval(step)
        }
        return events
    }
}
