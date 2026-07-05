//
//  SkylightAR.swift
//  Skylight AR
//
//  The engine seed: data layer + geo/celestial math + the AR view controller.
//
//  Key insight: everything we draw is miles away, so we only need *direction*,
//  not 3D position. For each object we compute azimuth + elevation from the
//  observer and place it on a large sphere around the camera. The session uses
//  ARWorldTrackingConfiguration.worldAlignment = .gravityAndHeading, so the scene
//  frame is already aligned to the world: -Z = true north, +X = east, +Y = up.
//  No manual compass/attitude math needed.
//

import Foundation
import SceneKit
import ARKit
import CoreLocation
import AVFoundation
import SatelliteKit
import simd
import WidgetKit

// MARK: - Model

/// A single aircraft fix, normalized from whatever provider fed it in.
struct Aircraft: Identifiable, Sendable, Equatable {
    let hex: String
    var callsign: String?      // "flight", trimmed
    var lat: Double
    var lon: Double
    var altGeom: Double?       // geometric altitude, feet (preferred)
    var altBaro: Double?       // barometric altitude, feet (nil when on ground)
    var onGround: Bool
    var track: Double?         // ground track, degrees from north
    var groundSpeedKts: Double?
    var verticalRateFpm: Double?  // climb/descent, ft/min (+ up); for altitude dead-reckoning
    var positionAgeSec: Double?   // feed's "seen_pos": seconds since this fix
    var category: String?      // ADS-B emitter category, e.g. "A3"
    var type: String?          // ICAO type designator ("t"), e.g. "B738"
    var registration: String? // tail number ("r"), e.g. "N12345"
    var squawk: String?        // transponder code, e.g. "7700"

    var id: String { hex }

    /// Prefer geometric altitude; fall back to barometric. Feet.
    var altitudeFeet: Double { altGeom ?? altBaro ?? 0 }
    var altitudeMeters: Double { altitudeFeet * 0.3048 }
}

// MARK: - Data source (swappable provider)

/// Abstraction over the traffic provider so the source can be swapped without
/// touching the renderer. The public airplanes.live feed is non-commercial; for
/// a paid app, drop in a commercial `DataSource` (RapidAPI/FlightAware) or proxy.
protocol DataSource: Sendable {
    /// Aircraft within `radiusNm` nautical miles of the point. Honor the feed's
    /// ~1 req/sec rate limit at the call site.
    func aircraft(lat: Double, lon: Double, radiusNm: Int) async throws -> [Aircraft]

    /// Global lookup of any aircraft matching `value` on `field`, regardless of
    /// distance. Default returns nothing so a provider without global search
    /// stays a drop-in `DataSource`.
    func search(field: AircraftSearchField, value: String) async throws -> [Aircraft]
}

extension DataSource {
    func search(field: AircraftSearchField, value: String) async throws -> [Aircraft] { [] }
    /// Residual pipeline lag beyond each fix's own reported age, in seconds —
    /// how far forward to dead-reckon to land on "now". Tuned per source; the
    /// near-real-time default fits a ~1 Hz feed like airplanes.live.
    var feedLatencySec: Double { 1.5 }
}

/// The parameters a flight can be searched by, mapped to airplanes.live's
/// global endpoints.
enum AircraftSearchField: String, CaseIterable, Identifiable, Sendable {
    case callsign, registration, type, squawk
    var id: String { rawValue }

    var title: String {
        switch self {
        case .callsign:     return "Flight"
        case .registration: return "Tail"
        case .type:         return "Type"
        case .squawk:       return "Squawk"
        }
    }
    /// Endpoint path segment on the airplanes.live v2 API.
    var endpoint: String {
        switch self {
        case .callsign:     return "callsign"
        case .registration: return "reg"
        case .type:         return "type"
        case .squawk:       return "squawk"
        }
    }
    var placeholder: String {
        switch self {
        case .callsign:     return "EK226, BA45, UAL123"
        case .registration: return "N12345, G-XWBA"
        case .type:         return "B738, A320"
        case .squawk:       return "7700, 1200"
        }
    }
    /// How the feed wants the query normalized. Crucially, aircraft broadcast
    /// *ICAO* callsigns (Emirates = UAE226), but people type the *IATA* flight
    /// number (EK226) — so translate the airline code for callsign searches.
    func normalized(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch self {
        case .callsign:     return AirlineCodes.toICAOCallsign(t)
        case .registration: return t.replacingOccurrences(of: " ", with: "")
        default:            return t
        }
    }
}

/// IATA→ICAO airline code translation so "EK226" finds the broadcast "UAE226".
enum AirlineCodes {
    /// Two-letter IATA → three-letter ICAO for the busiest carriers worldwide.
    static let iataToICAO: [String: String] = [
        "AA":"AAL","AC":"ACA","AF":"AFR","AI":"AIC","AM":"AMX","AS":"ASA","AT":"RAM",
        "AV":"AVA","AY":"FIN","AZ":"ITY","B6":"JBU","BA":"BAW","BR":"EVA","CA":"CCA",
        "CI":"CAL","CM":"CMP","CX":"CPA","CZ":"CSN","DL":"DAL","DY":"NAX","EI":"EIN",
        "EK":"UAE","ET":"ETH","EW":"EWG","EY":"ETD","F9":"FFT","FR":"RYR","FZ":"FDB",
        "GA":"GIA","GF":"GFA","HA":"HAL","HU":"CHH","IB":"IBE","JL":"JAL","KE":"KAL",
        "KL":"KLM","KU":"KAC","LA":"LAN","LH":"DLH","LO":"LOT","LX":"SWR","LY":"ELY",
        "MH":"MAS","MS":"MSR","MU":"CES","NH":"ANA","NK":"NKS","NZ":"ANZ","OS":"AUA",
        "OZ":"AAR","PR":"PAL","PS":"AUI","QF":"QFA","QR":"QTR","RJ":"RJA","RO":"ROT",
        "SA":"SAA","SK":"SAS","SN":"BEL","SQ":"SIA","SU":"AFL","SV":"SVA","TG":"THA",
        "TK":"THY","TP":"TAP","U2":"EZY","UA":"UAL","UX":"AEA","VA":"VOZ","VN":"HVN",
        "VS":"VIR","VY":"VLG","W6":"WZZ","WN":"SWA","WS":"WJA","WY":"OMA","ME":"MEA",
        "6E":"IGO","SG":"SEJ","UK":"VTI","A3":"AEE","DE":"CFG","TO":"TVF","HV":"TRA",
    ]

    /// Translate a typed flight number to the broadcast ICAO callsign.
    /// "EK 0226" → "UAE226"; a 3-letter prefix is assumed already ICAO.
    static func toICAOCallsign(_ raw: String) -> String {
        let s = raw.replacingOccurrences(of: " ", with: "")
        // IATA codes can contain digits (B6, 6E, U2, W6, F9, A3), so match the
        // two-character prefix against the table directly — but only when a
        // flight number follows, so ICAO callsigns like "UAL123" pass through.
        if s.count > 2, let icao = iataToICAO[s.prefix(2).uppercased()],
           s[s.index(s.startIndex, offsetBy: 2)].isNumber {
            var rest = String(s.dropFirst(2))
            while rest.first == "0" { rest.removeFirst() }   // ADS-B strips leading zeros
            return icao + rest
        }
        let letters = String(s.prefix { $0.isLetter })
        var rest = String(s.dropFirst(letters.count))
        while rest.first == "0" { rest.removeFirst() }
        return letters + rest
    }
}

/// airplanes.live point endpoint — ADSBExchange v2 response shape.
struct ADSBClient: DataSource {
    var baseURL = "https://api.airplanes.live/v2"
    var session: URLSession = .shared

    func aircraft(lat: Double, lon: Double, radiusNm: Int) async throws -> [Aircraft] {
        let r = min(max(radiusNm, 1), 250)   // feed caps radius at 250 nm
        guard let url = URL(string: "\(baseURL)/point/\(lat)/\(lon)/\(r)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, _) = try await session.data(for: request)
        let decoded = try JSONDecoder().decode(ADSBResponse.self, from: data)
        return decoded.records.compactMap(Aircraft.init(adsb:))
    }

    func search(field: AircraftSearchField, value: String) async throws -> [Aircraft] {
        let query = field.normalized(value)
        guard !query.isEmpty,
              let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/\(field.endpoint)/\(escaped)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let (data, _) = try await session.data(for: request)
        let decoded = try JSONDecoder().decode(ADSBResponse.self, from: data)
        return decoded.records.compactMap(Aircraft.init(adsb:))
    }
}

// MARK: - ADSBExchange v2 decoding

/// Raw response envelope. The readsb schema is shared by airplanes.live (`ac`)
/// and dump1090-fa (`aircraft`), so one decoder covers both — mirroring the
/// reference project's `json.aircraft ?? json.ac` normalizer.
private struct ADSBResponse: Decodable {
    let ac: [ADSBAircraft]?
    let aircraft: [ADSBAircraft]?
    var records: [ADSBAircraft] { ac ?? aircraft ?? [] }
}

private struct ADSBAircraft: Decodable {
    let hex: String
    let flight: String?
    let lat: Double?
    let lon: Double?
    let alt_baro: AltBaro?
    let alt_geom: Double?
    let track: Double?
    let gs: Double?
    let geom_rate: Double?
    let baro_rate: Double?
    let seen_pos: Double?
    let category: String?
    let t: String?
    let r: String?
    let squawk: String?
}

/// `alt_baro` is either a number (feet) or the string `"ground"`.
private enum AltBaro: Decodable {
    case feet(Double)
    case ground

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            self = .feet(d)
        } else if let s = try? c.decode(String.self), s.lowercased() == "ground" {
            self = .ground
        } else {
            self = .ground
        }
    }
}

private extension Aircraft {
    /// Map a decoded record to the normalized model; drop fixes without a position.
    init?(adsb a: ADSBAircraft) {
        guard let lat = a.lat, let lon = a.lon else { return nil }
        self.hex = a.hex
        self.callsign = a.flight?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        self.lat = lat
        self.lon = lon
        self.altGeom = a.alt_geom
        switch a.alt_baro {
        case .feet(let f): self.altBaro = f;  self.onGround = false
        case .ground:      self.altBaro = nil; self.onGround = true
        case .none:        self.altBaro = nil; self.onGround = false
        }
        self.track = a.track
        self.groundSpeedKts = a.gs
        self.verticalRateFpm = a.geom_rate ?? a.baro_rate   // prefer geometric rate
        self.positionAgeSec = a.seen_pos
        self.category = a.category
        self.type = a.t
        self.registration = a.r?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        self.squawk = a.squawk?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Geo / celestial math

/// All geometry from observer + target geodetic coordinates to a point on the
/// AR sky sphere. Pure and `nonisolated` so it can run off the main actor.
enum SkyMath {
    static let a = 6_378_137.0                    // WGS84 semi-major axis (m)
    static let f = 1.0 / 298.257_223_563          // WGS84 flattening
    static let e2 = f * (2 - f)                    // first eccentricity squared

    /// Geodetic (deg, deg, m) -> Earth-Centered Earth-Fixed (m).
    nonisolated static func ecef(latDeg: Double, lonDeg: Double, altM: Double) -> SIMD3<Double> {
        let lat = latDeg * .pi / 180, lon = lonDeg * .pi / 180
        let sinLat = sin(lat), cosLat = cos(lat)
        let n = a / (1 - e2 * sinLat * sinLat).squareRoot()
        let x = (n + altM) * cosLat * cos(lon)
        let y = (n + altM) * cosLat * sin(lon)
        let z = (n * (1 - e2) + altM) * sinLat
        return SIMD3(x, y, z)
    }

    /// Local East-North-Up of `target` relative to the observer geodetic origin.
    nonisolated static func enu(targetECEF: SIMD3<Double>,
                                originLatDeg: Double, originLonDeg: Double,
                                originECEF: SIMD3<Double>) -> SIMD3<Double> {
        let lat = originLatDeg * .pi / 180, lon = originLonDeg * .pi / 180
        let sinLat = sin(lat), cosLat = cos(lat)
        let sinLon = sin(lon), cosLon = cos(lon)
        let d = targetECEF - originECEF
        let east  = -sinLon * d.x + cosLon * d.y
        let north = -sinLat * cosLon * d.x - sinLat * sinLon * d.y + cosLat * d.z
        let up    =  cosLat * cosLon * d.x + cosLat * sinLon * d.y + sinLat * d.z
        return SIMD3(east, north, up)
    }

    /// Azimuth (deg from north, clockwise), elevation (deg), range (m).
    nonisolated static func azElRange(observerLat: Double, observerLon: Double, observerAltM: Double,
                                      targetLat: Double, targetLon: Double, targetAltM: Double)
        -> (azimuth: Double, elevation: Double, range: Double) {
        let origin = ecef(latDeg: observerLat, lonDeg: observerLon, altM: observerAltM)
        let target = ecef(latDeg: targetLat, lonDeg: targetLon, altM: targetAltM)
        let local = enu(targetECEF: target, originLatDeg: observerLat, originLonDeg: observerLon, originECEF: origin)
        let range = simd_length(local)
        guard range > 0 else { return (0, 0, 0) }
        var az = atan2(local.x, local.y) * 180 / .pi   // x=east, y=north
        if az < 0 { az += 360 }
        let el = asin(local.z / range) * 180 / .pi
        return (az, el, range)
    }

    /// Atmospheric refraction (Saemundsson/Bennett): the air lifts the image
    /// of anything near the horizon by up to ~0.5°. Applied at render time so
    /// drawn objects match the *visible* sky, not the geometric one.
    nonisolated static func refractedElevation(_ elevationDeg: Double) -> Double {
        guard elevationDeg > -1.5, elevationDeg < 89 else { return elevationDeg }
        let arcmin = 1.02 / tan((elevationDeg + 10.3 / (elevationDeg + 5.11)) * .pi / 180)
        return elevationDeg + arcmin / 60
    }

    /// Place an object on the sky sphere given its azimuth/elevation.
    /// Convention (matches the brief): position = (R·cosE·sinA, R·sinE, −R·cosE·cosA),
    /// where A is azimuth from north and E is elevation. `headingOffsetDeg` and
    /// `mirrorX` are the magnetometer-bias calibration knobs.
    nonisolated static func scenePosition(azimuthDeg: Double, elevationDeg: Double,
                                          radius: Double,
                                          headingOffsetDeg: Double = 0,
                                          mirrorX: Bool = false) -> SCNVector3 {
        var azDeg = azimuthDeg + headingOffsetDeg
        if mirrorX { azDeg = -azDeg }
        let a = azDeg * .pi / 180, e = refractedElevation(elevationDeg) * .pi / 180
        let cosE = cos(e)
        let x = radius * cosE * sin(a)
        let y = radius * sin(e)
        let z = -radius * cosE * cos(a)
        return SCNVector3(Float(x), Float(y), Float(z))
    }

    /// Astronomical Julian Day for a date.
    nonisolated static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400.0 + 2_440_587.5
    }

    /// Equatorial (J2000 RA/Dec, degrees) -> horizontal (azimuth from north
    /// clockwise, elevation), for an observer at the given time. Fast closed
    /// form (no precession) — plenty accurate for plotting stars.
    nonisolated static func equatorialToHorizontal(raDeg: Double, decDeg: Double,
                                                   latDeg: Double, lonDeg: Double,
                                                   date: Date) -> (azimuth: Double, elevation: Double) {
        let d = julianDay(date) - 2_451_545.0
        let gmst = (280.460_618_37 + 360.985_647_366_29 * d).truncatingRemainder(dividingBy: 360)
        let lst = (gmst + lonDeg).truncatingRemainder(dividingBy: 360)
        let haDeg = (lst - raDeg).truncatingRemainder(dividingBy: 360)
        let ha = haDeg * .pi / 180, dec = decDeg * .pi / 180, lat = latDeg * .pi / 180
        let sinAlt = sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(ha)
        let alt = asin(max(-1, min(1, sinAlt)))
        let cosAz = (sin(dec) - sin(lat) * sinAlt) / (cos(lat) * cos(alt))
        var az = acos(max(-1, min(1, cosAz)))
        if sin(ha) > 0 { az = 2 * .pi - az }
        return (az * 180 / .pi, alt * 180 / .pi)
    }
}

// MARK: - Glyph category (first-pass mapping from ADS-B emitter category)

/// Coarse shape/scale class derived from the ADS-B emitter category. M5 replaces
/// the placeholder glyph per category (widebodies larger, spinning rotors, etc.).
enum GlyphCategory: String {
    case light, small, large, highVortex, heavy, highPerformance
    case rotorcraft, glider, lighterThanAir, ultralight, uav, space, surface, unknown

