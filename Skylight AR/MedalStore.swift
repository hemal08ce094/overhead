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
        SpotterTier(name: "Observer",      threshold: 0,    finish: .bronze),
        SpotterTier(name: "Spotter",       threshold: 10,   finish: .bronze),
        SpotterTier(name: "Sky Watcher",   threshold: 25,   finish: .bronze),
        SpotterTier(name: "Sky Tracker",   threshold: 50,   finish: .steel),
        SpotterTier(name: "Plane Chaser",  threshold: 100,  finish: .steel),
        SpotterTier(name: "Navigator",     threshold: 200,  finish: .silver),
        SpotterTier(name: "Aviator",       threshold: 350,  finish: .silver),
        SpotterTier(name: "Captain",       threshold: 500,  finish: .gold),
        SpotterTier(name: "Commander",     threshold: 750,  finish: .gold),
        SpotterTier(name: "Constellation", threshold: 1000, finish: .night),
        SpotterTier(name: "Voyager",       threshold: 2500, finish: .night),
        SpotterTier(name: "Legend",        threshold: 5000, finish: .night),
    ]

    static func tier(forSpots n: Int) -> SpotterTier {
        tiers.last { n >= $0.threshold } ?? tiers[0]
    }

    static func nextTier(forSpots n: Int) -> SpotterTier? {
        tiers.first { n < $0.threshold }
    }

    static let all: [Medal] = [
        Medal(id: "first", name: "First Contact",
              requirement: "Spot your first aircraft in the sky.",
              finish: .bronze, emblem: .symbol("airplane"), caption: nil, target: 1),
        Medal(id: "spots10", name: "Spotter's Wings",
              requirement: "Spot 10 flights.",
              finish: .bronze, emblem: .count(10), caption: "FLIGHTS", target: 10),
        Medal(id: "spots25", name: "Sky Watcher",
              requirement: "Spot 25 flights.",
              finish: .bronze, emblem: .count(25), caption: "FLIGHTS", target: 25),
        Medal(id: "spots50", name: "Sky Tracker",
              requirement: "Spot 50 flights.",
              finish: .steel, emblem: .count(50), caption: "FLIGHTS", target: 50),
        Medal(id: "spots100", name: "Plane Chaser",
              requirement: "Spot 100 flights.",
              finish: .steel, emblem: .count(100), caption: "FLIGHTS", target: 100),
        Medal(id: "spots200", name: "Navigator",
              requirement: "Spot 200 flights.",
              finish: .silver, emblem: .count(200), caption: "FLIGHTS", target: 200),
        Medal(id: "spots350", name: "Aviator",
              requirement: "Spot 350 flights.",
              finish: .silver, emblem: .count(350), caption: "FLIGHTS", target: 350),
        Medal(id: "spots500", name: "Captain",
              requirement: "Spot 500 flights.",
              finish: .gold, emblem: .count(500), caption: "FLIGHTS", target: 500),
        Medal(id: "spots750", name: "Commander",
              requirement: "Spot 750 flights.",
              finish: .gold, emblem: .count(750), caption: "FLIGHTS", target: 750),
        Medal(id: "spots1000", name: "Constellation",
              requirement: "Spot 1,000 flights.",
              finish: .night, emblem: .constellation, caption: "1000", target: 1000),
        Medal(id: "spots2500", name: "Voyager",
              requirement: "Spot 2,500 flights.",
              finish: .night, emblem: .symbol("sparkles"), caption: "2500", target: 2500),
        Medal(id: "spots5000", name: "Legend",
              requirement: "Spot 5,000 flights.",
              finish: .night, emblem: .symbol("trophy.fill"), caption: "5000", target: 5000),
        Medal(id: "superjumbo", name: "Superjumbo",
              requirement: "Spot an Airbus A380 — the biggest airliner flying.",
              finish: .silver, emblem: .symbol("airplane"), caption: "A380", target: 1),
        Medal(id: "queen", name: "Queen of the Skies",
              requirement: "Spot a Boeing 747.",
              finish: .silver, emblem: .symbol("crown.fill"), caption: "747", target: 1),
        Medal(id: "widebodies", name: "Widebody Collector",
              requirement: "Spot five different widebody types.",
              finish: .gold, emblem: .symbol("airplane"), caption: "5 TYPES", target: 5),
        Medal(id: "heavymetal", name: "Heavy Metal",
              requirement: "Spot 25 widebodies.",
              finish: .gold, emblem: .count(25), caption: "HEAVIES", target: 25),
        Medal(id: "rotor", name: "Rotorhead",
              requirement: "Spot a helicopter.",
              finish: .steel, emblem: .rotor, caption: nil, target: 1),
        Medal(id: "nightowl", name: "Night Owl",
              requirement: "Spot 10 flights after midnight.",
              finish: .night, emblem: .symbol("moon.stars.fill"), caption: "AFTER 12", target: 10),
        Medal(id: "globetrotter", name: "Globetrotter",
              requirement: "Spot flights bound for 10 different countries.",
              finish: .gold, emblem: .symbol("globe"), caption: "COUNTRIES", target: 10),
        Medal(id: "transit", name: "Transit Hunter",
              requirement: "Capture a plane crossing the sun or the moon.",
              finish: .gold, emblem: .transit, caption: nil, target: 1),
        Medal(id: "starsailor", name: "Star Sailor",
              requirement: "Catch the ISS passing overhead.",
              finish: .steel, emblem: .issStreak, caption: "ISS", target: 1),
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
        if let t = type?.uppercased(), CatalogCheck.widebody(t) {
            state.widebodyTypes.insert(t)
            state.widebodyCount += 1
        }
        if MedalCatalog.isHelicopter(type: type, category: category) { state.rotorSeen = true }
        if type?.uppercased().hasPrefix("A38") == true { state.superjumboSeen = true }
        if type?.uppercased().hasPrefix("B74") == true { state.queenSeen = true }
        if Calendar.current.component(.hour, from: date) < 5 { state.nightCount += 1 }
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
        default:             raw = 0
        }
        return min(raw, medal.target)
    }

    private func evaluate(totalSpots: Int, celebrate: Bool, detail: String?) {
        for medal in MedalCatalog.all where state.earned[medal.id] == nil {
            guard progress(for: medal, totalSpots: totalSpots) >= medal.target else { continue }
            state.earned[medal.id] = MedalAward(date: Date(), detail: detail)
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
