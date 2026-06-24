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
    // Reality check: where this plane is *observed* to be landing right now,
    // when that disagrees with (or confirms) the filed route.
    var observedArrival: String?       // IATA
    var observedArrivalCity: String?
    var routeMismatch: Bool = false

    var id: String { hex }
}

/// One hit from flight search — either a plane in the live feed ("in view") or
/// a global lookup that may be far away. Tapping it links to the track system.
struct SearchResult: Identifiable, Equatable {
    let hex: String
    var callsign: String?
    var type: String?
    var registration: String?
    var airline: String?
    var altitudeFeet: Double
    var onGround: Bool
    var distanceNm: Double?    // nil when our location or the plane's is unknown
    var azimuth: Double?
    var inView: Bool           // currently in the local feed (trackable in AR now)

    var id: String { hex }
    var title: String {
        if let c = callsign, !c.isEmpty { return c }
        if let r = registration, !r.isEmpty { return r }
        return hex.uppercased()
    }
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
    /// Planes taxiing/parked are noise for a sky app — hidden by default.
    var showGroundAircraft: Bool { didSet { persist(); controller?.applyLayerVisibility() } }
    /// Show only aircraft plausibly visible to the naked eye (near, and well
    /// above the horizon haze) instead of every distant contact in radio range.
    var nakedEyeOnly: Bool { didSet { persist(); controller?.applyAircraftVisibilityFilter() } }
    /// How far (nm) still counts as "visible" while `nakedEyeOnly` is on.
    var nakedEyeRangeNm: Double { didSet { persist(); controller?.applyAircraftVisibilityFilter() } }
    var showAirports: Bool { didSet { persist(); controller?.applyLayerVisibility() } }
    var showTrails: Bool   { didSet { persist(); controller?.applyTrailVisibility() } }
    var soundOn: Bool      { didSet { persist(); controller?.applySoundMode() } }
    /// Accessibility: locate aircraft by 3D spatial sound *and* proximity
    /// haptics — for blind / low-vision users, or anyone, to find a plane
    /// eyes-free. Turning it on also switches the spatial soundscape on.
    var hearFeelSky: Bool  { didSet { persist(); if hearFeelSky { soundOn = true }; controller?.applyAccessibility() } }

    /// Minutes added to "now" for the sky clock (time-scrub; not persisted).
    var skyTimeOffsetMin: Double = 0 { didSet { controller?.applySkyTimeNow() } }

    /// Flightradar24 API token. When set, live traffic comes from FR24 (global,
    /// satellite-backed) instead of the non-commercial airplanes.live feed.
    var fr24ApiKey: String {
        didSet {
            UserDefaults.standard.set(fr24ApiKey, forKey: SkyDefaults.fr24ApiKey)
            controller?.configureDataSource()
        }
    }

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
    /// The traffic feed has failed several polls in a row (no network?).
    var feedOffline: Bool = false
    /// Location was denied; the sky is shown from a stand-in city.
    var usingDemoLocation: Bool = false
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
        // The mirror toggle is gone — it silently flipped the whole sky
        // east↔west (sun on the wrong side, mirrored planes and airports)
        // after one accidental tap. Force any persisted value off.
        mirrorX = false
        d.set(false, forKey: SkyDefaults.mirrorX)
        // Camera AR is the default experience; only off if explicitly disabled.
        cameraPassthrough = d.object(forKey: SkyDefaults.cameraPassthrough) as? Bool ?? true
        lidarAssist = d.object(forKey: SkyDefaults.lidarAssist) as? Bool ?? true
        labelMode = LabelMode(rawValue: d.string(forKey: SkyDefaults.labelMode) ?? "") ?? .nearby
        showSun = d.object(forKey: SkyDefaults.showSun) as? Bool ?? true
        showMoon = d.object(forKey: SkyDefaults.showMoon) as? Bool ?? true
        showPlanets = d.object(forKey: SkyDefaults.showPlanets) as? Bool ?? true
        showStars = d.object(forKey: SkyDefaults.showStars) as? Bool ?? true
        showISS = d.object(forKey: SkyDefaults.showISS) as? Bool ?? true
        showAircraft = d.object(forKey: SkyDefaults.showAircraft) as? Bool ?? true
        showGroundAircraft = d.object(forKey: SkyDefaults.showGroundAircraft) as? Bool ?? false
        // On by default: show what you could actually see, not every distant blip.
        nakedEyeOnly = d.object(forKey: SkyDefaults.nakedEyeOnly) as? Bool ?? true
        let nakedRange = d.object(forKey: SkyDefaults.nakedEyeRangeNm) as? Double ?? 35
        nakedEyeRangeNm = (15...55).contains(nakedRange) ? nakedRange : 35
        showAirports = d.object(forKey: SkyDefaults.showAirports) as? Bool ?? true
        showTrails = d.object(forKey: SkyDefaults.showTrails) as? Bool ?? true
        soundOn = d.bool(forKey: SkyDefaults.soundOn)
        hearFeelSky = d.bool(forKey: SkyDefaults.hearFeelSky)
        fr24ApiKey = d.string(forKey: SkyDefaults.fr24ApiKey) ?? ""
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

