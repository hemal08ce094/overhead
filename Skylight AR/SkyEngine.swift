//
//  SkyEngine.swift
//  Skylight AR
//
//  The bridge between SwiftUI and the AR view controller: a single observable
//  source of truth for calibration + layer visibility (persisted) plus live UI
//  state (traffic count, the selected aircraft readout, compass accuracy).
//

import SwiftUI
import Observation

/// A snapshot of the currently selected aircraft, recomputed each poll so the
/// readout tracks the plane as it moves. Lets the user cross-check one target
/// against a flight tracker — the heart of M1 calibration.
struct SelectedAircraft: Identifiable, Equatable {
    let hex: String
    var callsign: String
    var type: String?
    var altitudeFeet: Double
    var onGround: Bool
    var azimuth: Double      // degrees from true north
    var elevation: Double    // degrees above horizon
    var distanceNm: Double
    var track: Double?
    var groundSpeedKts: Double?
    // Route enrichment (M5, filled async from adsbdb).
    var airline: String?
    var origin: String?
    var originCity: String?
    var destination: String?
    var destinationCity: String?

    var id: String { hex }
}

/// A tapped airport, with observer-relative geometry for the detail sheet.
struct SelectedAirport: Identifiable, Equatable {
    let iata: String
    let icao: String
    let name: String
    let city: String
    let country: String
    let lat: Double
    let lon: Double
    var distanceNm: Double
    var azimuth: Double

    var id: String { iata }
}

@MainActor
@Observable
final class SkyEngine {

