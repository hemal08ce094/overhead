//
//  MedalStore.swift
//  Skylight AR
//
//  Tiers and medals for plane spotting. All progress lives on this device —
//  same privacy story as every other stat. Award logic is pure and synchronous;
//  the store persists one JSON blob and publishes newly-earned medals for the
//  sky screen's banner.
//

import SwiftUI
import Observation

// MARK: - Model

struct Medal: Identifiable, Equatable {
    /// Metal the medal is struck in — drives the 3D material and 2D thumb.
    enum Finish: String, Codable {
        case bronze, steel, silver, gold, night
    }

    /// What's engraved on the face.
    enum Emblem: Equatable {
        case symbol(String)                 // an SF Symbol silhouette
        case count(Int)                     // big engraved milestone number
        case constellation                  // linked star pattern
        case rotor                          // four-blade rotor cross
        case transit                        // plane crossing the moon disc
        case issStreak                      // the station's diamond + trail
    }

    let id: String
    let name: String
    let requirement: String
    let finish: Finish
    let emblem: Emblem
    let caption: String?                    // small engraved line under the emblem
    let target: Int
}

struct MedalAward: Codable, Equatable {
    var date: Date
    var detail: String?                     // "ASA235 · B39M" — what earned it
}

struct SpotterTier: Equatable {
    let name: String
    let threshold: Int
    let finish: Medal.Finish
}

// MARK: - Catalog

enum MedalCatalog {
    static let tiers: [SpotterTier] = [
        SpotterTier(name: String(localized: "Observer"),      threshold: 0,    finish: .bronze),
        SpotterTier(name: String(localized: "Spotter"),       threshold: 10,   finish: .bronze),
        SpotterTier(name: String(localized: "Sky Watcher"),   threshold: 25,   finish: .bronze),
        SpotterTier(name: String(localized: "Sky Tracker"),   threshold: 50,   finish: .steel),
        SpotterTier(name: String(localized: "Plane Chaser"),  threshold: 100,  finish: .steel),
        SpotterTier(name: String(localized: "Navigator"),     threshold: 200,  finish: .silver),
        SpotterTier(name: String(localized: "Aviator"),       threshold: 350,  finish: .silver),
        SpotterTier(name: String(localized: "Captain"),       threshold: 500,  finish: .gold),
        SpotterTier(name: String(localized: "Commander"),     threshold: 750,  finish: .gold),
        SpotterTier(name: String(localized: "Constellation"), threshold: 1000, finish: .night),
        SpotterTier(name: String(localized: "Voyager"),       threshold: 2500, finish: .night),
        SpotterTier(name: String(localized: "Legend"),        threshold: 5000, finish: .night),
    ]

    static func tier(forSpots n: Int) -> SpotterTier {
        tiers.last { n >= $0.threshold } ?? tiers[0]
    }

    static func nextTier(forSpots n: Int) -> SpotterTier? {
        tiers.first { n < $0.threshold }
    }

