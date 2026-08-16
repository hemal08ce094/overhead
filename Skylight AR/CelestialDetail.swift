//
//  CelestialDetail.swift
//  Skylight AR
//
//  Tap the sky, get the tower briefing: a detail sheet for the sun, moon,
//  planets, named stars, and the ISS. The position rows are LIVE — recomputed
//  every second from the same SwiftAA math that places the objects in the
//  dome — plus per-body facts (moon phase and distance from its own parallax,
//  planet distances in light-minutes, stellar distances in light-years).
//

import SwiftUI
import SwiftAA

// MARK: - Selection model

struct SelectedBody: Identifiable, Equatable {
    enum Kind { case sun, moon, planet, star, iss }
    let kind: Kind
    let name: String          // English key (localized at display time)
    var ra: Double = 0        // stars only, degrees
    var dec: Double = 0
    var id: String { name }
}

// MARK: - Live math

private enum BodyMath {
    /// Azimuth/elevation for any body right now.
    static func fix(_ body: SelectedBody, date: Date, lat: Double, lon: Double) -> (az: Double, el: Double)? {
        switch body.kind {
        case .sun:  return Celestial.sun(date: date, lat: lat, lon: lon)
        case .moon:
            let m = Celestial.moon(date: date, lat: lat, lon: lon)
            return (m.az, m.el)
        case .planet:
            return Celestial.planets(date: date, lat: lat, lon: lon)
                .first { $0.name == body.name }.map { ($0.az, $0.el) }
        case .star:
            let geo = GeographicCoordinates(positivelyWestwardLongitude: Degree(-lon), latitude: Degree(lat))
            let eq = EquatorialCoordinates(rightAscension: Hour(body.ra / 15), declination: Degree(body.dec))
            let h = eq.makeHorizontalCoordinates(for: geo, at: JulianDay(date))
            return (h.northBasedAzimuth.value, h.altitude.value)
        case .iss:
            return nil            // propagated in the scene; the sheet shows pass info
        }
    }

    /// Next rise and set within 24 h, by scanning the elevation curve.
    /// `horizon` lets the sun ask for civil twilight (-6°) too.
    static func crossings(_ body: SelectedBody, from start: Date, lat: Double, lon: Double,
                          horizon: Double = 0) -> (rise: Date?, set: Date?) {
        var rise: Date?, set: Date?
        var prev = fix(body, date: start, lat: lat, lon: lon)?.el ?? 0
        let step: TimeInterval = 240
        for i in 1...(24 * 15) {
            let t = start.addingTimeInterval(Double(i) * step)
            guard let el = fix(body, date: t, lat: lat, lon: lon)?.el else { break }
            if prev < horizon, el >= horizon, rise == nil { rise = t }
            if prev >= horizon, el < horizon, set == nil { set = t }
            if rise != nil, set != nil { break }
            prev = el
        }
        return (rise, set)
    }

    /// Moon distance from its own horizontal parallax — no extra ephemeris.
    static func moonDistanceKm(date: Date, lat: Double, lon: Double) -> Double {
        let par = Celestial.moon(date: date, lat: lat, lon: lon).parallaxDeg
        guard par > 0 else { return 384_400 }
        return 6378.137 / sin(par * .pi / 180)
    }

    /// Planet distance from Earth right now, in AU.
    static func planetDistanceAU(_ name: String, date: Date) -> Double? {
        let jd = JulianDay(date)
        let planet: Planet?
        switch name {
        case "Mercury": planet = Mercury(julianDay: jd)
        case "Venus":   planet = Venus(julianDay: jd)
        case "Mars":    planet = Mars(julianDay: jd)
        case "Jupiter": planet = Jupiter(julianDay: jd)
        case "Saturn":  planet = Saturn(julianDay: jd)
        default:        planet = nil
        }
        return planet?.trueGeocentricDistance.value
    }

    static func compassDir(_ az: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return dirs[Int(((az + 22.5).truncatingRemainder(dividingBy: 360)) / 45)]
    }
}

// MARK: - Facts

private struct StarFact { let ly: Double; let type: String }