    static func from(_ category: String?) -> GlyphCategory {
        switch category?.uppercased() {
        case "A1": return .light
        case "A2": return .small
        case "A3": return .large
        case "A4": return .highVortex
        case "A5": return .heavy
        case "A6": return .highPerformance
        case "A7": return .rotorcraft
        case "B1": return .glider
        case "B2": return .lighterThanAir
        case "B4": return .ultralight
        case "B6": return .uav
        case "B7": return .space
        case "C0", "C1", "C2", "C3", "C4", "C5", "C6", "C7": return .surface
        default:   return .unknown
        }
    }

    /// Relative glyph scale; widebodies read larger than light GA.
    var scale: CGFloat {
        switch self {
        case .heavy, .highVortex: return 1.6
        case .large:              return 1.3
        case .highPerformance:    return 1.1
        case .small:              return 1.0
        case .light, .ultralight, .glider: return 0.8
        case .rotorcraft:         return 0.9
        case .lighterThanAir:     return 1.4
        default:                  return 1.0
        }
    }
}

// MARK: - Calibration keys (persisted by SkyEngine via UserDefaults)

enum SkyDefaults {
    static let headingOffsetDeg  = "headingOffsetDeg"   // Double, -20...20
    static let mirrorX           = "mirrorX"            // Bool
    static let cameraPassthrough = "cameraPassthrough"  // Bool; true = live camera AR, false = dark low-power
    static let labelMode         = "labelMode"          // String (SkyEngine.LabelMode)
    static let showSun           = "showSun"            // Bool
    static let showMoon          = "showMoon"           // Bool
    static let showPlanets       = "showPlanets"        // Bool
    static let showStars         = "showStars"          // Bool
    static let showISS           = "showISS"            // Bool
    static let showAircraft      = "showAircraft"       // Bool
    static let showGroundAircraft = "showGroundAircraft" // Bool
    static let nakedEyeOnly       = "nakedEyeOnly"       // Bool
    static let nakedEyeRangeNm    = "nakedEyeRangeNm"    // Double
    static let showAirports      = "showAirports"       // Bool
    static let showTrails        = "showTrails"         // Bool
    static let soundOn           = "soundOn"            // Bool
    static let hearFeelSky       = "hearFeelSky"        // Bool
    static let nightVision       = "nightVision"        // Bool
    static let issAlerts         = "issAlerts"          // Bool
    static let fr24ApiKey        = "fr24ApiKey"         // String
    static let lastLat           = "lastLat"            // Double (for Siri)
    static let lastLon           = "lastLon"            // Double
    static let favorites         = "favoriteCallsigns"  // [String]
    static let statSpots         = "statFlightsSpotted" // Int
    static let statDays          = "statDaysUsed"       // Int
    static let lastUsedDay       = "lastUsedDay"        // TimeInterval
    static let issTLELines       = "issTLELines"        // [String] (3 TLE lines)
    static let issTLEDate        = "issTLEDate"         // Date (when fetched)
    static let lidarAssist       = "lidarAssist"        // Bool (LiDAR tracking assist)
}

// MARK: - Airport catalog (bundled majors)

struct Airport: Decodable, Sendable, Equatable {
    let iata: String
    let icao: String
    let name: String
    let city: String
    let country: String
    let lat: Double
    let lon: Double
}

final class AirportCatalog {
    static let shared = AirportCatalog()
    let airports: [Airport]

    private init() {
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Airport].self, from: data) else {
            airports = []
            return
        }
        airports = decoded
    }
}

// MARK: - AR view controller

/// Hosts the AR session, polls the data source at 1 Hz, and maintains one
/// billboarded glyph+label node per aircraft `hex`. Dark sky in M0/M1; the
/// camera passthrough arrives in M2 by clearing `scene.background`.
final class ARSkyViewController: UIViewController {

    // Tunables
    private let sphereRadius: Double = 1000     // meters; any large value works
    private var pollInterval: Duration = .seconds(1)
    private let staleAfter: TimeInterval = 15   // drop aircraft not seen for this long
    private let searchRadiusNm = 80
    // Pipeline lag is now per-source: see `DataSource.feedLatencySec`.
    /// Cap on how far ahead a stalled fix may be dead-reckoned (s).
    private let maxExtrapolationSec: Double = 20
    /// Below this elevation, an aircraft is lost to horizon haze/buildings and
    /// is treated as not naked-eye visible.
    private static let nakedEyeMinElevationDeg: Double = 3

    // Dependencies
    var dataSource: DataSource = ADSBClient()
    weak var engine: SkyEngine?

    // AR + location
    private let sceneView = ARSCNView(frame: .zero)
    private let locationManager = CLLocationManager()
    private var observerLocation: CLLocation?

    /// All sky content lives under this node. The AR session runs with plain
    /// `.gravity` alignment (a `.gravityAndHeading` session hard-fails with
    /// ARKit error 102 whenever the compass can't produce a valid heading —
    /// seen repeatedly on device), and this node is rotated to true north
    /// manually from CLHeading, refining as compass accuracy improves.
    private let worldNode = SCNNode()
    /// Compass accuracy (degrees) of the currently applied north alignment.
    private var appliedNorthAccuracy: Double = .infinity

    // Pinch zoom — digital, by scaling the AR view's layer. Feed and overlay
    // magnify together and ARKit is never touched: adjusting the capture
    // device's videoZoomFactor mid-session invalidates SLAM's calibrated
    // intrinsics and aborts inside AppleCV3D (seen on device, iOS 27.0).
    private var pinchStartZoom: CGFloat = 1
    private var zoomFactor: CGFloat = 1 { didSet { engine?.zoomFactor = Double(zoomFactor) } }

    // State
    private var nodes: [String: AircraftNode] = [:]
    private var lastSeen: [String: Date] = [:]
    private var lastFix: [String: Fix] = [:]
    /// Per-aircraft dead-reckoning baseline, advanced every display frame so the
    /// marker glides continuously between 1 Hz fixes instead of stepping.
    private var anchors: [String: Anchor] = [:]
    private var displayLink: CADisplayLink?
    private var selectedHex: String?
    private var pollTask: Task<Void, Never>?
    private var airportNodes: [String: AirportNode] = [:]
    private var spottedThisSession: Set<String> = []
    private var poorCompassSince: Date?
    // Home/Lock-Screen glance: last pushed signature + when, so the widget is
    // reloaded only when the visible content actually changes and never faster
    // than WidgetKit wants (a 1 Hz reload would just be throttled away).
    private var lastGlanceSignature: String?
    private var lastGlanceReload = Date.distantPast
    // Guided-calibration sweep state.
    private var scanStart: Date?
    private var calibrationSamples: [(offset: Double, weight: Double)] = []
    private var scanBuckets: Set<Int> = []
    /// Rolling window of recent passive north estimates (deg offset =
    /// trueHeading − cameraYaw). Locking and re-locking run off this consensus
    /// rather than a single noisy CLHeading, so one bad reading can't strand the
    /// sky and a genuine drift can still heal.
    private var northSamples: [(offset: Double, weight: Double, t: Date)] = []
    /// When a large but self-consistent heading error first appeared — used to
    /// tell a real drift (persistent) from a magnetic spike (momentary).
    private var driftSince: Date?
    /// Alignment state as it was before the guided flow started, so a cancel
    /// can put everything back instead of leaving the trim wiped and the
    /// compass frozen mid-sweep.
    var preCalibration: (offsetDeg: Double, autoAlign: Bool, worldY: Float)?
    private let flightActivity = FlightActivityController()
    private let skyAudio = SkyAudioEngine()

    // Sky layer + trails
    private var sky: SkyScene?
    private let routes = RouteEnricher()
    private let photos = PlanePhotoFetcher()
    private var trails: [String: [SCNVector3]] = [:]
    private var trailNodes: [String: SCNNode] = [:]
    private let maxTrail = 90      // one fix per second → ~90 s of path

    /// The most recent geometry for an aircraft, kept so calibration changes can
    /// re-place it instantly and the selection readout can refresh between fixes.
    private struct Fix { var az: Double; var el: Double; var range: Double; var aircraft: Aircraft }

    /// A geodetic baseline plus the wall-clock instant it was actually true,
    /// so any later frame can project it forward along the ground track.
    private struct Anchor {
        var lat: Double; var lon: Double; var altM: Double
        var track: Double?; var gsKts: Double?
        var vsFpm: Double?            // vertical rate, ft/min (+ up), for altitude dead-reckoning
        var observedAt: Date
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpScene()
        setUpLocation()
        setUpGestures()
        observeAppLifecycle()
        // Focus doesn't survive launches; clear any Live Activity left behind.
        flightActivity.end()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Hold the screen awake — you're pointing at the sky, not touching the
        // phone, so the auto-lock dimming/sleep would interrupt tracking.
        UIApplication.shared.isIdleTimerDisabled = true
        startSession(reset: true)
        applyBackground()      // black background over the live session in dark mode
        startPolling()
        loadOrRefreshISSTLE()
        applyNightVision()
        scheduleISSPassAlertsIfStale()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        syncHeadingOrientation()   // the window (and its orientation) exists now
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        pauseEverything()
    }

    // MARK: Setup

    private func setUpScene() {
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.scene = SCNScene()
        sceneView.automaticallyUpdatesLighting = true
        sceneView.rendersContinuously = true
        sceneView.antialiasingMode = .multisampling4X
        view.addSubview(sceneView)
        sceneView.scene.rootNode.addChildNode(darkDomeNode)
        sceneView.scene.rootNode.addChildNode(horizonGlowNode)
        sceneView.scene.rootNode.addChildNode(dimDomeNode)
        applyBackground()
        sceneView.scene.rootNode.addChildNode(worldNode)
        sky = SkyScene(root: worldNode, engine: engine, radius: sphereRadius)
        routes.onResolved = { [weak self] callsign in self?.routeResolved(callsign) }
        photos.onResolved = { [weak self] hex in
            guard let self, hex == self.selectedHex else { return }
            self.engine?.selectedPhoto = self.photos.cachedPhoto(hex)
        }
    }