    static let all: [Medal] = [
        Medal(id: "first", name: String(localized: "First Contact"),
              requirement: String(localized: "Spot your first aircraft in the sky."),
              finish: .bronze, emblem: .symbol("airplane"), caption: nil, target: 1),
        Medal(id: "spots10", name: String(localized: "Spotter's Wings"),
              requirement: String(localized: "Spot 10 flights."),
              finish: .bronze, emblem: .count(10), caption: String(localized: "FLIGHTS"), target: 10),
        Medal(id: "spots25", name: String(localized: "Sky Watcher"),
              requirement: String(localized: "Spot 25 flights."),
              finish: .bronze, emblem: .count(25), caption: String(localized: "FLIGHTS"), target: 25),
        Medal(id: "spots50", name: String(localized: "Sky Tracker"),
              requirement: String(localized: "Spot 50 flights."),
              finish: .steel, emblem: .count(50), caption: String(localized: "FLIGHTS"), target: 50),
        Medal(id: "spots100", name: String(localized: "Plane Chaser"),
              requirement: String(localized: "Spot 100 flights."),
              finish: .steel, emblem: .count(100), caption: String(localized: "FLIGHTS"), target: 100),
        Medal(id: "spots200", name: String(localized: "Navigator"),
              requirement: String(localized: "Spot 200 flights."),
              finish: .silver, emblem: .count(200), caption: String(localized: "FLIGHTS"), target: 200),
        Medal(id: "spots350", name: String(localized: "Aviator"),
              requirement: String(localized: "Spot 350 flights."),
              finish: .silver, emblem: .count(350), caption: String(localized: "FLIGHTS"), target: 350),
        Medal(id: "spots500", name: String(localized: "Captain"),
              requirement: String(localized: "Spot 500 flights."),
              finish: .gold, emblem: .count(500), caption: String(localized: "FLIGHTS"), target: 500),
        Medal(id: "spots750", name: String(localized: "Commander"),
              requirement: String(localized: "Spot 750 flights."),
              finish: .gold, emblem: .count(750), caption: String(localized: "FLIGHTS"), target: 750),
        Medal(id: "spots1000", name: String(localized: "Constellation"),
              requirement: String(localized: "Spot 1,000 flights."),
              finish: .night, emblem: .constellation, caption: "1000", target: 1000),
        Medal(id: "spots2500", name: String(localized: "Voyager"),
              requirement: String(localized: "Spot 2,500 flights."),
              finish: .night, emblem: .symbol("sparkles"), caption: "2500", target: 2500),
        Medal(id: "spots5000", name: String(localized: "Legend"),
              requirement: String(localized: "Spot 5,000 flights."),
              finish: .night, emblem: .symbol("trophy.fill"), caption: "5000", target: 5000),
        Medal(id: "superjumbo", name: String(localized: "Superjumbo"),
              requirement: String(localized: "Spot an Airbus A380 — the biggest airliner flying."),
              finish: .silver, emblem: .symbol("airplane"), caption: "A380", target: 1),
        Medal(id: "queen", name: String(localized: "Queen of the Skies"),
              requirement: String(localized: "Spot a Boeing 747."),
              finish: .silver, emblem: .symbol("crown.fill"), caption: "747", target: 1),
        Medal(id: "widebodies", name: String(localized: "Widebody Collector"),
              requirement: String(localized: "Spot five different widebody types."),
              finish: .gold, emblem: .symbol("airplane"), caption: String(localized: "5 TYPES"), target: 5),
        Medal(id: "heavymetal", name: String(localized: "Heavy Metal"),
              requirement: String(localized: "Spot 25 widebodies."),
              finish: .gold, emblem: .count(25), caption: String(localized: "HEAVIES"), target: 25),
        Medal(id: "rotor", name: String(localized: "Rotorhead"),
              requirement: String(localized: "Spot a helicopter."),
              finish: .steel, emblem: .rotor, caption: nil, target: 1),
        Medal(id: "nightowl", name: String(localized: "Night Owl"),
              requirement: String(localized: "Spot 10 flights after midnight."),
              finish: .night, emblem: .symbol("moon.stars.fill"), caption: String(localized: "AFTER 12"), target: 10),
        Medal(id: "globetrotter", name: String(localized: "Globetrotter"),
              requirement: String(localized: "Spot flights bound for 10 different countries."),
              finish: .gold, emblem: .symbol("globe"), caption: String(localized: "COUNTRIES"), target: 10),
        Medal(id: "transit", name: String(localized: "Transit Hunter"),
              requirement: String(localized: "Capture a plane crossing the sun or the moon."),
              finish: .gold, emblem: .transit, caption: nil, target: 1),
        Medal(id: "starsailor", name: String(localized: "Star Sailor"),
              requirement: String(localized: "Catch the ISS passing overhead."),
              finish: .steel, emblem: .issStreak, caption: "ISS", target: 1),

        // The expanded shelf: every one earnable from what a spot already
        // tells us — type, category, callsign, time, destination.
        Medal(id: "props", name: String(localized: "Propliner"),
              requirement: String(localized: "Spot a turboprop airliner."),
              finish: .bronze, emblem: .symbol("fanblades.fill"), caption: nil, target: 1),
        Medal(id: "lightwings", name: String(localized: "Little Wings"),
              requirement: String(localized: "Spot 10 light general-aviation aircraft."),
              finish: .bronze, emblem: .symbol("paperplane.fill"),
              caption: String(localized: "LIGHT AIRCRAFT"), target: 10),
        Medal(id: "newyear", name: String(localized: "First Light"),
              requirement: String(localized: "Spot a flight on New Year's Day."),
              finish: .bronze, emblem: .symbol("sparkles"), caption: String(localized: "JAN 1"), target: 1),
        Medal(id: "earlybird", name: String(localized: "Dawn Patrol"),
              requirement: String(localized: "Spot 10 flights before 7 in the morning."),
              finish: .steel, emblem: .symbol("sunrise.fill"),
              caption: String(localized: "BEFORE 7"), target: 10),
        Medal(id: "busysky", name: String(localized: "Busy Sky"),
              requirement: String(localized: "Spot 20 flights in a single day."),
              finish: .steel, emblem: .count(20), caption: String(localized: "ONE DAY"), target: 20),
        Medal(id: "ritual", name: String(localized: "Daily Ritual"),
              requirement: String(localized: "Spot flights on 7 different days."),
              finish: .steel, emblem: .symbol("calendar"), caption: String(localized: "DAYS"), target: 7),
        Medal(id: "triple7", name: String(localized: "Triple Seven"),
              requirement: String(localized: "Spot a Boeing 777."),
              finish: .silver, emblem: .count(777), caption: String(localized: "BOEING"), target: 1),
        Medal(id: "dreamliner", name: String(localized: "Dreamliner"),
              requirement: String(localized: "Spot a Boeing 787 Dreamliner."),
              finish: .silver, emblem: .symbol("airplane"), caption: "787", target: 1),
        Medal(id: "quadjet", name: String(localized: "Four Engines"),
              requirement: String(localized: "Spot 5 four-engine aircraft."),
              finish: .silver, emblem: .symbol("circle.grid.2x2.fill"),
              caption: String(localized: "QUADS"), target: 5),
        Medal(id: "typecollector", name: String(localized: "Type Collector"),
              requirement: String(localized: "Spot 15 different aircraft types."),
              finish: .gold, emblem: .symbol("square.grid.3x3.fill"),
              caption: String(localized: "TYPES"), target: 15),
        Medal(id: "liverycollector", name: String(localized: "Airline Collector"),
              requirement: String(localized: "Spot flights from 20 different airlines."),
              finish: .gold, emblem: .symbol("tag.fill"),
              caption: String(localized: "AIRLINES"), target: 20),
        Medal(id: "whale", name: String(localized: "Whale Watcher"),
              requirement: String(localized: "Spot an outsize freighter — a Beluga, Dreamlifter or Antonov 124."),
              finish: .gold, emblem: .symbol("fish.fill"), caption: nil, target: 1),
        Medal(id: "continental", name: String(localized: "World Tour"),
              requirement: String(localized: "Spot flights bound for 25 different countries."),
              finish: .night, emblem: .symbol("globe.americas.fill"),
              caption: String(localized: "COUNTRIES"), target: 25),
        Medal(id: "heavycentury", name: String(localized: "Century of Heavies"),
              requirement: String(localized: "Spot 100 widebodies."),
              finish: .night, emblem: .count(100), caption: String(localized: "HEAVIES"), target: 100),
        Medal(id: "graveyard", name: String(localized: "Graveyard Shift"),
              requirement: String(localized: "Spot 50 flights after midnight."),
              finish: .night, emblem: .symbol("moon.zzz.fill"),
              caption: String(localized: "AFTER 12"), target: 50),
    ]

