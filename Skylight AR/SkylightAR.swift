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
import CoreMotion
import AVFoundation
import SatelliteKit
import simd

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
    var positionAgeSec: Double?   // feed's "seen_pos": seconds since this fix
    var category: String?      // ADS-B emitter category, e.g. "A3"
    var type: String?          // ICAO type designator ("t"), e.g. "B738"

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
    let seen_pos: Double?
    let category: String?
    let t: String?
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
        self.positionAgeSec = a.seen_pos
        self.category = a.category
        self.type = a.t
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
    static let showAirports      = "showAirports"       // Bool
    static let showTrails        = "showTrails"         // Bool
    static let soundOn           = "soundOn"            // Bool
    static let lastLat           = "lastLat"            // Double (for Siri)
    static let lastLon           = "lastLon"            // Double
    static let favorites         = "favoriteCallsigns"  // [String]
    static let statSpots         = "statFlightsSpotted" // Int
    static let statDays          = "statDaysUsed"       // Int
    static let lastUsedDay       = "lastUsedDay"        // TimeInterval
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
    private let pollInterval: Duration = .seconds(1)
    private let staleAfter: TimeInterval = 15   // drop aircraft not seen for this long
    private let searchRadiusNm = 80

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
    private var selectedHex: String?
    private var pollTask: Task<Void, Never>?
    private var airportNodes: [String: AirportNode] = [:]
    private var spottedThisSession: Set<String> = []
    private var poorCompassSince: Date?
    private let flightActivity = FlightActivityController()
    private let skyAudio = SkyAudioEngine()
    private let motionManager = CMMotionManager()

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
        startSession(reset: true)
        applyBackground()      // routes to IMU pointing when in dark-sky mode
        startPolling()
        Task { await fetchISSTLE() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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

    private func setUpGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        sceneView.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        sceneView.addGestureRecognizer(pinch)
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

    /// Live camera (true AR) when enabled and authorized; otherwise the dark
    /// low-power sky — and "low power" is now real: the AR session (camera +
    /// SLAM) stops entirely and the IMU alone drives where you're pointing.
    func applyBackground() {
        let wantCamera = engine?.cameraPassthrough ?? true
        let cameraOK = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let showCamera = wantCamera && cameraOK
        darkDomeNode.isHidden = showCamera
        guard ARWorldTrackingConfiguration.isSupported else {
            // Simulator: no session ever runs, so the background is ours to set.
            sceneView.scene.background.contents = UIColor.black
            return
        }
        if showCamera {
            stopMotionPointing()
            if isViewLoaded, view.window != nil { startSession() }
            // The pointing frame changed; re-estimate north from the compass.
            appliedNorthAccuracy = .infinity
        } else {
            sceneView.session.pause()
            startMotionPointing()
        }
    }

    // MARK: IMU pointing (dark-sky mode)

    private func startMotionPointing() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        // ARKit hasn't necessarily configured this camera (entering dark mode
        // directly pauses the session before its first frame) — the default
        // zFar of 100 clips the whole 1000 m sky dome out of existence.
        if let camera = sceneView.pointOfView?.camera {
            camera.zNear = 0.1
            camera.zFar = 1500
        }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        // CoreMotion reference: Z up. SceneKit world: Y up.
        let refToWorld = simd_quatf(angle: -.pi / 2, axis: simd_float3(1, 0, 0))
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self, let q = motion?.attitude.quaternion,
                  let pov = self.sceneView.pointOfView else { return }
            let dq = simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))
            pov.simdOrientation = refToWorld * dq
        }
        // Fresh arbitrary-yaw frame → realign to north from the next heading.
        appliedNorthAccuracy = .infinity
    }

    private func stopMotionPointing() {
        if motionManager.isDeviceMotionActive { motionManager.stopDeviceMotionUpdates() }
    }

    /// Inward-facing black sphere between the camera and the sky content —
    /// draws over the camera feed but never occludes content (no depth I/O).
    private lazy var darkDomeNode: SCNNode = {
        let sphere = SCNSphere(radius: 50)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.black
        mat.cullMode = .front                      // render the inside faces
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        sphere.materials = [mat]
        let node = SCNNode(geometry: sphere)
        node.renderingOrder = -100                 // before everything else
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
        // Don't trust the default video format: iOS 27.0 ships a 10 fps default
        // ("frame rate set to 10.0 by user defaults") that makes the feed feel
        // frozen. Pin the first ≥30 fps format (Apple lists best-first).
        if let smooth = ARWorldTrackingConfiguration.supportedVideoFormats
            .first(where: { $0.framesPerSecond >= 30 }) {
            config.videoFormat = smooth
        }
        sceneView.session.run(config, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
        if reset {
            // The scene frame was reset; realign to north from the next heading.
            appliedNorthAccuracy = .infinity
            worldNode.eulerAngles.y = 0
        }
    }

    private func pauseEverything() {
        sceneView.session.pause()
        stopMotionPointing()
        pollTask?.cancel()
        pollTask = nil
    }

    @objc private func appDidBackground() { pauseEverything() }
    @objc private func appDidBecomeActive() {
        guard viewIfLoaded?.window != nil else { return }
        applyBackground()      // resumes AR or IMU pointing per current mode
        startPolling()
    }

    // MARK: Polling

    private func startPolling() {
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
        let obsAltM = observer.altitude
        let offset = engine?.headingOffsetDeg ?? 0
        let mirror = engine?.mirrorX ?? false
        var visible = 0

        for ac in traffic {
            // Ground traffic is hidden unless explicitly enabled.
            if ac.onGround, engine?.showGroundAircraft != true { continue }
            // Render-time dead reckoning: the feed position is seen_pos +
            // network seconds old; project it forward along the track so the
            // glyph shows where the plane *is*, not where it was (FR24-style).
            var lat = ac.lat, lon = ac.lon
            if let track = ac.track, let gs = ac.groundSpeedKts, gs > 40, !ac.onGround {
                let age = min((ac.positionAgeSec ?? 1) + 2.0, 15)   // + feed/poll latency
                let meters = gs * 0.514444 * age
                let trackRad = track * .pi / 180
                lat += (meters * cos(trackRad) / 6_371_000) * 180 / .pi
                lon += (meters * sin(trackRad) / (6_371_000 * cos(ac.lat * .pi / 180))) * 180 / .pi
            }
            let (az, el, range) = SkyMath.azElRange(
                observerLat: observer.coordinate.latitude,
                observerLon: observer.coordinate.longitude,
                observerAltM: obsAltM,
                targetLat: lat, targetLon: lon, targetAltM: ac.altitudeMeters)

            // Only render objects above the horizon.
            guard el > -2 else { continue }
            visible += 1
            lastSeen[ac.hex] = now
            lastFix[ac.hex] = Fix(az: az, el: el, range: range, aircraft: ac)

            let position = SkyMath.scenePosition(
                azimuthDeg: az, elevationDeg: el, radius: sphereRadius,
                headingOffsetDeg: offset, mirrorX: mirror)

            let node: AircraftNode
            if let existing = nodes[ac.hex] {
                node = existing
                node.apply(aircraft: ac)
                orientGlyph(node, target: position, track: ac.track, az: az, el: el)
                // Smoothly glide between ~1 Hz fixes instead of teleporting.
                let move = SCNAction.move(to: position, duration: 1.0)
                move.timingMode = .easeInEaseOut
                node.runAction(move, forKey: "move")
            } else {
                node = AircraftNode(aircraft: ac)
                node.apply(aircraft: ac)
                node.position = position
                nodes[ac.hex] = node
                worldNode.addChildNode(node)
                orientGlyph(node, target: position, track: ac.track, az: az, el: el)
            }
            node.isHidden = !(engine?.showAircraft ?? true)

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

            updateTrail(hex: ac.hex, position: position, aircraft: ac)
        }

        removeStale(now: now)
        engine?.trafficCount = visible
        refreshSelection()
        applyFocus()
        updateTransitPrediction(traffic: traffic, observer: observer)
        updateAudio()
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
        let date = effectiveDate()
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
    private func orientGlyph(_ node: AircraftNode, target: SCNVector3,
                             track: Double?, az: Double, el: Double) {
        let fromWorld = node.presentation.worldPosition
        let toWorld = worldNode.convertPosition(target, to: nil)
        let p1 = sceneView.projectPoint(fromWorld)
        let p2 = sceneView.projectPoint(toWorld)
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y                        // view coords: y grows downward
        if p1.z > 0, p1.z < 1, dx * dx + dy * dy > 9 {
            node.setGlyphScreenAngle(atan2(dx, -dy))
        } else if let track {
            // Screen motion ≈ (sinΔ, −cosΔ·sinE) for a target at elevation E
            // moving with course Δ relative to its bearing from the observer.
            let delta = (track - az) * .pi / 180
            let elRad = max(el, 2) * .pi / 180
            node.setGlyphScreenAngle(Float(atan2(sin(delta), -cos(delta) * sin(elRad))))
        }
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
        let onScreen = !behind
            && projected.x >= 0 && CGFloat(projected.x) <= bounds.width
            && projected.y >= 0 && CGFloat(projected.y) <= bounds.height
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
            nodes[hex]?.removeFromParentNode()
            nodes[hex] = nil
            lastSeen[hex] = nil
            lastFix[hex] = nil
            trailNodes[hex]?.removeFromParentNode()
            trailNodes[hex] = nil
            trails[hex] = nil
            if hex == selectedHex { deselect() }
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
            let pos = SkyMath.scenePosition(azimuthDeg: fix.az, elevationDeg: fix.el,
                                            radius: sphereRadius,
                                            headingOffsetDeg: offset, mirrorX: mirror)
            node.removeAction(forKey: "move")
            let move = SCNAction.move(to: pos, duration: 0.25)
            move.timingMode = .easeOut
            node.runAction(move, forKey: "calibrate")
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
        for node in nodes.values {
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
        if spottedThisSession.insert(hex).inserted { engine?.recordSpot() }
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
            airline: route?.airline,
            origin: route?.originCode,
            originCity: route?.originCity,
            destination: route?.destinationCode,
            destinationCity: route?.destinationCity,
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

    func applyLayerVisibility() {
        let showAircraft = engine?.showAircraft ?? true
        let showGround = engine?.showGroundAircraft ?? false
        for (hex, node) in nodes {
            let grounded = lastFix[hex]?.aircraft.onGround == true
            node.isHidden = !showAircraft || (grounded && !showGround)
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

    private func fetchISSTLE() async {
        guard sky?.issSatellite == nil,
              let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=tle"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 3, let sat = try? Satellite(lines[0], lines[1], lines[2]) else { return }
        sky?.issSatellite = sat
    }

    /// Scrub the sky clock forward to the ISS's next rise above ~10°.
    func jumpToNextISSPass() {
        guard let here = observerLocation, let sat = sky?.issSatellite else { return }
        let lat = here.coordinate.latitude, lon = here.coordinate.longitude
        let start = Date()
        var minutes = 0.5
        while minutes < 60 * 24 {                       // search up to 24 h ahead
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
        Task { @MainActor in self.applyBackground() }
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
            engine?.loadEventsIfNeeded(lat: loc.coordinate.latitude,
                                       lon: loc.coordinate.longitude)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        engine?.headingAccuracyDeg = newHeading.headingAccuracy
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
        guard heading.trueHeading >= 0, heading.headingAccuracy >= 0,
              heading.headingAccuracy <= 30,
              let pov = sceneView.pointOfView else { return }
        let f = pov.presentation.simdWorldFront
        // Camera's horizontal yaw in the content convention (0 = −Z, 90° = +X).
        let yawCamDeg = atan2(Double(f.x), Double(-f.z)) * 180 / .pi
        let desired = (heading.trueHeading - yawCamDeg) * .pi / 180

        if appliedNorthAccuracy == .infinity {
            // First lock: one smooth snap.
            appliedNorthAccuracy = heading.headingAccuracy
            let rotate = SCNAction.rotateTo(x: 0, y: CGFloat(desired), z: 0,
                                            duration: 0.6, usesShortestUnitArc: true)
            rotate.timingMode = .easeInEaseOut
            worldNode.runAction(rotate)
            return
        }

        var error = (desired - Double(worldNode.eulerAngles.y))
            .truncatingRemainder(dividingBy: 2 * .pi)
        if error > .pi { error -= 2 * .pi }
        if error < -.pi { error += 2 * .pi }
        // Deadband keeps the sky calm; gain scales with compass confidence.
        guard abs(error) > 1.5 * .pi / 180 else { return }
        let gain = min(0.05, max(0.01, 0.02 * (25 / max(heading.headingAccuracy, 5))))
        worldNode.eulerAngles.y += Float(error * gain)
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

    private func buildGlyph(for aircraft: Aircraft) {
        // Top-view airliner silhouette (nose up): fuselage, swept wings, tailplane.
        // A vector shape keeps the altitude-graded material colorable and crisp.
        let k: CGFloat = 0.62
        let right: [CGPoint] = [
            CGPoint(x: 0.0, y: 10.0),     // nose tip
            CGPoint(x: 1.1, y: 8.2),      // nose shoulder
            CGPoint(x: 1.1, y: 2.2),      // wing root, leading edge
            CGPoint(x: 8.6, y: -1.6),     // wing tip, leading edge (swept)
            CGPoint(x: 8.6, y: -2.8),     // wing tip chord
            CGPoint(x: 1.1, y: -1.0),     // wing root, trailing edge
            CGPoint(x: 0.9, y: -6.0),     // rear fuselage
            CGPoint(x: 3.6, y: -7.8),     // tailplane tip, leading edge
            CGPoint(x: 3.6, y: -8.7),     // tailplane tip chord
            CGPoint(x: 0.9, y: -8.4),     // tailplane root, trailing edge
            CGPoint(x: 0.0, y: -9.0),     // tail cone
        ]
        let path = UIBezierPath()
        path.move(to: CGPoint(x: right[0].x * k, y: right[0].y * k))
        for p in right.dropFirst() { path.addLine(to: CGPoint(x: p.x * k, y: p.y * k)) }
        for p in right.reversed().dropFirst() { path.addLine(to: CGPoint(x: -p.x * k, y: p.y * k)) }
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 0)
        let mat = SCNMaterial()
        mat.lightingModel = .constant     // unaffected by scene lighting; reads on bright sky
        mat.isDoubleSided = true
        shape.materials = [mat]
        glyphNode.geometry = shape
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
        glyphNode.geometry?.firstMaterial?.diffuse.contents = color
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