    private func setUpLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.headingFilter = 1
        locationManager.requestWhenInUseAuthorization()
    }

    /// Heading samples are referenced to the top edge of the device; keep that
    /// reference glued to the UI orientation, or the compass fusion snaps the
    /// whole sky ~90° off in landscape.
    private func syncHeadingOrientation() {
        switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeLeft: locationManager.headingOrientation = .landscapeRight
        case .landscapeRight: locationManager.headingOrientation = .landscapeLeft
        case .portraitUpsideDown: locationManager.headingOrientation = .portraitUpsideDown
        default: locationManager.headingOrientation = .portrait
        }
    }

    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in self.syncHeadingOrientation() }
    }

    private func setUpGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        sceneView.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        sceneView.addGestureRecognizer(pinch)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleAlignPan(_:)))
        pan.maximumNumberOfTouches = 1
        sceneView.addGestureRecognizer(pan)   // only acts during the aligning step
    }

    // MARK: Zoom

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began: pinchStartZoom = zoomFactor
        case .changed: setZoom(pinchStartZoom * gesture.scale)
        default: break
        }
    }

    func setZoom(_ requested: CGFloat) {
        let zoom = max(1, min(requested, 4))
        zoomFactor = zoom
        sceneView.transform = zoom > 1.001 ? CGAffineTransform(scaleX: zoom, y: zoom) : .identity
    }

    func resetZoom() { setZoom(1) }

    private func observeAppLifecycle() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appDidBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        // Resume on did-become-active, not will-enter-foreground: while the lock
        // screen still covers the app the capture daemon counts us as background
        // and silently refuses to start the camera — running the AR session that
        // early leaves a permanently frozen feed (observed on iOS 27.0).
        nc.addObserver(self, selector: #selector(appDidBecomeActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// Live camera AR, or the dark sky. ARKit world tracking runs in BOTH modes
    /// — it gives a smooth render loop and stable, drift-free pointing — and
    /// "dark sky" hides the live feed behind the opaque night dome. Two dead
    /// ends live in git history, do not revisit them: pausing the session for
    /// dark mode leaves the render loop without a driver (frozen, flickering
    /// sky; yaw re-references on every switch), and overwriting
    /// scene.background with black permanently loses ARKit's feed provider on
    /// iOS 26/27 (nil doesn't restore it) plus drops the per-frame clear, so
    /// stale frames burn in as a ghost second sky.
    func applyBackground() {
        let wantCamera = engine?.cameraPassthrough ?? true
        let cameraOK = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let showCamera = wantCamera && cameraOK
        darkDomeNode.isHidden = showCamera
        horizonGlowNode.isHidden = showCamera  // the real sky has its own horizon
        dimDomeNode.isHidden = !showCamera     // scrim only over the live camera
        guard ARWorldTrackingConfiguration.isSupported else {
            // Simulator: no session runs and SceneKit auto-frames the scene
            // from outside — hide the near-field night shell (dome + horizon
            // glow) so it doesn't float in view, and paint the backdrop flat.
            darkDomeNode.isHidden = true
            horizonGlowNode.isHidden = true
            sceneView.scene.background.contents = UIColor(red: 0.010, green: 0.012,
                                                          blue: 0.045, alpha: 1)
            return
        }
        // The scene background stays ARKit's live-feed provider, ALWAYS.
        // Overwriting it (with black, then nil to undo) permanently loses the
        // feed on iOS 26/27 — and a dead background also drops the per-frame
        // clear, so stale frames burn in as a ghost "second sky". Dark mode
        // is simply the opaque night dome (renderingOrder -100) drawn over
        // the feed; toggling modes only ever flips node visibility above.
        // The 1000 m sky dome needs a far clip well past ARKit's default.
        if let camera = sceneView.pointOfView?.camera { camera.zNear = 0.1; camera.zFar = 1500 }
    }

    /// Soft indigo bloom that sits exactly on the horizon in dark-sky mode —
    /// night with a residual glow at the skyline, not a void. Drawn on a
    /// capless cylinder around the observer (a textured sphere shows bullseye
    /// artifacts at its poles), so the band rings the real horizon in 3D.
    private static let horizonGlowTexture: UIImage = {
        let h = 256
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: h))
        return renderer.image { ctx in
            let glow = UIColor(red: 0.16, green: 0.19, blue: 0.38, alpha: 1)
            let stops: [(CGFloat, UIColor)] = [
                (0.00, glow.withAlphaComponent(0)),
                (0.42, glow.withAlphaComponent(0.30)),
                (0.50, glow.withAlphaComponent(0.55)),   // the horizon line
                (0.60, glow.withAlphaComponent(0.18)),
                (1.00, glow.withAlphaComponent(0)),
            ]
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: stops.map(\.1.cgColor) as CFArray,
                                        locations: stops.map(\.0)) else { return }
            ctx.cgContext.drawLinearGradient(grad, start: .zero,
                                             end: CGPoint(x: 0, y: h), options: [])
        }
    }()

    private lazy var horizonGlowNode: SCNNode = {
        let tube = SCNCylinder(radius: 46, height: 22)
        let side = SCNMaterial()
        side.lightingModel = .constant
        side.diffuse.contents = Self.horizonGlowTexture
        side.isDoubleSided = true
        side.blendMode = .add
        side.writesToDepthBuffer = false
        side.readsFromDepthBuffer = false
        let clear = SCNMaterial()
        clear.transparency = 0
        tube.materials = [side, clear, clear]      // no caps
        let node = SCNNode(geometry: tube)
        node.renderingOrder = -95                  // over the dome, under content
        return node
    }()

    /// Inward-facing night sphere between the camera and the sky content —
    /// draws over the camera feed but never occludes content (no depth I/O).
    private lazy var darkDomeNode: SCNNode = {
        let sphere = SCNSphere(radius: 50)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        // Not pure black: the faintest indigo keeps depth in the night.
        mat.diffuse.contents = UIColor(red: 0.010, green: 0.012, blue: 0.045, alpha: 1)
        mat.cullMode = .front                      // render the inside faces
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        sphere.materials = [mat]
        let node = SCNNode(geometry: sphere)
        node.renderingOrder = -100                 // before everything else
        return node
    }()

    /// Camera-mode scrim: a *semi-transparent* black dome between the camera
    /// feed and the sky content. A bright daytime sky overpowers the plotted
    /// planes; this dims the feed (drawn first) while the glyphs — rendered
    /// after it — stay full brightness, so the planes pop instead of washing
    /// out. Only shown in camera mode (the dark dome handles dark-sky mode).
    private lazy var dimDomeNode: SCNNode = {
        let sphere = SCNSphere(radius: 49)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor(white: 0, alpha: 0.50)
        mat.cullMode = .front
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        sphere.materials = [mat]
        let node = SCNNode(geometry: sphere)
        node.renderingOrder = -90                  // after the feed, before content
        return node
    }()

    // MARK: AR session

    /// Run (or resume) the AR session. `reset: true` starts tracking from
    /// scratch and re-estimates north; plain resumes keep the existing world
    /// frame so the sky doesn't swing on every unlock or app switch.
    private func startSession(reset: Bool = false) {
        guard ARWorldTrackingConfiguration.isSupported else {
            // Simulator / unsupported device: keep the dark scene, no crash.
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        // Spike: LiDAR-assisted tracking. On Pro models the depth mesh keeps world
        // tracking locked when the camera frame is featureless — a blank or night
        // sky, the worst case for visual-inertial tracking and the most likely time
        // the overlay would swim. Nothing is rendered from the mesh; it only
        // stabilises the pose. A no-op on non-LiDAR devices (falls back to today's
        // behaviour), and switchable for A/B via Settings → heading.
        let lidarOK = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        engine?.lidarSupported = lidarOK
        if lidarOK, engine?.lidarAssist ?? true {
            config.sceneReconstruction = .mesh
            engine?.lidarActive = true
        } else {
            engine?.lidarActive = false
        }
        // Don't trust the default video format: iOS 27.0 ships a 10 fps default
        // ("frame rate set to 10.0 by user defaults") that makes the feed feel
        // frozen. Pin the first ≥30 fps format (Apple lists best-first).
        if let smooth = ARWorldTrackingConfiguration.supportedVideoFormats
            .first(where: { $0.framesPerSecond >= 30 }) {
            config.videoFormat = smooth
        }
        sceneView.session.run(config, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
        if reset {
            // The scene frame was reset; realign to north from a fresh consensus.
            appliedNorthAccuracy = .infinity
            northSamples.removeAll(); driftSince = nil
            worldNode.eulerAngles.y = 0
        }
    }

    /// Re-run the session so a tracking-config change (e.g. the LiDAR assist
    /// toggle) takes effect immediately.
    func applyTrackingConfig() { if viewIfLoaded?.window != nil { startSession() } }

    // MARK: Night vision

    /// Deep-red rendering that spares the eye's dark adaptation. Two layers:
    /// a color-grading LUT collapses the SceneKit render (sky, planes, the
    /// camera feed) to red luminance, and a multiply overlay on the window
    /// reddens every piece of SwiftUI chrome — sheets and covers included.
    @MainActor
    enum NightVision {
        private static var overlay: UIView?

        /// 32-cube LUT as SceneKit's horizontal-strip format: every color
        /// becomes its luminance on the red channel, with a whisper of green
        /// so bright whites keep a little shape.
        static let lut: UIImage = {
            let n = 32
            var rgba = [UInt8](repeating: 0, count: n * n * n * 4)
            for b in 0..<n {
                for g in 0..<n {
                    for r in 0..<n {
                        let lum = 0.35 * Double(r) + 0.50 * Double(g) + 0.15 * Double(b)
                        let v = UInt8(min(255, lum / Double(n - 1) * 255))
                        let i = (g * n * n + b * n + r) * 4
                        rgba[i] = v
                        rgba[i + 1] = UInt8(Double(v) * 0.10)
                        rgba[i + 2] = 0
                        rgba[i + 3] = 255
                    }
                }
            }
            // The buffer pointer is only valid inside this closure, so the
            // context must be created AND read back within it.
            let image: CGImage? = rgba.withUnsafeMutableBytes { buf in
                CGContext(data: buf.baseAddress, width: n * n, height: n, bitsPerComponent: 8,
                          bytesPerRow: n * n * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
            return image.map(UIImage.init(cgImage:)) ?? UIImage()
        }()

        static func setOverlay(_ on: Bool) {
            if on {
                guard overlay == nil,
                      let window = UIApplication.shared.connectedScenes
                        .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
                let v = UIView(frame: window.bounds)
                v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                v.backgroundColor = UIColor(red: 1.0, green: 0.14, blue: 0.05, alpha: 1)
                v.layer.compositingFilter = "multiplyBlendMode"
                v.isUserInteractionEnabled = false
                window.addSubview(v)
                overlay = v
            } else {
                overlay?.removeFromSuperview()
                overlay = nil
            }
        }
    }

    func applyNightVision() {
        let on = engine?.nightVision == true
        sceneView.pointOfView?.camera?.colorGrading.contents = on ? NightVision.lut : nil
        NightVision.setOverlay(on)
    }

    // MARK: ISS pass alerts

    private var issAlertsScheduledAt: Date?

    /// Toggle handler: ask permission, then schedule; clearing removes only
    /// our own pending requests.
    func applyISSAlerts() {
        if engine?.issAlerts == true {
            Task { @MainActor in
                let center = UNUserNotificationCenter.current()
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                guard granted else { engine?.issAlerts = false; return }
                scheduleISSPassAlerts()
            }
        } else {
            issAlertsScheduledAt = nil
            Task {
                let center = UNUserNotificationCenter.current()
                let ours = await center.pendingNotificationRequests()
                    .map(\.identifier).filter { $0.hasPrefix("isspass-") }
                center.removePendingNotificationRequests(withIdentifiers: ours)
            }
        }
    }

    /// Refresh the schedule when it's older than six hours (TLE drift and
    /// location changes both stay well inside that window).
    func scheduleISSPassAlertsIfStale() {
        guard engine?.issAlerts == true,
              issAlertsScheduledAt.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true
        else { return }
        scheduleISSPassAlerts()
    }

    /// Scan the next 48 h of the orbit for visible passes (elevation > 10°)
    /// and schedule a local notification 10 minutes before each rise.
    /// Stamps freshness only once the TLE and a location are actually in hand,
    /// so an early bail keeps `scheduleISSPassAlertsIfStale()` retrying.
    private func scheduleISSPassAlerts() {
        guard let sat = sky?.issSatellite, let here = observerLocation else { return }
        issAlertsScheduledAt = Date()
        let lat = here.coordinate.latitude, lon = here.coordinate.longitude
        Task.detached(priority: .utility) {
            var passes: [(rise: Date, maxEl: Double, az: Double)] = []
            let start = Date()
            var t = 120.0
            var rise: Date?
            var riseAz = 0.0, maxEl = 0.0
            while t < 48 * 3600, passes.count < 4 {
                let date = start.addingTimeInterval(t)
                if let lla = try? sat.geoPosition(julianDays: SkyMath.julianDay(date)) {
                    let g = SkyMath.azElRange(observerLat: lat, observerLon: lon, observerAltM: 0,
                                              targetLat: lla.lat, targetLon: lla.lon,
                                              targetAltM: lla.alt * 1000)
                    if g.elevation > 10 {
                        if rise == nil { rise = date; riseAz = g.azimuth }
                        maxEl = max(maxEl, g.elevation)
                    } else if let r = rise {
                        passes.append((r, maxEl, riseAz))
                        rise = nil; maxEl = 0
                    }
                }
                t += 30
            }
            let found = passes
            await MainActor.run {
                Self.scheduleNotifications(for: found)
            }
        }
    }

    private static func scheduleNotifications(for passes: [(rise: Date, maxEl: Double, az: Double)]) {
        Task {
            let center = UNUserNotificationCenter.current()
            let stale = await center.pendingNotificationRequests()
                .map(\.identifier).filter { $0.hasPrefix("isspass-") }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            for pass in passes {
                let fireAt = pass.rise.addingTimeInterval(-600)
                guard fireAt > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = "ISS pass in 10 minutes"
                content.body = "Rises \(compass(pass.az)) and climbs to \(Int(pass.maxEl.rounded()))° — open Overhead to watch it cross."
                content.sound = .default
                let comps = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: fireAt)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                try? await center.add(UNNotificationRequest(
                    identifier: "isspass-\(Int(pass.rise.timeIntervalSince1970))",
                    content: content, trigger: trigger))
            }
        }
    }

    private func pauseEverything() {
        sceneView.session.pause()
        stopDisplayLink()
        pollTask?.cancel()
        pollTask = nil
    }

    /// A full-screen chrome sheet (Profile / Settings / Events / Search) is
    /// covering the live sky. Nothing is visible to update, so stop the per-frame
    /// aircraft + sky simulation, the SceneKit render loop, and the network feed,
    /// then resume the instant it's dismissed. The AR session and its tracking are
    /// left running (unlike a full background pause), so returning is seamless and
    /// any heading calibration is left untouched.
    private var skyObscured = false
    func setSkyObscured(_ obscured: Bool) {
        guard isViewLoaded, skyObscured != obscured else { return }
        skyObscured = obscured
        if obscured {
            stopDisplayLink()
            pollTask?.cancel()
            pollTask = nil
            sceneView.isPlaying = false
            sceneView.rendersContinuously = false
        } else {
            sceneView.isPlaying = true
            sceneView.rendersContinuously = true
            applyBackground()       // the mode may have changed inside the cover
            startPolling()          // restarts the display link and the feed
        }
    }

    /// When the app was backgrounded, so a long absence can prompt a re-align.
    private var backgroundedAt: Date?

    @objc private func appDidBackground() { backgroundedAt = Date(); pauseEverything() }
    @objc private func appDidBecomeActive() {
        guard viewIfLoaded?.window != nil else { return }
        startSession()         // ARKit runs in both modes; resume it
        applyBackground()      // dome visibility per mode
        if !skyObscured { startPolling() }   // stay idle if a sheet still covers the sky
        refreshISSTLEIfStale() // a multi-day background may have aged the TLE
        suggestRealignIfNeeded()
    }

    /// After a real gap away, a precise manual lock or a shaky compass may no
    /// longer be trustworthy once tracking re-localises — surface a gentle
    /// "re-align?" prompt rather than silently drifting. Quick app switches
    /// (under the threshold) are left alone.
    private func suggestRealignIfNeeded() {
        defer { backgroundedAt = nil }
        guard let since = backgroundedAt, Date().timeIntervalSince(since) > 45 else { return }
        let manualLock = engine?.autoAlignEnabled == false
        let acc = engine?.headingAccuracyDeg ?? -1
        let poorCompass = acc < 0 || acc > 20
        if manualLock || poorCompass {
            engine?.realignDismissed = false
            engine?.realignSuggested = true
        }
    }

    // MARK: Polling

    /// Choose the live-traffic provider: Flightradar24 when a token is set
    /// (global, satellite coverage — but billed per call, so poll gently),
    /// otherwise the free non-commercial airplanes.live feed.
    func configureDataSource() {
        if let key = engine?.fr24ApiKey, !key.isEmpty {
            dataSource = FR24Source(apiKey: key)
            pollInterval = .seconds(8)
        } else {
            dataSource = ADSBClient()
            pollInterval = .seconds(1)
        }
    }

    private func startPolling() {
        configureDataSource()
        startDisplayLink()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(1))
            }
        }
    }

    private var feedFailureStreak = 0

    private func pollOnce() async {
        guard let here = observerLocation else { return }
        // Sky (sun/moon/stars/ISS) refreshes every tick regardless of the feed.
        updateSky(observer: here, forceStars: false)
        updateAirports(observer: here)
        do {
            let traffic = try await dataSource.aircraft(
                lat: here.coordinate.latitude,
                lon: here.coordinate.longitude,
                radiusNm: searchRadiusNm)
            feedFailureStreak = 0
            engine?.feedOffline = false
            update(with: traffic, observer: here)
        } catch {
            // Transient errors are expected at 1 Hz; surface only a streak.
            feedFailureStreak += 1
            if feedFailureStreak >= 3 { engine?.feedOffline = true }
            // Age out stale planes even while the feed is down, so glyphs —
            // and their spatial-audio hums — don't haunt the sky at their
            // last known spots indefinitely.
            removeStale(now: Date())
            updateAudio()
        }
    }

    private func effectiveDate() -> Date {
        Date().addingTimeInterval((engine?.skyTimeOffsetMin ?? 0) * 60)
    }

    private func updateSky(observer: CLLocation, forceStars: Bool) {
        sky?.update(date: effectiveDate(),
                    lat: observer.coordinate.latitude,
                    lon: observer.coordinate.longitude,
                    offset: engine?.headingOffsetDeg ?? 0,
                    mirror: engine?.mirrorX ?? false,
                    forceStars: forceStars)
    }

    // MARK: Rendering

    private func update(with traffic: [Aircraft], observer: CLLocation) {
        let now = Date()
        let offset = engine?.headingOffsetDeg ?? 0
        let mirror = engine?.mirrorX ?? false
        var visible = 0
        // Accumulate the Home/Lock-Screen glance as we place traffic: how many
        // are airborne, and the closest one (with its true bearing for the rose).
        var glanceAirborne = 0
        var glanceNearest: SkyGlanceSnapshot.Plane?
        var glanceNearestRange = Double.greatestFiniteMagnitude

        for ac in traffic {
            // Ground traffic is hidden unless explicitly enabled.
            if ac.onGround, engine?.showGroundAircraft != true { dropAircraft(ac.hex); continue }

            // Anchor the fix to the instant it was actually true (feed `seen_pos`
            // plus pipeline lag); the display link projects it forward from here
            // every frame so the glyph rides where the plane *is*, not where it
            // was — continuous motion instead of a 1 Hz step.
            let anchor = Anchor(lat: ac.lat, lon: ac.lon, altM: ac.altitudeMeters,
                                track: ac.track, gsKts: ac.groundSpeedKts,
                                vsFpm: ac.verticalRateFpm,
                                observedAt: now.addingTimeInterval(-((ac.positionAgeSec ?? 0) + dataSource.feedLatencySec)))
            let (az, el, range) = geometry(of: anchor, at: now, observer: observer)

            // Cull only what's well below the horizon. We allow a wide negative
            // band because an observer up high (an airport lounge, a tower) looks
            // *down* at nearby ground traffic, which sits below eye level.
            guard el > -25 else { dropAircraft(ac.hex); continue }

            // Naked-eye filter: skip distant/low contacts you couldn't actually
            // see — but never drop a plane the user is explicitly tracking.
            // Hysteresis: a plane already on screen stays until it's clearly out,
            // so boundary jitter doesn't flicker the plane (and its trail) on/off.
            let rangeNm = range / 1852
            let tracked = ac.hex == selectedHex
                || (engine?.focusedCallsign != nil && ac.callsign == engine?.focusedCallsign)
            let shown = nodes[ac.hex] != nil
            // On-ground planes (apron/runway) are visible even below the horizon
            // when you're up high, so they skip the elevation floor and use a
            // short range — you can only pick out a plane on the ground nearby.
            let baseMax = ac.onGround ? min(nakedEyeMaxRangeNm(altitudeFeet: 0), 6)
                                      : nakedEyeMaxRangeNm(altitudeFeet: ac.altitudeFeet)
            let maxNm = baseMax * (shown ? 1.18 : 1.0)
            let minEl = ac.onGround ? -90 : Self.nakedEyeMinElevationDeg - (shown ? 1.5 : 0)
            if engine?.nakedEyeOnly == true, !tracked, rangeNm > maxNm || el < minEl {
                dropAircraft(ac.hex); continue
            }

            visible += 1
            anchors[ac.hex] = anchor
            lastSeen[ac.hex] = now
            lastFix[ac.hex] = Fix(az: az, el: el, range: range, aircraft: ac)

            // Glance: count airborne traffic and keep the nearest as the hero.
            if !ac.onGround {
                glanceAirborne += 1
                if range < glanceNearestRange {
                    glanceNearestRange = range
                    let cs = ac.callsign?.trimmingCharacters(in: .whitespaces)
                    glanceNearest = SkyGlanceSnapshot.Plane(
                        callsign: (cs?.isEmpty == false) ? cs : nil,
                        type: ac.type,
                        destination: routes.cached(ac.callsign)?.destinationCode,
                        distanceNm: range / 1852,
                        altitudeFeet: ac.altitudeFeet,
                        bearingDeg: az, elevationDeg: el)
                }
            }

            let position = SkyMath.scenePosition(
                azimuthDeg: az, elevationDeg: el, radius: sphereRadius,
                headingOffsetDeg: offset, mirrorX: mirror)

            let node: AircraftNode
            if let existing = nodes[ac.hex] {
                node = existing
                node.apply(aircraft: ac)
                node.removeAction(forKey: "move")     // motion + heading now per-frame
            } else {
                node = AircraftNode(aircraft: ac)
                node.apply(aircraft: ac)
                node.position = position
                nodes[ac.hex] = node
                worldNode.addChildNode(node)
            }
            node.isHidden = !(engine?.showAircraft ?? true) || hiddenBySpotlight(ac)
            trailNodes[ac.hex]?.isHidden = node.isHidden || !(engine?.showTrails ?? true)

            let labelOn = labelVisible(rangeNm: range / 1852, hex: ac.hex)
            node.setLabelVisible(labelOn)
            if labelOn {
                // Enrich labeled aircraft with their route (cached); apply destination.
                if let route = routes.cached(ac.callsign) {
                    node.setRouteDestination(route.destinationCode)
                } else {
                    routes.request(ac.callsign)
                }
            }

            // Trail = where the plane actually *was* (the raw fixes), not the
            // extrapolated "now" spot — extrapolation jitter made the line jagged.
            let rawFix = geometry(of: anchor, at: anchor.observedAt, observer: observer)
            let rawPosition = SkyMath.scenePosition(azimuthDeg: rawFix.az, elevationDeg: rawFix.el,
                                                    radius: sphereRadius,
                                                    headingOffsetDeg: offset, mirrorX: mirror)
            updateTrail(hex: ac.hex, position: rawPosition, aircraft: ac)
        }

        removeStale(now: now)
        engine?.trafficCount = visible
        #if DEBUG
        // `-shot spotlight` hook: emulate picking the first live plane from
        // search, so the spotlight state can be captured deterministically.
        if ShotScreen.current == .spotlight, engine?.focusedCallsign == nil,
           let first = traffic.first(where: { $0.callsign != nil && !$0.onGround }) {
            trackSearchResult(SearchResult(
                hex: first.hex, callsign: first.callsign, type: first.type,
                registration: nil, airline: nil, altitudeFeet: first.altitudeFeet,
                onGround: false, distanceNm: nil, azimuth: nil, inView: true))
        }
        #endif
        refreshSelection()
        applyFocus()
        updateTransitPrediction(traffic: traffic, observer: observer)
        updateAudio()
        writeGlance(count: glanceAirborne, nearest: glanceNearest, observer: observer)
    }

    /// Persist the "what's overhead now" glance for the widgets, and nudge a
    /// timeline reload only when the visible content changes — the feed ticks at
    /// 1 Hz but the Home Screen has no reason to redraw that often.
    private func writeGlance(count: Int, nearest: SkyGlanceSnapshot.Plane?, observer: CLLocation) {
        let snapshot = SkyGlanceSnapshot(updated: Date(), count: count,
                                         offline: engine?.feedOffline ?? false,
                                         nearest: nearest,
                                         observerLat: observer.coordinate.latitude,
                                         observerLon: observer.coordinate.longitude)
        SkyGlance.write(snapshot)

        // Signature captures only what the widget renders; skip no-op reloads.
        let sig = "\(count)|\(nearest?.callsign ?? "-")|\(Int((nearest?.distanceNm ?? 0).rounded()))|\(Int((nearest?.bearingDeg ?? 0).rounded()))"
        let now = Date()
        guard sig != lastGlanceSignature, now.timeIntervalSince(lastGlanceReload) > 20 else { return }
        lastGlanceSignature = sig
        lastGlanceReload = now
        WidgetCenter.shared.reloadTimelines(ofKind: SkyGlance.widgetKind)
    }

    // MARK: Per-frame dead reckoning

    /// Observer height in metres on the WGS84 ellipsoid — the same datum ADS-B
    /// geometric altitude uses — so the vertical baseline isn't off by the local
    /// geoid undulation (tens of metres). Falls back to the geoid/MSL altitude
    /// when the ellipsoidal value isn't available (older fix, no vertical fix).
    private func observerAltMeters(_ loc: CLLocation) -> Double {
        let e = loc.ellipsoidalAltitude
        return (loc.verticalAccuracy > 0 && e.isFinite) ? e : loc.altitude
    }

    /// Project an anchor forward to `date` along its ground track and return the
    /// observer-relative geometry. The forward step auto-includes feed latency
    /// because the anchor is timestamped to when the fix was actually true.
    private func geometry(of anchor: Anchor, at date: Date, observer: CLLocation)
        -> (az: Double, el: Double, range: Double) {
        var lat = anchor.lat, lon = anchor.lon, altM = anchor.altM
        let dt = min(max(date.timeIntervalSince(anchor.observedAt), 0), maxExtrapolationSec)
        if let track = anchor.track, let gs = anchor.gsKts, gs > 40 {
            let meters = gs * 0.514444 * dt
            let tr = track * .pi / 180
            lat += (meters * cos(tr) / 6_371_000) * 180 / .pi
            lon += (meters * sin(tr) / (6_371_000 * cos(anchor.lat * .pi / 180))) * 180 / .pi
        }
        // Climb/descent: carry the plane's altitude forward too, so traffic on
        // approach or departure sits at the height it's actually at now, not its
        // last-reported one. ft/min → m/s × dt; never below the ground.
        if let vs = anchor.vsFpm, abs(vs) > 1 {
            altM = max(0, altM + vs / 60 * 0.3048 * dt)
        }
        let r = SkyMath.azElRange(observerLat: observer.coordinate.latitude,
                                  observerLon: observer.coordinate.longitude,
                                  observerAltM: observerAltMeters(observer),
                                  targetLat: lat, targetLon: lon, targetAltM: altM)
        return (az: r.azimuth, el: r.elevation, range: r.range)
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepAircraft))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Re-place every aircraft each display frame from its anchor, so markers
    /// glide continuously with the real planes between 1 Hz fixes. A light
    /// low-pass absorbs the small correction when a fresh fix lands without
    /// adding lag (the target is always projected to true-now).
    @objc private func stepAircraft() {
        if scanStart != nil { updateScanCoverage() }
        // The night shells (dark dome, camera scrim, horizon glow) are sky
        // backdrops, not world objects: keep them centered on the camera so
        // walking can never carry the observer outside them — from outside
        // they loom as a huge dark sphere with a violet glow band.
        if let pov = sceneView.pointOfView?.presentation {
            let p = pov.worldPosition
            darkDomeNode.position = p
            dimDomeNode.position = p
            horizonGlowNode.position = p
        }
        // The sky itself refreshes at 1 Hz regardless of the traffic poll —
        // on the slow FR24 cadence (8 s) the ISS would otherwise jump ~8° at
        // a time during a pass, and the sun/moon would visibly stutter.
        if let observer = observerLocation, Date().timeIntervalSince(lastSkyStepAt) >= 1 {
            lastSkyStepAt = Date()
            updateSky(observer: observer, forceStars: false)
        }
        // The binaural listener follows the camera a few times a second, so
        // "point the phone at the sound" holds while the user turns — not
        // just once per poll.
        if engine?.soundOn == true, orientTick % 6 == 0 { updateAudio() }
        guard let observer = observerLocation, !anchors.isEmpty else { return }
        let now = Date()
        let offset = engine?.headingOffsetDeg ?? 0
        let mirror = engine?.mirrorX ?? false
        // Heading (glyph direction) changes slowly and needs an expensive screen
        // projection — only recompute it a few times a second, not every frame.
        // Position stays per-frame so motion is still smooth.
        orientTick &+= 1
        let doOrient = orientTick % 10 == 0
        for (hex, anchor) in anchors {
            guard let node = nodes[hex], !node.isHidden else { continue }
            let (az, el, range) = geometry(of: anchor, at: now, observer: observer)
            let target = SkyMath.scenePosition(azimuthDeg: az, elevationDeg: el,
                                               radius: sphereRadius,
                                               headingOffsetDeg: offset, mirrorX: mirror)
            let p = node.position
            let a: Float = 0.5
            node.position = SCNVector3(p.x + (target.x - p.x) * a,
                                       p.y + (target.y - p.y) * a,
                                       p.z + (target.z - p.z) * a)
            if doOrient {
                // Aim the glyph along its track: project the spot it'll be a few
                // seconds ahead and point at that on screen.
                let fwd = geometry(of: anchor, at: now.addingTimeInterval(10), observer: observer)
                let ahead = SkyMath.scenePosition(azimuthDeg: fwd.az, elevationDeg: fwd.el,
                                                  radius: sphereRadius,
                                                  headingOffsetDeg: offset, mirrorX: mirror)
                orientGlyph(node, at: target, ahead: ahead)
            }
            lastFix[hex]?.az = az
            lastFix[hex]?.el = el
            lastFix[hex]?.range = range
        }
        if engine?.hearFeelSky == true, orientTick % 4 == 0 { updateProximityHaptic() }
    }
    private var orientTick = 0
    private var lastSkyStepAt = Date.distantPast

    /// Remove an aircraft and everything attached to it (node, trail, fix).
    private func dropAircraft(_ hex: String) {
        guard nodes[hex] != nil || anchors[hex] != nil else { return }
        nodes[hex]?.removeFromParentNode(); nodes[hex] = nil
        trailNodes[hex]?.removeFromParentNode(); trailNodes[hex] = nil
        trails[hex] = nil
        lastFix[hex] = nil
        lastSeen[hex] = nil
        anchors[hex] = nil
        if hex == selectedHex { deselect() }
    }

    /// Drop already-plotted planes that no longer pass the naked-eye filter, so
    /// turning the setting on clears the distant ones without waiting for a poll.
    func applyAircraftVisibilityFilter() {
        guard let engine, engine.nakedEyeOnly else { return }
        for (hex, fix) in lastFix {
            let ac = fix.aircraft
            let tracked = hex == selectedHex
                || (engine.focusedCallsign != nil && ac.callsign == engine.focusedCallsign)
            // Mirror the poll-loop rules exactly (ground exemption from the
            // elevation floor + shown-plane hysteresis), otherwise each slider
            // tick instantly drops planes the next poll immediately re-adds.
            let baseMax = ac.onGround ? min(nakedEyeMaxRangeNm(altitudeFeet: 0), 6)
                                      : nakedEyeMaxRangeNm(altitudeFeet: ac.altitudeFeet)
            let minEl = ac.onGround ? -90 : Self.nakedEyeMinElevationDeg - 1.5
            if !tracked, fix.range / 1852 > baseMax * 1.18 || fix.el < minEl {
                dropAircraft(hex)
            }
        }
    }

    /// Max slant range (nm) at which an aircraft is treated as naked-eye visible.
    /// High jets — and their contrails — stay visible far past low traffic, so
    /// the user's baseline range is extended with altitude. Horizon haze is
    /// handled separately by the elevation floor.
    private func nakedEyeMaxRangeNm(altitudeFeet: Double) -> Double {
        let base = engine?.nakedEyeRangeNm ?? 35
        let altBonus = max(0, (altitudeFeet - 20000) / 1000)   // +1 nm per 1000 ft above FL200
        return base + min(altBonus, 30)
    }

    // MARK: Spatial flyover audio

    func applySoundMode() {
        if engine?.soundOn == true {
            skyAudio.start()
            updateAudio()
        } else {
            skyAudio.stop()
        }
    }

    // MARK: Accessibility — feel the plane

    private let proxHaptic = UIImpactFeedbackGenerator(style: .medium)
    private var lastProxHapticAt: Date?

    func applyAccessibility() {
        if engine?.hearFeelSky == true { proxHaptic.prepare() }
    }

    /// "Feel" the sky: emit a haptic pulse whose strength and tempo rise as a
    /// plane nears the center of where you're pointing — a Geiger-counter for
    /// aircraft, so a plane can be found by touch alone. Throttled by caller.
    private func updateProximityHaptic() {
        let center = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        var nearest = CGFloat.greatestFiniteMagnitude
        for (_, node) in nodes where !node.isHidden {
            let p = sceneView.projectPoint(node.presentation.worldPosition)
            guard p.z > 0, p.z < 1 else { continue }
            nearest = min(nearest, hypot(CGFloat(p.x) - center.x, CGFloat(p.y) - center.y))
        }
        let reach: CGFloat = 220                       // beyond this you're not on a plane
        guard nearest < reach else { return }
        let t = 1 - (nearest / reach)                  // 0 at the edge … 1 dead-centre
        let interval = 0.55 - 0.42 * Double(t)         // 0.55 s far … 0.13 s centred
        let now = Date()
        if let last = lastProxHapticAt, now.timeIntervalSince(last) < interval { return }
        lastProxHapticAt = now
        proxHaptic.impactOccurred(intensity: CGFloat(0.35 + 0.65 * t))
    }

    private func updateAudio() {
        guard engine?.soundOn == true, skyAudio.running else { return }
        // While tracking, the soundscape spotlights only the focused flight;
        // otherwise it's the ambient hum of the nearest aircraft.
        let sources: [(hex: String, position: SCNVector3)]
        if let focusHex = focusedHex {
            sources = nodes[focusHex].map { [(focusHex, $0.presentation.worldPosition)] } ?? []
        } else {
            let nearestFirst = lastFix.sorted { $0.value.range < $1.value.range }
            sources = nearestFirst.compactMap { hex, _ in
                guard let node = nodes[hex], !node.isHidden else { return nil }
                return (hex, node.presentation.worldPosition)
            }
        }
        let pov = sceneView.pointOfView?.presentation
        let forward = pov?.simdWorldFront ?? simd_float3(0, 0, -1)
        let up = pov?.simdWorldUp ?? simd_float3(0, 1, 0)
        skyAudio.update(sources: sources, forward: forward, up: up)
    }

    // MARK: Transit alerts (plane × moon/sun)

    private var transitHapticFired = false

    private func updateTransitPrediction(traffic: [Aircraft], observer: CLLocation) {
        guard let engine else { return }
        // Keep an active prediction until it plays out (+grace), then rescan.
        if let current = engine.transitPrediction {
            if current.date.timeIntervalSinceNow > -4 {
                if current.date.timeIntervalSinceNow < 5, !transitHapticFired {
                    transitHapticFired = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                return
            }
            engine.transitPrediction = nil
            transitHapticFired = false
        }
        // Transit alerts are real-world events. While the sky clock is
        // scrubbed the displayed sun/moon are displaced from the real ones,
        // and the aircraft are always at real-now — don't mix the two frames.
        guard engine.skyTimeOffsetMin == 0 else { return }
        let date = Date()
        let lat = observer.coordinate.latitude
        let lon = observer.coordinate.longitude
        let moon = Celestial.moon(date: date, lat: lat, lon: lon)
        let sun = Celestial.sun(date: date, lat: lat, lon: lon)
        engine.transitPrediction = TransitPredictor.predict(
            aircraft: traffic,
            observerLat: lat, observerLon: lon, observerAltM: observer.altitude,
            moon: (moon.az, moon.el), sun: (sun.az, sun.el))
    }

    /// Rotate a glyph to its on-screen direction of motion so the nose runs
    /// head-to-tail along the drawn trail. Falls back to a track-based
    /// estimate when there's no usable projected motion yet.
    /// Aim the glyph along its true direction of travel: project the plane's
    /// current spot and a spot a little further along its track, and point the
    /// glyph from one to the other on screen. Works regardless of motion timing
    /// or where the camera is aimed (so it stays correct while you pan).
    private func orientGlyph(_ node: AircraftNode, at position: SCNVector3, ahead: SCNVector3) {
        let p1 = sceneView.projectPoint(worldNode.convertPosition(position, to: nil))
        let p2 = sceneView.projectPoint(worldNode.convertPosition(ahead, to: nil))
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y                        // view coords: y grows downward
        guard p1.z > 0, p1.z < 1, dx * dx + dy * dy > 1 else { return }
        node.setGlyphScreenAngle(atan2(dx, -dy))
    }

    // MARK: Favorites & focus

    /// Hex of the focused flight in the current feed, resolved by callsign.
    private var focusedHex: String? {
        guard let callsign = engine?.focusedCallsign else { return nil }
        return lastFix.first { $0.value.aircraft.callsign == callsign }?.key
    }

    /// Restyle every aircraft for favorite rings + focus dimming, and refresh
    /// the on-screen guidance for the focused flight.
    func applyFocus() {
        guard let engine else { return }
        let focusHex = focusedHex
        let focusing = engine.focusedCallsign != nil
        for (hex, node) in nodes {
            let callsign = lastFix[hex]?.aircraft.callsign
            node.setFavorite(callsign.map { engine.favorites.contains($0) } ?? false)
            node.setFocused(focusing && hex == focusHex)
            node.opacity = (focusing && hex != focusHex) ? 0.22 : 1.0
        }
        updateFocusGuidance()
        syncLiveActivity()
    }

    /// Mirror the focused flight onto the lock screen / Dynamic Island.
    private func syncLiveActivity() {
        guard let engine else { return }
        guard let callsign = engine.focusedCallsign else {
            flightActivity.end()
            return
        }
        let fix = focusedHex.flatMap { lastFix[$0] }
        let state = FlightActivityAttributes.ContentState(
            altitudeFeet: fix?.aircraft.altitudeFeet ?? 0,
            distanceNm: (fix?.range ?? 0) / 1852,
            bearingDeg: fix?.az ?? 0,
            overhead: fix != nil)
        if flightActivity.callsign != callsign {
            let route = routes.cached(callsign).flatMap { r -> String? in
                guard let dest = r.destinationCode else { return nil }
                let origin = r.originCode.map { "\($0) → " } ?? "→ "
                return origin + dest
            } ?? ""
            flightActivity.start(callsign: callsign, route: route, state: state)
        } else {
            flightActivity.update(state)
        }
    }

    /// Compute the find-it arrow: project the focused flight into view space;
    /// when it's outside the screen, the arrow points from center toward it.
    func updateFocusGuidance() {
        guard let engine, let callsign = engine.focusedCallsign else {
            engine?.focusInfo = nil
            return
        }
        guard let hex = focusedHex, let fix = lastFix[hex], let node = nodes[hex] else {
            engine.focusInfo = .init(callsign: callsign, distanceNm: 0, arrowAngle: nil, overhead: false)
            return
        }
        let projected = sceneView.projectPoint(node.worldPosition)
        let bounds = sceneView.bounds
        let behind = projected.z > 1 || projected.z < 0
        // Pinch zoom scales the view about its center, so only the central
        // bounds/zoom region is actually visible — a plane outside it needs
        // the arrow even though it projects inside the unscaled bounds.
        let visible = bounds.insetBy(dx: bounds.width * (1 - 1 / zoomFactor) / 2,
                                     dy: bounds.height * (1 - 1 / zoomFactor) / 2)
        let onScreen = !behind
            && visible.contains(CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)))
        var arrow: Double?
        if !onScreen {
            var dx = Double(projected.x) - bounds.width / 2
            var dy = Double(projected.y) - bounds.height / 2
            if behind { dx = -dx; dy = -dy }   // projection flips behind the camera
            arrow = atan2(dx, -dy) * 180 / .pi
        }
        engine.focusInfo = .init(callsign: callsign,
                                 distanceNm: fix.range / 1852,
                                 arrowAngle: arrow,
                                 overhead: true)
    }

    // MARK: Airports

    /// Place nearby major airports on the horizon at their true bearings.
    private func updateAirports(observer: CLLocation) {
        let show = engine?.showAirports ?? true
        guard show else {
            airportNodes.values.forEach { $0.isHidden = true }
            return
        }
        let offset = engine?.headingOffsetDeg ?? 0
        let mirror = engine?.mirrorX ?? false
        for airport in AirportCatalog.shared.airports {
            let (az, el, range) = SkyMath.azElRange(
                observerLat: observer.coordinate.latitude,
                observerLon: observer.coordinate.longitude,
                observerAltM: observer.altitude,
                targetLat: airport.lat, targetLon: airport.lon, targetAltM: 0)
            let rangeNm = range / 1852
            guard rangeNm <= 150 else {
                airportNodes[airport.iata]?.isHidden = true
                continue
            }
            let node: AirportNode
            if let existing = airportNodes[airport.iata] {
                node = existing
            } else {
                node = AirportNode(airport: airport)
                airportNodes[airport.iata] = node
                worldNode.addChildNode(node)
            }
            node.isHidden = false
            // Airports sit on the ground; pin them just above the horizon line.
            node.position = SkyMath.scenePosition(
                azimuthDeg: az, elevationDeg: max(el, 0.8), radius: sphereRadius,
                headingOffsetDeg: offset, mirrorX: mirror)
            node.lastAzimuth = az
            node.lastRangeNm = rangeNm
        }
    }

    private func selectAirport(_ node: AirportNode) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let a = node.airport
        engine?.selectedAirport = SelectedAirport(
            iata: a.iata, icao: a.icao, name: a.name, city: a.city, country: a.country,
            lat: a.lat, lon: a.lon,
            distanceNm: node.lastRangeNm, azimuth: node.lastAzimuth)
    }

    // MARK: Catch the crossing (capture + share)

    /// Snapshot the live view (camera + overlay composited), dress it as a
    /// share card, and hand it to the share sheet.
    func captureShareCard() {
        let snapshot = sceneView.snapshot()
        let title: String
        if let transit = engine?.transitPrediction {
            title = "\(transit.callsign) crossing the \(transit.body.rawValue)"
        } else if let selected = engine?.selected {
            title = selected.callsign
        } else {
            title = "The sky right now"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        let card = Self.renderShareCard(snapshot: snapshot, title: title,
                                        subtitle: formatter.string(from: Date()))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let share = UIActivityViewController(activityItems: [card], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view
        present(share, animated: true)
    }

    private static func renderShareCard(snapshot: UIImage, title: String, subtitle: String) -> UIImage {
        let size = snapshot.size
        return UIGraphicsImageRenderer(size: size).image { ctx in
            snapshot.draw(in: CGRect(origin: .zero, size: size))
            // Footer gradient for legibility.
            let footerHeight = size.height * 0.16
            let footerTop = size.height - footerHeight
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [UIColor.black.withAlphaComponent(0).cgColor,
                                           UIColor.black.withAlphaComponent(0.75).cgColor] as CFArray,
                                  locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(grad,
                                             start: CGPoint(x: 0, y: footerTop),
                                             end: CGPoint(x: 0, y: size.height), options: [])
            let pad = size.width * 0.05
            let titleFont = UIFont.systemFont(ofSize: size.width * 0.045, weight: .bold)
            let subFont = UIFont.systemFont(ofSize: size.width * 0.028, weight: .medium)
            (title as NSString).draw(
                at: CGPoint(x: pad, y: size.height - footerHeight * 0.62),
                withAttributes: [.font: titleFont, .foregroundColor: UIColor.white])
            (subtitle as NSString).draw(
                at: CGPoint(x: pad, y: size.height - footerHeight * 0.28),
                withAttributes: [.font: subFont,
                                 .foregroundColor: UIColor.white.withAlphaComponent(0.7)])
            let brand = "Overhead" as NSString
            let brandFont = UIFont.systemFont(ofSize: size.width * 0.032, weight: .semibold)
            let brandSize = brand.size(withAttributes: [.font: brandFont])
            brand.draw(at: CGPoint(x: size.width - pad - brandSize.width,
                                   y: size.height - footerHeight * 0.45),
                       withAttributes: [.font: brandFont,
                                        .foregroundColor: UIColor(red: 0.6, green: 0.74, blue: 1.0, alpha: 0.95)])
        }
    }

    // MARK: Comet trails (M5)

    private func updateTrail(hex: String, position: SCNVector3, aircraft: Aircraft) {
        guard engine?.showTrails ?? true else { return }
        var points = trails[hex] ?? []
        // Skip near-duplicate points (a slow/parked plane), which would make the
        // line geometry degenerate and look broken.
        if let last = points.last {
            let dx = last.x - position.x, dy = last.y - position.y, dz = last.z - position.z
            if dx * dx + dy * dy + dz * dz < 4 { return }   // < 2 m of movement
        }
        points.append(position)
        if points.count > maxTrail { points.removeFirst(points.count - maxTrail) }
        trails[hex] = points
        guard points.count >= 2 else { return }

        let color = AircraftNode.altitudeColor(feet: aircraft.altitudeFeet, onGround: aircraft.onGround)
        let geometry = SCNGeometry.fadingTrail(points, color: color)

        if let trailNode = trailNodes[hex] {
            trailNode.geometry = geometry
        } else {
            let trailNode = SCNNode(geometry: geometry)
            trailNodes[hex] = trailNode
            worldNode.addChildNode(trailNode)
        }
    }

    private func removeStale(now: Date) {
        for (hex, seen) in lastSeen where now.timeIntervalSince(seen) > staleAfter {
            dropAircraft(hex)
        }
    }

    /// Whether an aircraft should carry a label given the current declutter mode.
    private func labelVisible(rangeNm: Double, hex: String) -> Bool {
        if hex == selectedHex { return true }
        switch engine?.labelMode ?? .nearby {
        case .all:    return true
        case .off:    return false
        case .nearby: return rangeNm <= (engine?.nearbyRangeNm ?? 60)
        }
    }

    // MARK: Calibration / declutter hooks (called by SkyEngine)

    /// Re-place every node immediately when a calibration knob changes, so a
    /// known plane can be lined up with the real sky without waiting for a poll.
    func applyCalibrationNow() {
        let offset = engine?.headingOffsetDeg ?? 0
        let mirror = engine?.mirrorX ?? false
        for (hex, fix) in lastFix {
            guard let node = nodes[hex] else { continue }
            node.removeAction(forKey: "move")
            node.position = SkyMath.scenePosition(azimuthDeg: fix.az, elevationDeg: fix.el,
                                                  radius: sphereRadius,
                                                  headingOffsetDeg: offset, mirrorX: mirror)
        }
        // Old trail points were plotted with the previous calibration; reset them.
        trailNodes.values.forEach { $0.removeFromParentNode() }
        trailNodes.removeAll()
        trails.removeAll()
        // Re-place the sky for the new calibration too.
        if let here = observerLocation { updateSky(observer: here, forceStars: true) }
    }

    func applyLabelMode() {
        for (hex, fix) in lastFix {
            nodes[hex]?.setLabelVisible(labelVisible(rangeNm: fix.range / 1852, hex: hex))
        }
    }

    // MARK: Selection (tap to identify)

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: sceneView)
        let hits = sceneView.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        if let node = hits.lazy.compactMap({ $0.node.aircraftAncestor }).first {
            select(hex: node.hex)
        } else if let airport = hits.lazy.compactMap({ $0.node.airportAncestor }).first {
            selectAirport(airport)
        } else if let nearest = nearestAircraftNode(to: point, within: 44) {
            // Forgiving fallback: planes are tiny and moving, so grab the closest
            // glyph within a comfortable thumb radius rather than demanding a precise hit.
            select(hex: nearest.hex)
        } else {
            deselect()
        }
    }

    /// The on-screen-closest aircraft glyph to `point`, within `threshold` points.
    private func nearestAircraftNode(to point: CGPoint, within threshold: CGFloat) -> AircraftNode? {
        var best: AircraftNode?
        var bestDistance = threshold
        for node in nodes.values where !node.isHidden {   // never grab an invisible plane
            let projected = sceneView.projectPoint(node.worldPosition)
            guard projected.z > 0, projected.z < 1 else { continue }  // in front of camera
            let dx = CGFloat(projected.x) - point.x
            let dy = CGFloat(projected.y) - point.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                best = node
            }
        }
        return best
    }

    private func select(hex: String) {
        if let previous = selectedHex, previous != hex { nodes[previous]?.setSelected(false) }
        selectedHex = hex
        nodes[hex]?.setSelected(true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if spottedThisSession.insert(hex).inserted {
            engine?.recordSpot(aircraft: lastFix[hex]?.aircraft)
        }
        routes.request(lastFix[hex]?.aircraft.callsign)
        photos.request(hex)
        engine?.selectedPhoto = photos.cachedPhoto(hex)
        refreshSelection()
        applyLabelMode()
    }

    /// Open the focused flight's detail (the focus pill is tappable).
    func selectFocusedFlight() {
        if let hex = focusedHex { select(hex: hex) }
    }

    // MARK: Flight search

    /// Matches among the aircraft currently in our sky — instant, no network.
    func localMatches(field: AircraftSearchField, query rawQuery: String) -> [SearchResult] {
        let q = field.normalized(rawQuery)
        guard !q.isEmpty else { return [] }
        var out: [SearchResult] = []
        for (hex, fix) in lastFix {
            let ac = fix.aircraft
            let hay: String?
            switch field {
            case .callsign:     hay = ac.callsign
            case .registration: hay = ac.registration
            case .type:         hay = ac.type
            case .squawk:       hay = ac.squawk
            }
            guard let hay = hay?.uppercased(), hay.contains(q) else { continue }
            out.append(searchResult(hex: hex, aircraft: ac, az: fix.az, range: fix.range, inView: true))
        }
        return out.sorted { ($0.distanceNm ?? .infinity) < ($1.distanceNm ?? .infinity) }
    }

    /// Global lookup of any matching aircraft via the data source, with
    /// observer-relative distance filled in when we know where we are.
    func globalSearch(field: AircraftSearchField, value: String) async -> [SearchResult] {
        let matches = (try? await dataSource.search(field: field, value: value)) ?? []
        let inViewHexes = Set(lastFix.keys)
        let results: [SearchResult] = matches.map { ac in
            var az: Double?, range: Double?
            if let here = observerLocation {
                let g = SkyMath.azElRange(observerLat: here.coordinate.latitude,
                                          observerLon: here.coordinate.longitude,
                                          observerAltM: here.altitude,
                                          targetLat: ac.lat, targetLon: ac.lon,
                                          targetAltM: ac.altitudeMeters)
                az = g.azimuth; range = g.range
            }
            return searchResult(hex: ac.hex, aircraft: ac, az: az, range: range,
                                inView: inViewHexes.contains(ac.hex))
        }
        // A type/squawk lookup can match thousands; keep the nearest handful.
        return Array(results.sorted { ($0.distanceNm ?? .infinity) < ($1.distanceNm ?? .infinity) }
            .prefix(50))
    }

    private func searchResult(hex: String, aircraft ac: Aircraft,
                              az: Double?, range: Double?, inView: Bool) -> SearchResult {
        SearchResult(hex: hex,
                     callsign: ac.callsign,
                     type: ac.type,
                     registration: ac.registration,
                     airline: routes.cached(ac.callsign)?.airline,
                     altitudeFeet: ac.altitudeFeet,
                     onGround: ac.onGround,
                     distanceNm: range.map { $0 / 1852 },
                     azimuth: az,
                     inView: inView)
    }

    /// Link a search hit to the track system: focus it by callsign so it's
    /// followed (and auto-locked when it enters range), and open its detail now
    /// if it's already in our sky.
    func trackSearchResult(_ result: SearchResult) {
        if let cs = result.callsign?.trimmingCharacters(in: .whitespaces), !cs.isEmpty {
            engine?.focusedCallsign = cs
            // Search spotlight: the sky shows only the plane they asked for.
            // Cleared by ✕ on the focus pill or "Show all" on the status pill.
            engine?.spotlightOnly = true
        }
        routes.request(result.callsign)
        if nodes[result.hex] != nil || lastFix[result.hex] != nil {
            select(hex: result.hex)
        }
    }

    func deselect() {
        if let hex = selectedHex { nodes[hex]?.setSelected(false) }
        selectedHex = nil
        engine?.selected = nil
        engine?.selectedPhoto = nil
        applyLabelMode()
    }

    /// Rebuild the selected aircraft snapshot from its latest fix. Azimuth and
    /// elevation are the *true* values (uncalibrated) — that's what you compare
    /// against a flight tracker.
    private func refreshSelection() {
        guard let hex = selectedHex, let fix = lastFix[hex] else {
            if selectedHex != nil { engine?.selected = nil }
            return
        }
        let ac = fix.aircraft
        let route = routes.cached(ac.callsign)
        // Globetrotter accrues whenever a spotted flight's destination
        // country resolves (routes come back async; the store dedupes).
        if let engine, let iso = route?.destCountryISO {
            engine.medals.recordDestinationCountry(iso, totalSpots: engine.statFlightsSpotted)
        }
        let arrival = observedArrival(of: ac)
        // adsbdb maps callsigns to *filed* routes — often one leg of a
        // multi-stop run, or stale. When the plane is visibly on approach to
        // a different field than the filed destination, say so.
        var mismatch = false
        if let arrival, let filed = route?.destinationCode {
            mismatch = filed != arrival.iata && filed != arrival.icao
        }
        engine?.selected = SelectedAircraft(
            hex: hex,
            callsign: ac.callsign ?? hex.uppercased(),
            type: ac.type,
            altitudeFeet: ac.altitudeFeet,
            onGround: ac.onGround,
            azimuth: fix.az,
            elevation: fix.el,
            distanceNm: fix.range / 1852,
            track: ac.track,
            groundSpeedKts: ac.groundSpeedKts,
            verticalRateFpm: ac.verticalRateFpm,
            registration: ac.registration,
            squawk: ac.squawk,
            airline: route?.airline,
            origin: route?.originCode,
            originCity: route?.originCity,
            destination: route?.destinationCode,
            destinationCity: route?.destinationCity,
            lat: ac.lat,
            lon: ac.lon,
            originLat: route?.originLat,
            originLon: route?.originLon,
            destLat: route?.destLat,
            destLon: route?.destLon,
            observedArrival: arrival?.iata,
            observedArrivalCity: arrival?.city,
            routeMismatch: mismatch)
    }

    /// Where this plane is actually landing, judged by physics: low, slow,
    /// and within a few miles of a known field = on approach there.
    private func observedArrival(of ac: Aircraft) -> Airport? {
        guard !ac.onGround,
              ac.altitudeFeet > 0, ac.altitudeFeet < 4500,
              (ac.groundSpeedKts ?? 999) < 230 else { return nil }
        var best: (airport: Airport, rangeNm: Double)?
        for airport in AirportCatalog.shared.airports {
            let range = SkyMath.azElRange(observerLat: airport.lat, observerLon: airport.lon,
                                          observerAltM: 0,
                                          targetLat: ac.lat, targetLon: ac.lon,
                                          targetAltM: ac.altitudeMeters).range / 1852
            if range < 15, range < (best?.rangeNm ?? .infinity) {
                best = (airport, range)
            }
        }
        return best?.airport
    }

    private func routeResolved(_ callsign: String) {
        let route = routes.cached(callsign)
        for (hex, fix) in lastFix where fix.aircraft.callsign == callsign {
            nodes[hex]?.setRouteDestination(route?.destinationCode)
        }
        if let hex = selectedHex, lastFix[hex]?.aircraft.callsign == callsign {
            refreshSelection()
        }
    }

    // MARK: Layer / time hooks (called by SkyEngine)

    /// True when the search spotlight is on and this aircraft isn't the one.
    private func hiddenBySpotlight(_ ac: Aircraft?) -> Bool {
        guard engine?.spotlightOnly == true,
              let focus = engine?.focusedCallsign else { return false }
        return ac?.callsign?.trimmingCharacters(in: .whitespaces) != focus
    }

    func applyLayerVisibility() {
        let showAircraft = engine?.showAircraft ?? true
        let showGround = engine?.showGroundAircraft ?? false
        let showTrails = engine?.showTrails ?? true
        for (hex, node) in nodes {
            let grounded = lastFix[hex]?.aircraft.onGround == true
            node.isHidden = !showAircraft || (grounded && !showGround)
                || hiddenBySpotlight(lastFix[hex]?.aircraft)
            trailNodes[hex]?.isHidden = node.isHidden || !showTrails
        }
        sky?.setVisibility()
        if let here = observerLocation {
            updateSky(observer: here, forceStars: true)
            updateAirports(observer: here)
        }
    }

    func applyTrailVisibility() {
        let show = engine?.showTrails ?? true
        for node in trailNodes.values { node.isHidden = !show }
        if !show { trails.removeAll() }
    }

    func applySkyTimeNow() {
        if let here = observerLocation { updateSky(observer: here, forceStars: true) }
    }

    // MARK: ISS (M4)

    private var issTLEFetchedAt: Date?
    private var issTLEFetching = false

    /// Bring up the ISS orbit from a cached TLE instantly (offline-friendly),
    /// then refresh from the network only when it's missing or stale. A TLE
    /// drifts ~1–2 km/day and is unreliable past ~10 days, so a daily refresh
    /// keeps passes accurate without hammering Celestrak.
    private func loadOrRefreshISSTLE() {
        if sky?.issSatellite == nil,
           let lines = UserDefaults.standard.stringArray(forKey: SkyDefaults.issTLELines),
           lines.count >= 3, let sat = try? Satellite(lines[0], lines[1], lines[2]) {
            sky?.issSatellite = sat
            issTLEFetchedAt = UserDefaults.standard.object(forKey: SkyDefaults.issTLEDate) as? Date
        }
        refreshISSTLEIfStale()
    }

    /// Re-fetch the TLE if we've never fetched one or it's over a day old.
    private func refreshISSTLEIfStale() {
        let stale = issTLEFetchedAt.map { Date().timeIntervalSince($0) > 86_400 } ?? true
        guard stale, !issTLEFetching else { return }
        issTLEFetching = true
        Task { await fetchISSTLE(); issTLEFetching = false }
    }

    private func fetchISSTLE() async {
        guard let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=tle"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 3, let sat = try? Satellite(lines[0], lines[1], lines[2]) else { return }
        sky?.issSatellite = sat
        issTLEFetchedAt = Date()
        UserDefaults.standard.set(Array(lines.prefix(3)), forKey: SkyDefaults.issTLELines)
        UserDefaults.standard.set(issTLEFetchedAt, forKey: SkyDefaults.issTLEDate)
        // Fresh elements → refresh any scheduled pass alerts.
        issAlertsScheduledAt = nil
        scheduleISSPassAlertsIfStale()
    }

    /// Scrub the sky clock forward to the ISS's next rise above ~10°.
    func jumpToNextISSPass() {
        guard let here = observerLocation, let sat = sky?.issSatellite else { return }
        let lat = here.coordinate.latitude, lon = here.coordinate.longitude
        let start = Date()
        var minutes = 0.5
        while minutes < 60 * 12 {                       // the sky-time slider tops out at +12 h
            let date = start.addingTimeInterval(minutes * 60)
            if let lla = try? sat.geoPosition(julianDays: SkyMath.julianDay(date)) {
                let r = SkyMath.azElRange(observerLat: lat, observerLon: lon, observerAltM: 0,
                                          targetLat: lla.lat, targetLon: lla.lon, targetAltM: lla.alt * 1000)
                if r.elevation > 10 { engine?.skyTimeOffsetMin = minutes; return }
            }
            minutes += 0.5
        }
    }
}