    /// How many aircraft labels to draw, to keep a busy horizon readable.
    enum LabelMode: String, CaseIterable, Identifiable {
        case all, nearby, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .nearby: return "Nearby"
            case .off: return "Off"
            }
        }
    }

    // Calibration (persisted). didSet pushes the change straight to the
    // controller for instant relayout — no waiting for the next poll.
    var headingOffsetDeg: Double { didSet { persist(); controller?.applyCalibrationNow() } }
    var mirrorX: Bool            { didSet { persist(); controller?.applyCalibrationNow() } }
    var cameraPassthrough: Bool  { didSet { persist(); controller?.applyBackground() } }
    var labelMode: LabelMode     { didSet { persist(); controller?.applyLabelMode() } }

    // Sky layer visibility (persisted).
    var showSun: Bool      { didSet { persist(); controller?.applyLayerVisibility() } }
    var showMoon: Bool     { didSet { persist(); controller?.applyLayerVisibility() } }
    var showPlanets: Bool  { didSet { persist(); controller?.applyLayerVisibility() } }
    var showStars: Bool    { didSet { persist(); controller?.applyLayerVisibility() } }
    var showISS: Bool      { didSet { persist(); controller?.applyLayerVisibility() } }
    var showAircraft: Bool { didSet { persist(); controller?.applyLayerVisibility() } }
    var showAirports: Bool { didSet { persist(); controller?.applyLayerVisibility() } }
    var showTrails: Bool   { didSet { persist(); controller?.applyTrailVisibility() } }
    var soundOn: Bool      { didSet { persist(); controller?.applySoundMode() } }

    /// Minutes added to "now" for the sky clock (time-scrub; not persisted).
    var skyTimeOffsetMin: Double = 0 { didSet { controller?.applySkyTimeNow() } }

    // Favorites & focus (callsign-based so they survive across days/sessions).
    var favorites: Set<String> {
        didSet { UserDefaults.standard.set(Array(favorites).sorted(), forKey: SkyDefaults.favorites) }
    }
    var focusedCallsign: String? { didSet { controller?.applyFocus() } }

    /// Live guidance for the focused flight: where it is, and which way to
    /// turn when it's off screen (`arrowAngle` nil while visible).
    struct FocusInfo: Equatable {
        var callsign: String
        var distanceNm: Double
        var arrowAngle: Double?   // degrees clockwise from screen-up
        var overhead: Bool        // currently in the live feed
    }
    var focusInfo: FocusInfo?

    /// Upcoming plane-crosses-Moon/Sun moment, when one is predicted.
    var transitPrediction: TransitPrediction?

    /// The sky calendar — eclipses (local), meteor showers, full moons.
    var events: [SkyEvent] = []
    private var eventsLoaded = false

    /// Heavy scan (thousands of ephemerides); runs once, off the main actor.
    func loadEventsIfNeeded(lat: Double, lon: Double) {
        guard !eventsLoaded else { return }
        eventsLoaded = true
        Task.detached(priority: .utility) {
            let events = EventsCalendar.upcoming(lat: lat, lon: lon)
            await MainActor.run { self.events = events }
        }
    }

    func isFavorite(_ callsign: String) -> Bool { favorites.contains(callsign) }
    func toggleFavorite(_ callsign: String) {
        if favorites.contains(callsign) { favorites.remove(callsign) }
        else { favorites.insert(callsign) }
        controller?.applyFocus()
    }

    // Lifetime sky stats (local, private).
    private(set) var statFlightsSpotted: Int = 0
    private(set) var statDaysUsed: Int = 0

    func recordSpot() {
        statFlightsSpotted += 1
        UserDefaults.standard.set(statFlightsSpotted, forKey: SkyDefaults.statSpots)
    }

    /// Aircraft within this range get labels in `.nearby` mode.
    var nearbyRangeNm: Double = 60

    // Live UI state, written by the controller.
    var trafficCount: Int = 0
    var selected: SelectedAircraft?
    var selectedPhoto: PlanePhoto?
    var selectedAirport: SelectedAirport?
    /// Current pinch-zoom factor (1 = no zoom), mirrored from the controller.
    var zoomFactor: Double = 1
    /// Compass heading accuracy in degrees; < 0 means unknown.
    var headingAccuracyDeg: Double = -1
    /// True once the compass has stayed poor long enough to deserve a nudge.
    var compassHintNeeded: Bool = false
    var compassHintDismissed: Bool = false
    /// Moon illuminated fraction (0…1) and waxing flag, for the UI.
    var moonIllumination: Double = 0
    var moonWaxing: Bool = true
    /// True once the ISS TLE has been fetched and the ISS is above the horizon.
    var issVisible: Bool = false

    weak var controller: ARSkyViewController?

    init() {
        let d = UserDefaults.standard
        // Direct assignment in init does not trigger didSet — safe while
        // `controller` is still nil.
        headingOffsetDeg = d.double(forKey: SkyDefaults.headingOffsetDeg)
        mirrorX = d.bool(forKey: SkyDefaults.mirrorX)
        // Camera AR is the default experience; only off if explicitly disabled.
        cameraPassthrough = d.object(forKey: SkyDefaults.cameraPassthrough) as? Bool ?? true
        labelMode = LabelMode(rawValue: d.string(forKey: SkyDefaults.labelMode) ?? "") ?? .nearby
        showSun = d.object(forKey: SkyDefaults.showSun) as? Bool ?? true
        showMoon = d.object(forKey: SkyDefaults.showMoon) as? Bool ?? true
        showPlanets = d.object(forKey: SkyDefaults.showPlanets) as? Bool ?? true
        showStars = d.object(forKey: SkyDefaults.showStars) as? Bool ?? true
        showISS = d.object(forKey: SkyDefaults.showISS) as? Bool ?? true
        showAircraft = d.object(forKey: SkyDefaults.showAircraft) as? Bool ?? true
        showAirports = d.object(forKey: SkyDefaults.showAirports) as? Bool ?? true
        showTrails = d.object(forKey: SkyDefaults.showTrails) as? Bool ?? true
        soundOn = d.bool(forKey: SkyDefaults.soundOn)
        favorites = Set(d.stringArray(forKey: SkyDefaults.favorites) ?? [])
        statFlightsSpotted = d.integer(forKey: SkyDefaults.statSpots)
        statDaysUsed = d.integer(forKey: SkyDefaults.statDays)
        // Count distinct days under the sky.
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        if d.double(forKey: SkyDefaults.lastUsedDay) != today {
            d.set(today, forKey: SkyDefaults.lastUsedDay)
            statDaysUsed += 1
            d.set(statDaysUsed, forKey: SkyDefaults.statDays)
        }
    }

    var compassQuality: CompassQuality {
        switch headingAccuracyDeg {
        case ..<0: return .unknown
        case 0..<8: return .good
        case 8..<20: return .fair
        default: return .poor
        }
    }

    enum CompassQuality { case unknown, good, fair, poor }

    func deselect() { controller?.deselect() }
    func jumpToNextISSPass() { controller?.jumpToNextISSPass() }
    func resetZoom() { controller?.resetZoom() }
    func openFocusedDetail() { controller?.selectFocusedFlight() }
    func captureShareCard() { controller?.captureShareCard() }

    private func persist() {
        let d = UserDefaults.standard
        d.set(headingOffsetDeg, forKey: SkyDefaults.headingOffsetDeg)
        d.set(mirrorX, forKey: SkyDefaults.mirrorX)
        d.set(cameraPassthrough, forKey: SkyDefaults.cameraPassthrough)
        d.set(labelMode.rawValue, forKey: SkyDefaults.labelMode)
        d.set(showSun, forKey: SkyDefaults.showSun)
        d.set(showMoon, forKey: SkyDefaults.showMoon)
        d.set(showPlanets, forKey: SkyDefaults.showPlanets)
        d.set(showStars, forKey: SkyDefaults.showStars)
        d.set(showISS, forKey: SkyDefaults.showISS)
        d.set(showAircraft, forKey: SkyDefaults.showAircraft)
        d.set(showAirports, forKey: SkyDefaults.showAirports)
        d.set(showTrails, forKey: SkyDefaults.showTrails)
        d.set(soundOn, forKey: SkyDefaults.soundOn)
    }
}