    static func medal(_ id: String) -> Medal? { all.first { $0.id == id } }

    /// The tier-milestone medals, highest first — used to pick the "featured"
    /// medal (your best) and to keep milestones out of the browsable grid.
    static let milestoneOrder = ["spots5000", "spots2500", "spots1000", "spots750",
                                 "spots500", "spots350", "spots200", "spots100",
                                 "spots50", "spots25", "spots10", "first"]

    /// The milestone medal that represents a tier.
    static func medalID(for tier: SpotterTier) -> String {
        switch tier.threshold {
        case 5000...: return "spots5000"
        case 2500...: return "spots2500"
        case 1000...: return "spots1000"
        case 750...:  return "spots750"
        case 500...:  return "spots500"
        case 350...:  return "spots350"
        case 200...:  return "spots200"
        case 100...:  return "spots100"
        case 50...:   return "spots50"
        case 25...:   return "spots25"
        case 10...:   return "spots10"
        default:      return "first"
        }
    }

    /// ICAO type-code prefixes that count as widebodies.
    static let widebodyPrefixes = ["A33", "A34", "A35", "A38", "B74", "B76", "B77", "B78",
                                   "MD11", "DC10", "IL96", "IL86", "A306", "A30B", "A310", "L101"]

    /// Helicopter type-code prefixes, as a fallback when the ADS-B emitter
    /// category ("A7" = rotorcraft) is missing.
    static let rotorPrefixes = ["EC1", "EC2", "EC3", "EC6", "H12", "H13", "H14", "H15", "H16",
                                "H25", "H47", "H53", "H60", "H64", "AS3", "AS5", "R22", "R44",
                                "R66", "B06", "B105", "B407", "B412", "B429", "B430", "A109",
                                "A119", "A139", "A149", "A169", "A189", "S61", "S64", "S76",
                                "S92", "MI8", "MI17", "UH1"]