// MARK: - ARSCNViewDelegate (interruption recovery)

extension ARSkyViewController: ARSCNViewDelegate {
    /// The camera can be interrupted (lock screen, app switcher, another app
    /// claiming it). Without an explicit re-run the iOS 27 capture daemon can
    /// leave the session "running" but starved of frames — a frozen feed under
    /// live SceneKit content. Re-run as soon as the interruption ends.
    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            // Plain re-run (no reset): keeps the world frame, but kicks the
            // capture pipeline back to life when the interruption ended
            // without a didBecomeActive (in-call banner, Split View, etc.).
            self.startSession(reset: false)
            self.applyBackground()
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.startSession(reset: true)
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension ARSkyViewController: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            engine?.usingDemoLocation = false
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        case .denied, .restricted:
            // Demo sky: show a real, busy piece of sky rather than a dead end.
            observerLocation = CLLocation(latitude: 37.6213, longitude: -122.3790)
            engine?.usingDemoLocation = true
            engine?.loadEventsIfNeeded(lat: 37.6213, lon: -122.3790)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            observerLocation = loc
            // Siri's "what's flying over me" answers from the last known spot.
            UserDefaults.standard.set(loc.coordinate.latitude, forKey: SkyDefaults.lastLat)
            UserDefaults.standard.set(loc.coordinate.longitude, forKey: SkyDefaults.lastLon)
            // Seed the widget so it can self-refresh even before the next poll.
            SkyGlance.writeLocation(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            engine?.loadEventsIfNeeded(lat: loc.coordinate.latitude,
                                       lon: loc.coordinate.longitude)
            // The launch-time attempt bails without a fix; now that one exists,
            // schedule for real. No-ops once stamped fresh.
            scheduleISSPassAlertsIfStale()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        engine?.headingAccuracyDeg = newHeading.headingAccuracy
        // During a calibration sweep, gather samples instead of live-steering.
        if scanStart != nil { collectScanSample(newHeading); return }
        alignNorth(with: newHeading)
        // Keep the find-it arrow tracking as the user turns.
        updateFocusGuidance()
        // iOS often declines to show its own calibration overlay; surface our
        // quiet hint when the compass stays poor for ten seconds straight.
        let accuracy = newHeading.headingAccuracy
        if accuracy < 0 || accuracy > 25 {
            if poorCompassSince == nil { poorCompassSince = Date() }
            if let since = poorCompassSince, Date().timeIntervalSince(since) > 10 {
                engine?.compassHintNeeded = true
            }
        } else {
            poorCompassSince = nil
            engine?.compassHintNeeded = false
        }
    }