private let starFacts: [String: StarFact] = [
    "Sirius": .init(ly: 8.6, type: "A1 V"), "Canopus": .init(ly: 310, type: "A9 II"),
    "Arcturus": .init(ly: 37, type: "K0 III"), "Vega": .init(ly: 25, type: "A0 V"),
    "Capella": .init(ly: 43, type: "G8 III"), "Rigel": .init(ly: 860, type: "B8 Ia"),
    "Procyon": .init(ly: 11.5, type: "F5 IV"), "Betelgeuse": .init(ly: 640, type: "M1 Ia"),
    "Altair": .init(ly: 16.7, type: "A7 V"), "Aldebaran": .init(ly: 65, type: "K5 III"),
    "Antares": .init(ly: 550, type: "M1 Ib"), "Spica": .init(ly: 250, type: "B1 V"),
    "Pollux": .init(ly: 34, type: "K0 III"), "Fomalhaut": .init(ly: 25, type: "A3 V"),
    "Deneb": .init(ly: 2600, type: "A2 Ia"), "Regulus": .init(ly: 79, type: "B8 IV"),
    "Polaris": .init(ly: 430, type: "F7 Ib"), "Castor": .init(ly: 51, type: "A1 V"),
    "Achernar": .init(ly: 139, type: "B6 V"),
]

private let planetFacts: [String: (moons: Int, dayHours: Double, yearDays: Double)] = [
    "Mercury": (0, 4222.6, 88), "Venus": (0, 2802.0, 225),
    "Mars": (2, 24.7, 687), "Jupiter": (95, 9.9, 4333), "Saturn": (274, 10.7, 10759),
]

// MARK: - The sheet

struct BodyDetailSheet: View {
    let body_: SelectedBody
    @Bindable var engine: SkyEngine
    @Environment(\.dismiss) private var dismiss