    /// Flight search. In-view matches come from the live feed instantly; the
    /// global lookup reaches any aircraft via the data source.
    func searchInView(field: AircraftSearchField, query: String) -> [SearchResult] {
        controller?.localMatches(field: field, query: query) ?? []
    }
    func searchAnywhere(field: AircraftSearchField, value: String) async -> [SearchResult] {
        await controller?.globalSearch(field: field, value: value) ?? []
    }
    /// Link a search hit to the track (focus) system, and open it if it's
    /// already in our sky.
    func track(_ result: SearchResult) { controller?.trackSearchResult(result) }

    // MARK: Calibration flow (camera mode)

    enum CalibrationStep: Equatable { case idle, scanning, aligning }
    /// Active step of the guided heading calibration (not persisted).
    var calibrationStep: CalibrationStep = .idle
    /// 0…1 coverage of the 360° sweep, for the scan UI.
    var calibrationScanProgress: Double = 0
    /// While false, the passive compass auto-align is frozen — a manual lock
    /// (from calibration) holds instead. Re-enabled on a fresh session.
    var autoAlignEnabled: Bool = true
    /// When the sky was last pinned to a known reference (Sun/Moon/plane or a
    /// drag-align). Drives the alignment-confidence HUD. Not persisted.
    var lastManualAlignAt: Date?

    /// Suggest a quick re-align after returning from the background (set by the
    /// controller when a real gap may have left the alignment stale). Not persisted.
    var realignSuggested = false
    var realignDismissed = false

    // LiDAR tracking assist (spike). `lidarSupported`/`lidarActive` are set by
    // the controller; `lidarAssist` is the user toggle.
    var lidarSupported = false
    var lidarActive = false
    var lidarAssist: Bool = true { didSet { persist(); controller?.applyTrackingConfig() } }

    /// Start the guided flow: 360° sweep, then drag-to-line-up. Switches to the
    /// live camera automatically — the Sun/plane lock needs it.
    func beginCalibration() {
        if !cameraPassthrough { cameraPassthrough = true }
        calibrationScanProgress = 0
        calibrationStep = .scanning
        controller?.beginCalibrationScan()
    }
    /// Called by the controller once the sweep has covered the circle.
    func calibrationStartAligning() { calibrationStep = .aligning }
    /// Keep the manual lock the user just dialled in.
    func finishCalibration() {
        calibrationStep = .idle
        controller?.lockManualAlignment()
    }
    func cancelCalibration() {
        calibrationStep = .idle
        controller?.cancelCalibrationScan()
    }
    /// Skip the sweep and go straight to locking on the Sun/Moon/a plane.
    func skipCalibrationScan() { controller?.skipScan() }
    /// Hand heading back to the automatic compass consensus.
    func resetToAutoAlign() {
        autoAlignEnabled = true
        calibrationStep = .idle
        controller?.resumeAutoAlign()
    }

    /// Whether the Sun / Moon are above the horizon right now — set when the
    /// sweep finishes, so the lock step can offer the precise reference.
    var calibrationSunUp = false
    var calibrationMoonUp = false
    func lockToSun()  { controller?.lockToSun();  finishCalibration() }
    func lockToMoon() { controller?.lockToMoon(); finishCalibration() }

    /// Pin the sky to the selected aircraft's known bearing — the all-weather
    /// solve when no celestial body is up. Center the real plane, then lock.
    func lockToSelectedAircraft() { controller?.lockToSelectedAircraft(); finishCalibration() }

    /// Open the drag/tap-to-align step straight from the live screen (no 360°
    /// sweep) — reuses the same lock primitives as the guided flow. Needs the
    /// camera so the real Sun/Moon/plane is visible to line up against.
    func beginQuickAlign() {
        if !cameraPassthrough { cameraPassthrough = true }
        controller?.prepareQuickAlign()
        calibrationStep = .aligning
    }

    /// Seconds since the last manual alignment, or nil if never aligned this run.
    var secondsSinceAlign: TimeInterval? {
        lastManualAlignAt.map { Date().timeIntervalSince($0) }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(headingOffsetDeg, forKey: SkyDefaults.headingOffsetDeg)
        d.set(mirrorX, forKey: SkyDefaults.mirrorX)
        d.set(cameraPassthrough, forKey: SkyDefaults.cameraPassthrough)
        d.set(lidarAssist, forKey: SkyDefaults.lidarAssist)
        d.set(labelMode.rawValue, forKey: SkyDefaults.labelMode)
        d.set(showSun, forKey: SkyDefaults.showSun)
        d.set(showMoon, forKey: SkyDefaults.showMoon)
        d.set(showPlanets, forKey: SkyDefaults.showPlanets)
        d.set(showStars, forKey: SkyDefaults.showStars)
        d.set(showISS, forKey: SkyDefaults.showISS)
        d.set(showAircraft, forKey: SkyDefaults.showAircraft)
        d.set(showGroundAircraft, forKey: SkyDefaults.showGroundAircraft)
        d.set(nakedEyeOnly, forKey: SkyDefaults.nakedEyeOnly)
        d.set(nakedEyeRangeNm, forKey: SkyDefaults.nakedEyeRangeNm)
        d.set(showAirports, forKey: SkyDefaults.showAirports)
        d.set(showTrails, forKey: SkyDefaults.showTrails)
        d.set(soundOn, forKey: SkyDefaults.soundOn)
        d.set(hearFeelSky, forKey: SkyDefaults.hearFeelSky)
    }
}