    /// Let iOS put up its figure-8 calibration overlay whenever the compass is
    /// unusable — the sky placement is only as good as the heading.
    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        let accuracy = manager.heading?.headingAccuracy ?? -1
        return accuracy < 0 || accuracy > 20
    }

    /// Keep content azimuths lined up with true north. The first plausible
    /// heading snaps the sky into place; after that, every decent compass
    /// sample gently steers the alignment toward consensus — noise averages
    /// out, and constant bias (the sky sitting a few degrees left or right of
    /// reality) heals itself within seconds of panning. No manual trim needed.
    private func alignNorth(with heading: CLHeading) {
        guard engine?.autoAlignEnabled ?? true else { return }   // manual lock holds
        guard heading.trueHeading >= 0, heading.headingAccuracy >= 0,
              heading.headingAccuracy <= 30,
              let pov = sceneView.pointOfView else { return }
        let f = pov.presentation.simdWorldFront
        // Near the zenith — the natural posture for this app — the horizontal
        // component of the camera front is noise, so any yaw derived from it
        // would slowly random-walk the sky. Wait for a usable posture.
        guard (Double(f.x) * Double(f.x) + Double(f.z) * Double(f.z)).squareRoot() > 0.25 else { return }
        // Camera's horizontal yaw in the content convention (0 = −Z, 90° = +X).
        let yawCamDeg = atan2(Double(f.x), Double(-f.z)) * 180 / .pi

        // Roll this reading into a short consensus window; a better-rated sample
        // carries more weight. Consensus — not any single CLHeading — drives every
        // lock, so one magnetically-corrupted reading can't strand the sky.
        let now = Date()
        northSamples.append((offset: heading.trueHeading - yawCamDeg,
                             weight: 1.0 / max(heading.headingAccuracy, 5), t: now))
        northSamples.removeAll { now.timeIntervalSince($0.t) > 4.0 }
        if northSamples.count > 24 { northSamples.removeFirst(northSamples.count - 24) }
        guard let cons = northConsensus() else { return }
        let desired = cons.mean * .pi / 180
        let agree = cons.r                       // 1 = window agrees tightly, 0 = scattered

        var error = (desired - Double(worldNode.eulerAngles.y))
            .truncatingRemainder(dividingBy: 2 * .pi)
        if error > .pi { error -= 2 * .pi }
        if error < -.pi { error += 2 * .pi }
        let errDeg = abs(error) * 180 / .pi

        if appliedNorthAccuracy == .infinity {
            // First lock: never trust a lone reading. Wait until several samples
            // over ≥1s agree tightly, then snap to their consensus. This is what
            // stops a single bad heading from locking the whole sky the wrong way.
            guard northSamples.count >= 5, cons.span >= 1.0, agree >= 0.9 else { return }
            appliedNorthAccuracy = heading.headingAccuracy
            driftSince = nil
            snapNorth(to: desired, duration: 0.6)
            return
        }

        // A large error the *whole window* agrees on isn't a spike — the sky has
        // genuinely drifted (a bad prior lock, or a strong local field that has
        // since passed). If it persists ~1.5s, re-snap to consensus rather than
        // rejecting the very samples that would heal it — the old gate's fatal
        // flaw, which left a wrong alignment wrong until the app relaunched.
        let big = max(20.0, heading.headingAccuracy * 2.0)
        if errDeg > big {
            if agree >= 0.9 {
                if driftSince == nil { driftSince = now }
                if now.timeIntervalSince(driftSince ?? now) >= 1.5 {
                    driftSince = nil
                    appliedNorthAccuracy = heading.headingAccuracy
                    snapNorth(to: desired, duration: 0.5)
                }
            } else {
                driftSince = nil                 // scattered → magnetic noise, ignore
            }
            return
        }
        driftSince = nil

        // Small, steady error: gentle bias correction. Deadband keeps the sky
        // calm; gain scales with both compass confidence and window agreement.
        guard abs(error) > 1.5 * .pi / 180 else { return }
        let gain = min(0.05, max(0.01, 0.02 * (25 / max(heading.headingAccuracy, 5)))) * agree
        worldNode.eulerAngles.y += Float(error * gain)
    }

    /// Weighted circular mean of the north-estimate window, with the resultant
    /// length `r` ∈ [0,1] (how tightly the samples agree) and the time `span`
    /// they cover. nil until the window holds anything.
    private func northConsensus() -> (mean: Double, r: Double, span: TimeInterval)? {
        guard let first = northSamples.first, let last = northSamples.last else { return nil }
        var sx = 0.0, sy = 0.0, sw = 0.0
        for s in northSamples {
            let a = s.offset * .pi / 180
            sx += cos(a) * s.weight; sy += sin(a) * s.weight; sw += s.weight
        }
        guard sw > 0 else { return nil }
        let mean = atan2(sy, sx) * 180 / .pi
        let r = (sx * sx + sy * sy).squareRoot() / sw
        return (mean, r, last.t.timeIntervalSince(first.t))
    }

    /// Rotate the world so its north sits at `desired` (radians), shortest arc.
    private func snapNorth(to desired: Double, duration: TimeInterval) {
        let rotate = SCNAction.rotateTo(x: 0, y: CGFloat(desired), z: 0,
                                        duration: duration, usesShortestUnitArc: true)
        rotate.timingMode = .easeInEaseOut
        worldNode.runAction(rotate)
    }

    // MARK: Guided calibration (360° sweep → lock to Sun/Moon or a plane)

    /// Camera yaw in the content convention (0 = −Z, 90° = +X), degrees.
    /// nil near the zenith, where the projected yaw is noise.
    private func cameraYawDeg() -> Double? {
        guard let f = sceneView.pointOfView?.presentation.simdWorldFront,
              (Double(f.x) * Double(f.x) + Double(f.z) * Double(f.z)).squareRoot() > 0.25 else { return nil }
        return atan2(Double(f.x), Double(-f.z)) * 180 / .pi
    }

    /// Set the sky so that `trueBearing` (deg from north) lines up with wherever
    /// the camera is currently pointed — the heart of every lock. Reuses the
    /// north-alignment relation: worldNode.y = trueBearing − cameraYaw.
    private func lockBearingToCamera(_ trueBearing: Double, animated: Bool) {
        guard let yaw = cameraYawDeg() else { return }
        var d = (trueBearing - yaw).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }; if d < -180 { d += 360 }
        let desired = CGFloat(d * .pi / 180)
        engine?.autoAlignEnabled = false
        engine?.lastManualAlignAt = Date()       // for the alignment-confidence HUD
        if animated {
            let r = SCNAction.rotateTo(x: 0, y: desired, z: 0, duration: 0.4, usesShortestUnitArc: true)
            r.timingMode = .easeInEaseOut
            worldNode.runAction(r)
        } else {
            worldNode.eulerAngles.y = Float(desired)
        }
    }

    func beginCalibrationScan() {
        preCalibration = (engine?.headingOffsetDeg ?? 0,
                          engine?.autoAlignEnabled ?? true,
                          worldNode.eulerAngles.y)
        engine?.headingOffsetDeg = 0          // worldNode rotation is the only knob
        engine?.autoAlignEnabled = false       // freeze passive align during the sweep
        calibrationSamples.removeAll()
        scanBuckets.removeAll()
        northSamples.removeAll(); driftSince = nil
        scanStart = Date()
    }

    func cancelCalibrationScan() {
        scanStart = nil
        // Cancel means discard: restore trim, align mode and sky rotation.
        if let saved = preCalibration {
            preCalibration = nil
            engine?.headingOffsetDeg = saved.offsetDeg
            engine?.autoAlignEnabled = saved.autoAlign
            worldNode.removeAllActions()
            worldNode.eulerAngles.y = saved.worldY
        }
    }

    /// Jump straight to the lock step (Sun/Moon/plane) without finishing the sweep.
    func skipScan() { if scanStart != nil { finishScan() } else { engine?.calibrationStartAligning() } }

    func lockManualAlignment() { preCalibration = nil; engine?.autoAlignEnabled = false; scanStart = nil }

    func resumeAutoAlign() {
        preCalibration = nil
        scanStart = nil
        appliedNorthAccuracy = .infinity       // re-snap from a fresh consensus
        northSamples.removeAll(); driftSince = nil
    }

    /// Compass sample (only when valid) — feeds the best-fit north estimate.
    /// Coverage/progress is driven separately off ARKit yaw, so the sweep still
    /// completes when the compass is reporting "invalid" (a glass building).
    private func collectScanSample(_ heading: CLHeading) {
        guard heading.trueHeading >= 0, heading.headingAccuracy >= 0,
              let yaw = cameraYawDeg() else { return }
        calibrationSamples.append((offset: heading.trueHeading - yaw,
                                   weight: 1.0 / max(heading.headingAccuracy, 5)))
    }

    /// Advance the sweep on how far the phone has actually turned (ARKit yaw),
    /// independent of the compass. Runs every display frame while scanning.
    private func updateScanCoverage() {
        guard let yaw = cameraYawDeg() else { return }
        let bucket = Int(((yaw.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360) / 15)   // 24 sectors of 15°
        scanBuckets.insert(max(0, min(23, bucket)))
        engine?.calibrationScanProgress = Double(scanBuckets.count) / 24.0
        let elapsed = Date().timeIntervalSince(scanStart ?? Date())
        if scanBuckets.count >= 18 || elapsed > 22 { finishScan() }
    }

    private func finishScan() {
        scanStart = nil
        // Weighted circular mean of the per-sample north offsets.
        var sx = 0.0, sy = 0.0
        for s in calibrationSamples {
            let r = s.offset * .pi / 180
            sx += cos(r) * s.weight; sy += sin(r) * s.weight
        }
        if sx != 0 || sy != 0 {
            let mean = atan2(sy, sx)
            let rot = SCNAction.rotateTo(x: 0, y: CGFloat(mean), z: 0,
                                         duration: 0.5, usesShortestUnitArc: true)
            rot.timingMode = .easeInEaseOut
            worldNode.runAction(rot)
        }
        engine?.calibrationScanProgress = 1
        // Tell the UI which precise references are available for the lock step.
        if let here = observerLocation {
            let now = effectiveDate()
            let sun = Celestial.sun(date: now, lat: here.coordinate.latitude, lon: here.coordinate.longitude)
            let moon = Celestial.moon(date: now, lat: here.coordinate.latitude, lon: here.coordinate.longitude)
            engine?.calibrationSunUp = sun.el > 3
            engine?.calibrationMoonUp = moon.el > 3
        }
        engine?.calibrationStartAligning()
    }

    /// Lock north by pinning the Sun (or Moon) — whose azimuth we know to a
    /// fraction of a degree — to wherever the camera is aimed.
    func lockToSun() {
        guard let here = observerLocation else { return }
        let s = Celestial.sun(date: effectiveDate(), lat: here.coordinate.latitude, lon: here.coordinate.longitude)
        lockBearingToCamera(s.az, animated: true)
    }
    func lockToMoon() {
        guard let here = observerLocation else { return }
        let m = Celestial.moon(date: effectiveDate(), lat: here.coordinate.latitude, lon: here.coordinate.longitude)
        lockBearingToCamera(m.az, animated: true)
    }

    /// Pin the selected plane's known true bearing to the camera centre — the
    /// all-weather alternative to a Sun/Moon lock. The user centres the real
    /// aircraft, then locks.
    func lockToSelectedAircraft() {
        guard let hex = selectedHex, let fix = lastFix[hex] else { return }
        lockBearingToCamera(fix.az, animated: true)
    }

    /// Enter the drag/tap-to-align step directly from the live screen (no sweep).
    /// Only needs to publish which precise references are currently up; the pan
    /// and lock primitives are shared with the guided flow. Auto-align is left
    /// running until the user actually drags or locks, so a cancel is harmless.
    func prepareQuickAlign() {
        guard let here = observerLocation else { return }
        let now = effectiveDate()
        let sun = Celestial.sun(date: now, lat: here.coordinate.latitude, lon: here.coordinate.longitude)
        let moon = Celestial.moon(date: now, lat: here.coordinate.latitude, lon: here.coordinate.longitude)
        engine?.calibrationSunUp = sun.el > 3
        engine?.calibrationMoonUp = moon.el > 3
    }

    /// One-finger drag during the aligning step rotates the whole sky so the
    /// user can slide a plane (or the Sun/Moon) onto its real-world position.
    @objc private func handleAlignPan(_ g: UIPanGestureRecognizer) {
        guard engine?.calibrationStep == .aligning else { return }
        switch g.state {
        case .began:
            engine?.autoAlignEnabled = false
        case .changed:
            let dx = g.translation(in: sceneView).x
            g.setTranslation(.zero, in: sceneView)
            worldNode.eulerAngles.y -= Float(dx) * 0.0045   // ~0.26°/pt
        case .ended, .cancelled:
            engine?.lastManualAlignAt = Date()              // hand-aligned counts
        default:
            break
        }
    }
}