    // Last known observer position (Siri and the events loader share this
    // slot); zero means never located — stand in the demo sky's spot.
    private var lat: Double {
        let v = UserDefaults.standard.double(forKey: SkyDefaults.lastLat)
        return v != 0 ? v : 37.6213
    }
    private var lon: Double {
        let v = UserDefaults.standard.double(forKey: SkyDefaults.lastLon)
        return v != 0 ? v : -122.3790
    }

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                let now = tl.date.addingTimeInterval(engine.skyTimeOffsetMin * 60)
                VStack(alignment: .leading, spacing: 22) {
                    header
                    liveCard(at: now)
                    factsCard(at: now)
                }
                .padding(24)
            }
        }
        .scrollContentBackground(.hidden)
        .presentationDetents([.medium, .large])
        .presentationBackground {
            Color.clear
                .glassEffectCompat(.regular.tint(Theme.nightBottom.opacity(0.45)),
                             in: .rect(cornerRadius: 38))
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
    }

    private var kindLabel: String {
        switch body_.kind {
        case .sun: String(localized: "Our star")
        case .moon: String(localized: "Earth's moon")
        case .planet: String(localized: "Planet")
        case .star: String(localized: "Star")
        case .iss: String(localized: "International Space Station")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Celestial.localizedName(body_.name))
                    .font(Theme.display(34, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(kindLabel)
                    .font(Theme.display(15, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // The live rows: recomputed every second from the sheet's own clock.
    @ViewBuilder private func liveCard(at now: Date) -> some View {
        VStack(spacing: 0) {
            if let f = BodyMath.fix(body_, date: now, lat: lat, lon: lon) {
                row(String(localized: "In your sky"),
                    f.el >= 0
                        ? String(localized: "Up now — \(BodyMath.compassDir(f.az)), \(Int(f.el.rounded()))° high")
                        : String(localized: "Below the horizon"),
                    live: true)
                divider
                row(String(localized: "Azimuth"), "\(BodyMath.compassDir(f.az)) \(Int(f.az.rounded()))°")
                divider
                let c = BodyMath.crossings(body_, from: now, lat: lat, lon: lon)
                if let rise = c.rise {
                    row(String(localized: "Rises"), rise.formatted(date: .omitted, time: .shortened))
                    divider
                }
                if let set = c.set {
                    row(String(localized: "Sets"), set.formatted(date: .omitted, time: .shortened))
                    divider
                }
            }
            switch body_.kind {
            case .sun:
                let civil = BodyMath.crossings(body_, from: now, lat: lat, lon: lon, horizon: -6)
                if let dusk = civil.set {
                    row(String(localized: "Civil dusk"), dusk.formatted(date: .omitted, time: .shortened))
                    divider
                }
                if let dawn = civil.rise {
                    row(String(localized: "Civil dawn"), dawn.formatted(date: .omitted, time: .shortened))
                    divider
                }
                row(String(localized: "Distance"), String(localized: "8.3 light-minutes"))
            case .moon:
                let m = Celestial.moon(date: now, lat: lat, lon: lon)
                row(String(localized: "Phase"),
                    "\(Int((m.illumination * 100).rounded()))% " +
                    (m.waxing ? String(localized: "lit, waxing") : String(localized: "lit, waning")),
                    live: true)
                divider
                let km = BodyMath.moonDistanceKm(date: now, lat: lat, lon: lon)
                row(String(localized: "Distance right now"),
                    String(localized: "\(Int(km).formatted()) km · \(String(format: "%.1f", km / 299_792.458)) light-seconds"),
                    live: true)
            case .planet:
                if let au = BodyMath.planetDistanceAU(body_.name, date: now) {
                    row(String(localized: "Distance right now"),
                        String(format: "%.2f AU", au), live: true)
                    divider
                    row(String(localized: "Its light left"),
                        String(localized: "\(Int((au * 8.3168).rounded())) minutes ago"), live: true)
                }
            case .star:
                if let fact = starFacts[body_.name] {
                    row(String(localized: "Distance"), String(localized: "\(fact.ly.formatted()) light-years"))
                    divider
                    row(String(localized: "The light you see left"), yearLabel(fact.ly, now: now))
                }
            case .iss:
                row(String(localized: "In your sky"),
                    engine.issVisible ? String(localized: "Overhead now — look for the moving light")
                                      : String(localized: "Below the horizon"),
                    live: true)
            }
        }
        .nightCard()
    }

    @ViewBuilder private func factsCard(at now: Date) -> some View {
        VStack(spacing: 0) {
            switch body_.kind {
            case .planet:
                if let f = planetFacts[body_.name] {
                    row(String(localized: "Moons"), f.moons.formatted())
                    divider
                    row(String(localized: "Day length"), String(localized: "\(f.dayHours.formatted()) hours"))
                    divider
                    row(String(localized: "Year length"), String(localized: "\(Int(f.yearDays).formatted()) Earth days"))
                }
            case .star:
                if let fact = starFacts[body_.name] {
                    row(String(localized: "Spectral type"), fact.type)
                    if let cat = StarCatalog.namedStars.first(where: { $0.name == body_.name }) {
                        divider
                        row(String(localized: "Position (RA / Dec)"),
                            String(format: "%.1f° / %+.1f°", cat.ra, cat.dec))
                    }
                }
            case .moon:
                row(String(localized: "Diameter"), String(localized: "3,475 km — about as wide as Australia"))
            case .sun:
                row(String(localized: "Diameter"), String(localized: "109 Earths across"))
                divider
                row(String(localized: "Never look directly at it"), String(localized: "especially through optics"))
            case .iss:
                row(String(localized: "Orbit"), String(localized: "~420 km up · one lap every 92 minutes"))
                divider
                row(String(localized: "Speed"), String(localized: "~27,600 km/h — horizon to horizon in minutes"))
                divider
                Button {
                    dismiss()
                    engine.jumpToNextISSPass()
                } label: {
                    HStack {
                        Label(String(localized: "Jump sky to the next pass"),
                              systemImage: "clock.arrow.2.circlepath")
                            .font(Theme.display(15, .semibold))
                            .foregroundStyle(Theme.accent)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .nightCard()
    }

    private func yearLabel(_ ly: Double, now: Date) -> String {
        let year = Calendar.current.component(.year, from: now) - Int(ly.rounded())
        return year > 0 ? String(localized: "in the year \(String(year))")
                        : String(localized: "\(Int(ly.rounded()).formatted()) years ago")
    }

    private var divider: some View {
        Divider().overlay(.white.opacity(0.08)).padding(.leading, 16)
    }

    private func row(_ title: String, _ value: String, live: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if live {
                Circle().fill(Theme.gold).frame(width: 5, height: 5)
                    .offset(y: -2)
            }
            Text(title)
                .font(Theme.display(14, .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            Text(value)
                .font(Theme.display(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}