    static func isWidebody(_ type: String?) -> Bool {
        guard let t = type?.uppercased() else { return false }
        return widebodyPrefixes.contains { t.hasPrefix($0) }
    }

    /// Turboprop airliners and workhorses.
    static let propPrefixes = ["AT4", "AT7", "DH8", "DHC", "SF34", "SW4", "E120", "D328",
                               "JS31", "JS41", "F50", "L410", "BE20", "B190", "PC12",
                               "TBM", "C208", "AN2"]

    /// Light general-aviation singles and twins.
    static let gaPrefixes = ["C150", "C152", "C162", "C172", "C177", "C182", "C206", "C210",
                             "P28", "PA18", "PA24", "PA32", "PA34", "PA44", "SR20", "SR22",
                             "DA20", "DA40", "DA42", "DA62", "BE33", "BE35", "BE36", "BE58",
                             "M20", "RV4", "RV6", "RV7", "RV8", "RV9", "RV1", "AA5", "C42"]

    /// Four-engine aircraft still flying. (No "C17"-style prefixes — they'd
    /// swallow the C172.)
    static let quadPrefixes = ["A38", "B74", "A34", "IL96", "IL86", "IL76", "A124", "AN12", "A400"]

    /// The outsize freighters people cross town for.
    static let whalePrefixes = ["A3ST", "A337", "BLCF", "A124", "A225", "AN22"]

    static func isProp(_ t: String) -> Bool { propPrefixes.contains { t.hasPrefix($0) } }
    static func isGA(_ t: String) -> Bool { gaPrefixes.contains { t.hasPrefix($0) } }
    static func isQuad(_ t: String) -> Bool { quadPrefixes.contains { t.hasPrefix($0) } }
    static func isWhale(_ t: String) -> Bool { whalePrefixes.contains { t.hasPrefix($0) } }

    /// "BAW123" → "BAW": the operator's ICAO code, when the callsign has one.
    static func airlineCode(from callsign: String?) -> String? {
        guard let c = callsign?.trimmingCharacters(in: .whitespaces).uppercased(),
              c.count >= 4 else { return nil }
        let code = String(c.prefix(3))
        guard code.allSatisfy(\.isLetter), c.dropFirst(3).first?.isNumber == true else { return nil }
        return code
    }

    static func isHelicopter(type: String?, category: String?) -> Bool {
        if category?.uppercased() == "A7" { return true }
        guard let t = type?.uppercased() else { return false }
        return rotorPrefixes.contains { t.hasPrefix($0) }
    }
}

// MARK: - Store

@MainActor
@Observable
final class MedalStore {

    private struct State: Codable {
        var earned: [String: MedalAward] = [:]
        var widebodyTypes: Set<String> = []
        var widebodyCount = 0
        var nightCount = 0
        var countries: Set<String> = []
        var superjumboSeen = false
        var queenSeen = false
        var rotorSeen = false
        var transitCaptured = false
        var issCaught = false
        var seeded = false
        // Expanded shelf (2026-07). Every new field decodes with a default so
        // existing stored blobs load untouched.
        var earlyCount = 0
        var gaCount = 0
        var propSeen = false
        var triple7Seen = false
        var dreamlinerSeen = false
        var whaleSeen = false
        var newYearSeen = false
        var quadCount = 0
        var typesSeen: Set<String> = []
        var airlines: Set<String> = []
        var daysActive: Set<String> = []
        var dayKey = ""
        var dayCount = 0
        var bestDay = 0

        init() {}