// MARK: - Node ancestry helper

extension SCNNode {
    /// Walk up the node tree to the owning AircraftNode, if any.
    var aircraftAncestor: AircraftNode? {
        var current: SCNNode? = self
        while let node = current {
            if let aircraft = node as? AircraftNode { return aircraft }
            current = node.parent
        }
        return nil
    }

    /// Walk up the node tree to the owning AirportNode, if any.
    var airportAncestor: AirportNode? {
        var current: SCNNode? = self
        while let node = current {
            if let airport = node as? AirportNode { return airport }
            current = node.parent
        }
        return nil
    }
}

// MARK: - Airport node (horizon marker with IATA code)

/// A grounded marker: small diamond on the horizon with the airport's IATA
/// code on a backing plate, billboarded like everything else on the dome.
final class AirportNode: SCNNode {

    let airport: Airport
    var lastAzimuth: Double = 0
    var lastRangeNm: Double = 0

    private static let markerColor = UIColor(red: 0.72, green: 0.62, blue: 1.0, alpha: 1)

    init(airport: Airport) {
        self.airport = airport
        super.init()
        constraints = [SCNBillboardConstraint()]

        // Invisible hit pad for comfortable tapping.
        let pad = SCNPlane(width: 40, height: 40)
        let padMat = SCNMaterial()
        padMat.diffuse.contents = UIColor.clear
        padMat.isDoubleSided = true
        pad.materials = [padMat]
        let padNode = SCNNode(geometry: pad)
        padNode.position = SCNVector3(0, 4, -0.5)
        addChildNode(padNode)

        // Diamond pin.
        let pin = SCNPlane(width: 6, height: 6)
        let pinMat = SCNMaterial()
        pinMat.lightingModel = .constant
        pinMat.diffuse.contents = Self.markerColor
        pinMat.isDoubleSided = true
        pin.materials = [pinMat]
        let pinNode = SCNNode(geometry: pin)
        pinNode.eulerAngles.z = .pi / 4
        addChildNode(pinNode)

        // IATA code on a soft plate above the pin.
        let text = SCNText(string: airport.iata, extrusionDepth: 0)
        text.font = .systemFont(ofSize: 8, weight: .bold)
        text.flatness = 0.2
        let tmat = SCNMaterial(); tmat.lightingModel = .constant
        tmat.diffuse.contents = Self.markerColor
        text.materials = [tmat]
        let label = SCNNode(geometry: text)
        label.scale = SCNVector3(0.7, 0.7, 0.7)
        let (minB, maxB) = text.boundingBox
        let width = (maxB.x - minB.x) * 0.7
        label.position = SCNVector3(-width / 2, 7, 0.1)
        addChildNode(label)

        let plate = SCNPlane(width: CGFloat(width) + 4, height: 8)
        plate.cornerRadius = 2
        let plateMat = SCNMaterial()
        plateMat.lightingModel = .constant
        plateMat.diffuse.contents = UIColor.black.withAlphaComponent(0.45)
        plate.materials = [plateMat]
        let plateNode = SCNNode(geometry: plate)
        plateNode.position = SCNVector3(0, 10, 0)
        addChildNode(plateNode)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension SCNGeometry {
    /// A line geometry from vertices arranged as consecutive segment pairs.
    static func line(_ verts: [SCNVector3]) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: verts)
        let element = SCNGeometryElement(indices: Array(Int32(0)..<Int32(verts.count)), primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    /// A comet trail: an ordered polyline whose brightness fades toward the
    /// tail, blended additively so it reads as a streak of light.
    static func fadingTrail(_ points: [SCNVector3], color: UIColor) -> SCNGeometry {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)

        var verts: [SCNVector3] = []
        var colors: [simd_float4] = []
        let n = points.count
        for i in 1..<n {
            // Newest segments (end of the array) glow; the tail melts away.
            let fade0 = pow(Float(i - 1) / Float(max(n - 1, 1)), 1.6) * 0.8
            let fade1 = pow(Float(i) / Float(max(n - 1, 1)), 1.6) * 0.8
            verts.append(points[i - 1])
            colors.append(simd_float4(Float(r) * fade0, Float(g) * fade0, Float(b) * fade0, 1))
            verts.append(points[i])
            colors.append(simd_float4(Float(r) * fade1, Float(g) * fade1, Float(b) * fade1, 1))
        }

        let vertexSource = SCNGeometrySource(vertices: verts)
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color, vectorCount: colors.count,
            usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<simd_float4>.stride)
        let element = SCNGeometryElement(indices: Array(Int32(0)..<Int32(verts.count)),
                                         primitiveType: .line)
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white      // vertex colors carry the hue
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}

// MARK: - Aircraft node (billboarded glyph + label)

/// One sky object: a billboarded placeholder triangle glyph plus a legible label
/// (airline/type today; destination in M5) on a semi-transparent backing plate.
/// Carries an invisible hit target for easy tapping and a halo for selection.
final class AircraftNode: SCNNode {

    let hex: String

    private let glyphNode = SCNNode()
    private let labelNode = SCNNode()
    private let plateNode = SCNNode()
    private let haloNode = SCNNode()
    private let favoriteNode = SCNNode()
    private let focusNode = SCNNode()
    private let hitNode = SCNNode()
    private var baseScale: Float = 1
    private var destinationCode: String?
    private var lastAircraft: Aircraft?

    init(aircraft: Aircraft) {
        hex = aircraft.hex
        super.init()
        constraints = [SCNBillboardConstraint()]   // always face the camera
        buildHitTarget()
        buildHalo()
        buildGlyph(for: aircraft)
        buildLabel(for: aircraft)
        // apply(aircraft:azimuthDeg:) runs immediately after creation in
        // update(with:) once the bearing is known.
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A large transparent plane so small glyphs are still easy to tap.
    private func buildHitTarget() {
        let plane = SCNPlane(width: 44, height: 44)
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.clear
        mat.isDoubleSided = true
        plane.materials = [mat]
        hitNode.geometry = plane
        hitNode.position = SCNVector3(0, -4, -0.5)
        addChildNode(hitNode)
    }

    private func buildHalo() {
        let torus = SCNTorus(ringRadius: 11, pipeRadius: 0.5)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor(red: 0.60, green: 0.74, blue: 1.0, alpha: 1)
        torus.materials = [mat]
        haloNode.geometry = torus
        haloNode.isHidden = true
        addChildNode(haloNode)

        // Favorite: a real heart riding above the glyph — white-rimmed pink
        // with a soft glow so it reads on black sky and daylight camera alike.
        let heart = SCNPlane(width: 9, height: 9)
        let heartMat = SCNMaterial()
        heartMat.lightingModel = .constant
        heartMat.diffuse.contents = AircraftNode.heartImage
        heartMat.isDoubleSided = true
        heart.materials = [heartMat]
        favoriteNode.geometry = heart
        favoriteNode.position = SCNVector3(0, 11, 0.2)
        favoriteNode.isHidden = true
        addChildNode(favoriteNode)

        // Focus: a warm gold ring, breathing gently.
        let focusTorus = SCNTorus(ringRadius: 14, pipeRadius: 0.7)
        let focusMat = SCNMaterial()
        focusMat.lightingModel = .constant
        focusMat.diffuse.contents = UIColor(red: 1.0, green: 0.82, blue: 0.45, alpha: 1)
        focusTorus.materials = [focusMat]
        focusNode.geometry = focusTorus
        focusNode.isHidden = true
        if !UIAccessibility.isReduceMotionEnabled {
            let breathe = SCNAction.repeatForever(.sequence([
                .scale(to: 1.15, duration: 1.0),
                .scale(to: 1.0, duration: 1.0),
            ]))
            breathe.timingMode = .easeInEaseOut
            focusNode.runAction(breathe)
        }
        addChildNode(focusNode)
    }

    func setFavorite(_ on: Bool) { favoriteNode.isHidden = !on }
    func setFocused(_ on: Bool) { focusNode.isHidden = !on }

    /// Glowing white-rimmed pink heart sprite, shared across nodes.
    static let heartImage: UIImage = {
        let size = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            // Soft pink glow halo.
            let center = CGPoint(x: 32, y: 32)
            let pink = UIColor(red: 1.0, green: 0.42, blue: 0.58, alpha: 1)
            let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [pink.withAlphaComponent(0.55).cgColor,
                                           pink.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(glow, startCenter: center, startRadius: 2,
                                             endCenter: center, endRadius: 32, options: [])
            // White rim heart behind, pink heart in front.
            let rimConfig = UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
            let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
            if let rim = UIImage(systemName: "heart.fill", withConfiguration: rimConfig)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                rim.draw(in: CGRect(x: 32 - rim.size.width / 2, y: 32 - rim.size.height / 2,
                                    width: rim.size.width, height: rim.size.height))
            }
            if let fill = UIImage(systemName: "heart.fill", withConfiguration: config)?
                .withTintColor(pink, renderingMode: .alwaysOriginal) {
                fill.draw(in: CGRect(x: 32 - fill.size.width / 2, y: 32 - fill.size.height / 2,
                                     width: fill.size.width, height: fill.size.height))
            }
        }
    }()