        // Custom decode: every field optional-with-default, so adding medals
        // never invalidates a spotter's saved progress.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T {
                ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? d
            }
            earned = v(.earned, [:]); widebodyTypes = v(.widebodyTypes, [])
            widebodyCount = v(.widebodyCount, 0); nightCount = v(.nightCount, 0)
            countries = v(.countries, []); superjumboSeen = v(.superjumboSeen, false)
            queenSeen = v(.queenSeen, false); rotorSeen = v(.rotorSeen, false)
            transitCaptured = v(.transitCaptured, false); issCaught = v(.issCaught, false)
            seeded = v(.seeded, false)
            earlyCount = v(.earlyCount, 0); gaCount = v(.gaCount, 0)
            propSeen = v(.propSeen, false); triple7Seen = v(.triple7Seen, false)
            dreamlinerSeen = v(.dreamlinerSeen, false); whaleSeen = v(.whaleSeen, false)
            newYearSeen = v(.newYearSeen, false); quadCount = v(.quadCount, 0)
            typesSeen = v(.typesSeen, []); airlines = v(.airlines, [])
            daysActive = v(.daysActive, []); dayKey = v(.dayKey, "")
            dayCount = v(.dayCount, 0); bestDay = v(.bestDay, 0)
        }
    }

    private var state = State() { didSet { persist() } }
    private static let key = "medals.v1"

    /// Latest live award, for the sky screen's banner. Cleared on tap/dismiss.
    var pendingReveal: Medal?

    private(set) var earned: [String: MedalAward] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let restored = try? JSONDecoder().decode(State.self, from: data) {
            state = restored
        }
        earned = state.earned
    }

    private func persist() {
        earned = state.earned
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    #if DEBUG
    /// A rich, believable medal state for App Store screenshots — a spread of
    /// earned milestones and special medals, a few still in progress. DEBUG only,
    /// written straight to storage before the store loads.
    static func seedDemoState() {
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        let earned: [String: MedalAward] = [
            "first":      MedalAward(date: ago(41), detail: "EK203 · A388"),
            "spots10":    MedalAward(date: ago(37), detail: nil),
            "spots25":    MedalAward(date: ago(31), detail: nil),
            "spots50":    MedalAward(date: ago(25), detail: nil),
            "spots100":   MedalAward(date: ago(15), detail: nil),
            "spots200":   MedalAward(date: ago(5),  detail: "BA106 · B77W"),
            "superjumbo": MedalAward(date: ago(34), detail: "EK203 · A388"),
            "queen":      MedalAward(date: ago(22), detail: "BA001 · B744"),
            "rotor":      MedalAward(date: ago(28), detail: "N911EV · H60"),
            "starsailor": MedalAward(date: ago(12), detail: nil),
            "nightowl":   MedalAward(date: ago(9),  detail: nil),
        ]
        var state = State()
        state.earned = earned
        state.widebodyTypes = ["A388", "B77W", "A359", "B789"]
        state.widebodyCount = 22
        state.nightCount = 12
        state.countries = ["AE", "GB", "US", "DE", "SG", "JP", "FR"]
        state.superjumboSeen = true; state.queenSeen = true; state.rotorSeen = true
        state.issCaught = true; state.seeded = true
        // The new shelf, mid-collection — believable and hungry.
        state.propSeen = true; state.triple7Seen = true; state.dreamlinerSeen = true
        state.earlyCount = 6; state.gaCount = 4; state.quadCount = 3
        state.typesSeen = ["A388", "B77W", "A359", "B789", "A320", "A321", "B738",
                           "E190", "AT76", "DH8D", "B744"]
        state.airlines = ["UAE", "BAW", "UAL", "DLH", "SIA", "QFA", "AFR", "ETD",
                          "QTR", "THY", "KLM", "SWR"]
        state.daysActive = Set((1...5).map { "2026-07-0\($0)" })
        state.bestDay = 14
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    #endif

    // MARK: Events

    /// One-time backfill so a long-time spotter's milestones don't reset to
    /// zero the day medals ship. No banner, no dates fabricated per-medal.
    func seed(totalSpots: Int) {
        guard !state.seeded else { return }
        state.seeded = true
        evaluate(totalSpots: totalSpots, celebrate: false, detail: nil)
    }

    func recordSpot(totalSpots: Int, type: String?, category: String?,
                    callsign: String?, at date: Date = Date()) {
        if let t = type?.uppercased(), !t.isEmpty {
            state.typesSeen.insert(t)
            if CatalogCheck.widebody(t) {
                state.widebodyTypes.insert(t)
                state.widebodyCount += 1
            }
            if t.hasPrefix("A38") { state.superjumboSeen = true }
            if t.hasPrefix("B74") { state.queenSeen = true }
            if t.hasPrefix("B77") { state.triple7Seen = true }
            if t.hasPrefix("B78") { state.dreamlinerSeen = true }
            if MedalCatalog.isProp(t) { state.propSeen = true }
            if MedalCatalog.isGA(t) { state.gaCount += 1 }
            if MedalCatalog.isQuad(t) { state.quadCount += 1 }
            if MedalCatalog.isWhale(t) { state.whaleSeen = true }
        }
        if MedalCatalog.isHelicopter(type: type, category: category) { state.rotorSeen = true }
        if let airline = MedalCatalog.airlineCode(from: callsign) { state.airlines.insert(airline) }

        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        if let h = parts.hour {
            if h < 5 { state.nightCount += 1 }
            else if h < 7 { state.earlyCount += 1 }
        }
        if parts.month == 1, parts.day == 1 { state.newYearSeen = true }
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        state.daysActive.insert(day)
        if day == state.dayKey { state.dayCount += 1 } else { state.dayKey = day; state.dayCount = 1 }
        state.bestDay = max(state.bestDay, state.dayCount)

        let detail = [callsign, type?.uppercased()].compactMap(\.self).joined(separator: " · ")
        evaluate(totalSpots: totalSpots, celebrate: true, detail: detail.isEmpty ? nil : detail)
    }

    /// Route enrichment resolves async — countries accrue whenever we learn
    /// where a spotted flight is headed.
    func recordDestinationCountry(_ iso: String, totalSpots: Int) {
        let code = iso.uppercased()
        guard !code.isEmpty, !state.countries.contains(code) else { return }
        state.countries.insert(code)
        evaluate(totalSpots: totalSpots, celebrate: true, detail: nil)
    }

    func recordTransitCapture(callsign: String?, totalSpots: Int) {
        state.transitCaptured = true
        evaluate(totalSpots: totalSpots, celebrate: true, detail: callsign)
    }

    func recordISSOverhead(totalSpots: Int) {
        guard !state.issCaught else { return }
        state.issCaught = true
        evaluate(totalSpots: totalSpots, celebrate: true, detail: nil)
    }

    // MARK: Progress & award

    /// Current progress toward a medal, capped at its target.
    func progress(for medal: Medal, totalSpots: Int) -> Int {
        let raw: Int
        switch medal.id {
        case "first", "spots10", "spots25", "spots50", "spots100", "spots200",
             "spots350", "spots500", "spots750", "spots1000", "spots2500", "spots5000":
            raw = totalSpots
        case "superjumbo":   raw = state.superjumboSeen ? 1 : 0
        case "queen":        raw = state.queenSeen ? 1 : 0
        case "widebodies":   raw = state.widebodyTypes.count
        case "heavymetal":   raw = state.widebodyCount
        case "rotor":        raw = state.rotorSeen ? 1 : 0
        case "nightowl":     raw = state.nightCount
        case "globetrotter": raw = state.countries.count
        case "transit":      raw = state.transitCaptured ? 1 : 0
        case "starsailor":   raw = state.issCaught ? 1 : 0
        case "props":        raw = state.propSeen ? 1 : 0
        case "lightwings":   raw = state.gaCount
        case "newyear":      raw = state.newYearSeen ? 1 : 0
        case "earlybird":    raw = state.earlyCount
        case "busysky":      raw = state.bestDay
        case "ritual":       raw = state.daysActive.count
        case "triple7":      raw = state.triple7Seen ? 1 : 0
        case "dreamliner":   raw = state.dreamlinerSeen ? 1 : 0
        case "quadjet":      raw = state.quadCount
        case "typecollector":   raw = state.typesSeen.count
        case "liverycollector": raw = state.airlines.count
        case "whale":        raw = state.whaleSeen ? 1 : 0
        case "continental":  raw = state.countries.count
        case "heavycentury": raw = state.widebodyCount
        case "graveyard":    raw = state.nightCount
        default:             raw = 0
        }
        return min(raw, medal.target)
    }

    private func evaluate(totalSpots: Int, celebrate: Bool, detail: String?) {
        for medal in MedalCatalog.all where state.earned[medal.id] == nil {
            guard progress(for: medal, totalSpots: totalSpots) >= medal.target else { continue }
            state.earned[medal.id] = MedalAward(date: Date(), detail: detail)
            if celebrate { Analytics.log("Medal.earned", ["id": medal.id]) }
            if celebrate {
                pendingReveal = medal
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}

/// Tiny indirection so `recordSpot` reads cleanly above.
private enum CatalogCheck {
    static func widebody(_ t: String) -> Bool { MedalCatalog.isWidebody(t) }
}