    /// Crisp SF Symbol airliner, drawn nose-up, white so the altitude tint can
    /// multiply it to colour. A soft dark outline keeps it legible on a bright
    /// daytime sky as well as black.
    static let planeImage: UIImage = {
        let size = CGSize(width: 128, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let config = UIImage.SymbolConfiguration(pointSize: 78, weight: .semibold)
            guard let plane = UIImage(systemName: "airplane", withConfiguration: config) else { return }
            // The symbol's nose points east by default; rotate it to point up.
            cg.translateBy(x: 64, y: 64)
            cg.rotate(by: -.pi / 2)
            let rect = CGRect(x: -plane.size.width / 2, y: -plane.size.height / 2,
                              width: plane.size.width, height: plane.size.height)
            // Dark halo for contrast, then the white plane on top.
            plane.withTintColor(.black.withAlphaComponent(0.55), renderingMode: .alwaysOriginal)
                .draw(in: rect.insetBy(dx: -1.5, dy: -1.5))
            plane.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: rect)
        }
    }()

    private func buildGlyph(for aircraft: Aircraft) {
        let billboard = SCNPlane(width: 18, height: 18)
        let mat = SCNMaterial()
        mat.lightingModel = .constant     // unaffected by scene lighting; reads on bright sky
        mat.diffuse.contents = AircraftNode.planeImage
        mat.isDoubleSided = true
        billboard.materials = [mat]
        glyphNode.geometry = billboard
        baseScale = Float(GlyphCategory.from(aircraft.category).scale)
        glyphNode.scale = SCNVector3(baseScale, baseScale, baseScale)
        addChildNode(glyphNode)
    }

    private func buildLabel(for aircraft: Aircraft) {
        let text = SCNText(string: labelString(for: aircraft), extrusionDepth: 0)
        text.font = .systemFont(ofSize: 8, weight: .semibold)
        text.flatness = 0.2
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.white
        text.materials = [mat]
        labelNode.geometry = text
        labelNode.scale = SCNVector3(0.6, 0.6, 0.6)

        let (minB, maxB) = text.boundingBox
        let width = (maxB.x - minB.x) * 0.6
        labelNode.position = SCNVector3(-width / 2, -14, 0.1)

        let plate = SCNPlane(width: CGFloat(width) + 3, height: 5)
        plate.cornerRadius = 1.2
        let plateMat = SCNMaterial()
        plateMat.lightingModel = .constant
        plateMat.diffuse.contents = UIColor.black.withAlphaComponent(0.45)
        plate.materials = [plateMat]
        plateNode.geometry = plate
        plateNode.position = SCNVector3(0, -12, 0)

        addChildNode(plateNode)
        addChildNode(labelNode)
    }

    private func labelString(for aircraft: Aircraft) -> String {
        let callsign = aircraft.callsign ?? aircraft.hex.uppercased()
        var s = callsign
        if let type = aircraft.type, !type.isEmpty { s += " · \(type)" }
        if let dest = destinationCode, !dest.isEmpty { s += " → \(dest)" }
        return s
    }

    /// Refresh per-fix visuals: altitude-graded color and the label text.
    /// Orientation is set separately via `setGlyphScreenAngle` — the
    /// controller derives it from the node's actual projected motion so the
    /// nose always points along the drawn trail.
    func apply(aircraft: Aircraft) {
        lastAircraft = aircraft
        let color = AircraftNode.altitudeColor(feet: aircraft.altitudeFeet, onGround: aircraft.onGround)
        // Tint the white plane symbol by altitude via multiply (keeps the dark
        // outline and crisp edges from the shared image).
        glyphNode.geometry?.firstMaterial?.multiply.contents = color
        refreshLabelLayout()
    }

    /// Point the nose along a screen-space direction (radians clockwise from
    /// screen-up). The billboard keeps the glyph's plane facing the camera, so
    /// an in-plane z-rotation maps directly onto screen angle.
    func setGlyphScreenAngle(_ radians: Float) {
        glyphNode.eulerAngles.z = -radians
    }

    /// Append the destination airport code to the label once the route resolves.
    func setRouteDestination(_ code: String?) {
        guard code != destinationCode else { return }
        destinationCode = code
        refreshLabelLayout()
    }

    /// Recompute the label text and size the backing plate to fit.
    private func refreshLabelLayout() {
        guard let aircraft = lastAircraft, let text = labelNode.geometry as? SCNText else { return }
        text.string = labelString(for: aircraft)
        let (minB, maxB) = text.boundingBox
        let width = (maxB.x - minB.x) * 0.6
        labelNode.position = SCNVector3(-width / 2, -14, 0.1)
        if let plate = plateNode.geometry as? SCNPlane {
            plate.width = CGFloat(width) + 3
        }
    }

    func setLabelVisible(_ visible: Bool) {
        labelNode.isHidden = !visible
        plateNode.isHidden = !visible
    }

    func setSelected(_ selected: Bool) {
        haloNode.isHidden = !selected
        let scale = selected ? baseScale * 1.6 : baseScale
        let action = SCNAction.scale(to: CGFloat(scale), duration: 0.18)
        action.timingMode = .easeOut
        glyphNode.runAction(action)
        renderingOrder = selected ? 10 : 0
    }

    /// Cool (high) to warm (low), matching the projector original's altitude grade.
    static func altitudeColor(feet: Double, onGround: Bool) -> UIColor {
        if onGround { return UIColor(white: 0.6, alpha: 1) }
        let t = max(0, min(1, feet / 40_000))      // 0 = ground, 1 = ~40k ft
        let hue = CGFloat(0.08 + t * (0.55 - 0.08)) // warm orange (low) -> cool cyan (high)
        return UIColor(hue: hue, saturation: 0.85, brightness: 1.0, alpha: 1.0)
    }
}

// =============================================================================
// MARK: - TODOs (milestone roadmap)
//
// M3 — Sky layer (SwiftAA):
//   • Sun, Moon (with phase), bright stars + constellation lines for observer
//     lat/lon and current time, placed with SkyMath.scenePosition(...).
//   • Bundle Yale BSC5 bright-star catalog; stars as constant-shaded points,
//     constellations as faint line strips. Add `skyTimeOffsetMin` time-scrub.
//
// M4 — ISS / satellites (SatelliteKit):
//   • Fetch TLEs from Celestrak, SGP4-propagate to "now", convert ECI -> lat/lon/
//     alt, feed SkyMath.azElRange like an aircraft. Add "next ISS pass" jump.
//
// M5 — Parity polish:
//   • Comet trails: keep last N positions per hex -> fading line-strip SCNGeometry.
//   • Type-aware glyphs per GlyphCategory (spin rotors/props; widebodies larger).
//   • Window-to-elsewhere: destination city, local time there, miles-to-go, faint
//     great-circle arc toward destination bearing (route via adsbdb, cached).
//   • Airport: local runway geometry from OurAirports at true position; config-
//     driven (DXB/DWC default), not a constant.
// =============================================================================
