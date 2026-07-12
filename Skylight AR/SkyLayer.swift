//
//  SkyLayer.swift
//  Skylight AR
//
//  The celestial layer: sun, moon (with phase), bright stars + constellation
//  lines (SwiftAA / bundled catalog), and the ISS (SatelliteKit). Everything is
//  reduced to azimuth/elevation and placed on the same sky sphere as aircraft,
//  through SkyMath.scenePosition so the calibration knobs apply uniformly.
//

import Foundation
import SceneKit
import UIKit
import SwiftAA
import SatelliteKit

// MARK: - Bundled bright-star catalog

struct CatalogStar: Decodable { let ra: Double; let dec: Double; let mag: Double }

final class StarCatalog {
    static let shared = StarCatalog()
    let stars: [CatalogStar]
    let lines: [[[Double]]]   // polylines of [ra, dec] (degrees, J2000)

    /// The famous bright stars, labeled by name in the sky (J2000 degrees).
    static let namedStars: [(name: String, ra: Double, dec: Double)] = [
        ("Sirius", 101.287, -16.716), ("Canopus", 95.988, -52.696),
        ("Arcturus", 213.915, 19.182), ("Vega", 279.234, 38.784),
        ("Capella", 79.172, 45.998), ("Rigel", 78.634, -8.202),
        ("Procyon", 114.825, 5.225), ("Betelgeuse", 88.793, 7.407),
        ("Altair", 297.696, 8.868), ("Aldebaran", 68.980, 16.509),
        ("Antares", 247.352, -26.432), ("Spica", 201.298, -11.161),
        ("Pollux", 116.329, 28.026), ("Fomalhaut", 344.413, -29.622),
        ("Deneb", 310.358, 45.280), ("Regulus", 152.093, 11.967),
        ("Polaris", 37.954, 89.264), ("Castor", 113.650, 31.888),
        ("Achernar", 24.429, -57.237),
    ]

    private init() {
        stars = StarCatalog.decode("stars", as: [CatalogStar].self) ?? []
        lines = StarCatalog.decode("constellations", as: [[[Double]]].self) ?? []
    }

    private static func decode<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Procedural Milky Way

/// A generated Milky Way: a dense cloud of faint points hugging the galactic
/// plane, thickest toward the galactic centre (Sagittarius). Pure pinpoint
/// grain — soft glow billboards were tried and read as clouds, not galaxy.
/// Seeded RNG makes the cloud identical on every launch and rebuild, and the
/// points live in real RA/Dec — the band rises, sets, and arcs like the sky.
enum MilkyWay {
    static let cloud: [CatalogStar] = generated

    /// Galactic (l, b) → J2000 equatorial (ra, dec), degrees.
    private static func galacticToEquatorial(l: Double, b: Double) -> (ra: Double, dec: Double) {
        let lr = l * .pi / 180, br = b * .pi / 180
        let gx = cos(br) * cos(lr), gy = cos(br) * sin(lr), gz = sin(br)
        // Transpose of the standard J2000 equatorial→galactic rotation.
        let x = -0.0548755604 * gx + 0.4941094279 * gy - 0.8676661490 * gz
        let y = -0.8734370902 * gx - 0.4448296300 * gy - 0.1980763734 * gz
        let z = -0.4838350155 * gx + 0.7469822445 * gy + 0.4559837762 * gz
        var ra = atan2(y, x) * 180 / .pi
        if ra < 0 { ra += 360 }
        return (ra, asin(max(-1, min(1, z))) * 180 / .pi)
    }

    private static let generated: [CatalogStar] = {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double {                       // xorshift64* — deterministic
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Double((state &* 2685821657736338717) >> 11) / Double(UInt64.max >> 11)
        }
        func gauss(_ sigma: Double) -> Double {      // Box–Muller
            let u = max(rnd(), 1e-9), v = rnd()
            return sigma * (-2 * Foundation.log(u)).squareRoot() * cos(2 * .pi * v)
        }

        var cloud: [CatalogStar] = []
        for _ in 0..<2600 {                          // the full band, all longitudes
            let eq = galacticToEquatorial(l: rnd() * 360, b: gauss(8))
            cloud.append(CatalogStar(ra: eq.ra, dec: eq.dec, mag: rnd()))
        }
        for _ in 0..<1100 {                          // dense bulge toward the centre
            let eq = galacticToEquatorial(l: gauss(45), b: gauss(5.5))
            cloud.append(CatalogStar(ra: eq.ra, dec: eq.dec, mag: rnd() * 0.7))
        }
        return cloud
    }()
}

// MARK: - Celestial computations

enum Celestial {
    /// Sun azimuth (from north) + elevation for the observer at `date`.
    nonisolated static func sun(date: Date, lat: Double, lon: Double) -> (az: Double, el: Double) {
        let geo = GeographicCoordinates(positivelyWestwardLongitude: Degree(-lon), latitude: Degree(lat))
        let h = Sun(julianDay: JulianDay(date)).makeHorizontalCoordinates(with: geo)
        return (h.northBasedAzimuth.value, h.altitude.value)
    }

    struct MoonState {
        var az: Double; var el: Double; var illumination: Double; var waxing: Bool
        /// Geocentric elevation (no parallax) — eclipse geometry needs the
        /// Earth-centred moon, not the observer-shifted one.
        var elGeocentric: Double = 0
        var parallaxDeg: Double = 0
    }

    struct PlanetFix { let name: String; let az: Double; let el: Double }

    /// Localized display names for the sky objects whose English names double
    /// as lookup keys (`starStyle`/`planetStyle`, node dictionaries, sort
    /// ranks). The keys stay English everywhere; only the rendered label —
    /// SCNText in the sky, the "Tonight" line in Events — goes through here.
    nonisolated static func localizedName(_ name: String) -> String {
        switch name {
        case "Mercury":    return String(localized: "Mercury")
        case "Venus":      return String(localized: "Venus")
        case "Mars":       return String(localized: "Mars")
        case "Jupiter":    return String(localized: "Jupiter")
        case "Saturn":     return String(localized: "Saturn")
        case "Sirius":     return String(localized: "Sirius")
        case "Canopus":    return String(localized: "Canopus")
        case "Arcturus":   return String(localized: "Arcturus")
        case "Vega":       return String(localized: "Vega")
        case "Capella":    return String(localized: "Capella")
        case "Rigel":      return String(localized: "Rigel")
        case "Procyon":    return String(localized: "Procyon")
        case "Betelgeuse": return String(localized: "Betelgeuse")
        case "Altair":     return String(localized: "Altair")
        case "Aldebaran":  return String(localized: "Aldebaran")
        case "Antares":    return String(localized: "Antares")
        case "Spica":      return String(localized: "Spica")
        case "Pollux":     return String(localized: "Pollux")
        case "Fomalhaut":  return String(localized: "Fomalhaut")
        case "Deneb":      return String(localized: "Deneb")
        case "Regulus":    return String(localized: "Regulus")
        case "Polaris":    return String(localized: "Polaris")
        case "Castor":     return String(localized: "Castor")
        case "Achernar":   return String(localized: "Achernar")
        default:           return name
        }
    }

    /// The five naked-eye planets at the observer's sky position.
    nonisolated static func planets(date: Date, lat: Double, lon: Double) -> [PlanetFix] {
        let geo = GeographicCoordinates(positivelyWestwardLongitude: Degree(-lon), latitude: Degree(lat))
        let jd = JulianDay(date)
        func fix(_ name: String, _ h: HorizontalCoordinates) -> PlanetFix {
            PlanetFix(name: name, az: h.northBasedAzimuth.value, el: h.altitude.value)
        }
        var out: [PlanetFix] = []
        out.append(fix("Mercury", Mercury(julianDay: jd).makeHorizontalCoordinates(with: geo)))
        out.append(fix("Venus", Venus(julianDay: jd).makeHorizontalCoordinates(with: geo)))
        out.append(fix("Mars", Mars(julianDay: jd).makeHorizontalCoordinates(with: geo)))
        out.append(fix("Jupiter", Jupiter(julianDay: jd).makeHorizontalCoordinates(with: geo)))
        out.append(fix("Saturn", Saturn(julianDay: jd).makeHorizontalCoordinates(with: geo)))
        return out
    }

    nonisolated static func moon(date: Date, lat: Double, lon: Double) -> MoonState {
        let geo = GeographicCoordinates(positivelyWestwardLongitude: Degree(-lon), latitude: Degree(lat))
        let jd = JulianDay(date)
        let moon = Moon(julianDay: jd)
        let h = moon.makeHorizontalCoordinates(with: geo)
        // SwiftAA's horizontal conversion is geocentric. The moon is close
        // enough that observer parallax depresses it by up to ~1° — two full
        // moon-widths — so correct the altitude topocentrically.
        let elGeo = h.altitude.value
        let parallax = moon.horizontalParallax.value
        let elTopo = elGeo - parallax * cos(elGeo * .pi / 180)
        let f0 = moon.illuminatedFraction()
        let f1 = Moon(julianDay: JulianDay(jd.value + 1.0 / 24.0)).illuminatedFraction()  // +1h
        return MoonState(az: h.northBasedAzimuth.value, el: elTopo,
                         illumination: f0, waxing: f1 >= f0,
                         elGeocentric: elGeo, parallaxDeg: parallax)
    }
}

// MARK: - Procedural sun / moon textures

enum SkyArt {
    static func sunImage(diameter: CGFloat = 128) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = CGPoint(x: diameter / 2, y: diameter / 2)
            let colors = [UIColor(red: 1, green: 0.95, blue: 0.8, alpha: 1).cgColor,
                          UIColor(red: 1, green: 0.85, blue: 0.4, alpha: 0.9).cgColor,
                          UIColor(red: 1, green: 0.7, blue: 0.2, alpha: 0).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: colors as CFArray, locations: [0, 0.45, 1])!
            ctx.cgContext.drawRadialGradient(g, startCenter: c, startRadius: 0,
                                             endCenter: c, endRadius: diameter / 2, options: [])
        }
    }

    /// A soft radial glow sprite for additive blending.
    static func glowImage(color: UIColor, diameter: CGFloat = 64) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = CGPoint(x: diameter / 2, y: diameter / 2)
            let colors = [color.withAlphaComponent(0.9).cgColor,
                          color.withAlphaComponent(0).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(g, startCenter: c, startRadius: 0,
                                             endCenter: c, endRadius: diameter / 2, options: [])
        }
    }

    /// White star sprite: soft core + four diffraction spikes. Shared by all
    /// bright stars; tinted per star through the material's multiply channel.
    static let starSprite: UIImage = {
        let d: CGFloat = 128
        let size = CGSize(width: d, height: d)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let c = CGPoint(x: d / 2, y: d / 2)
            // Spikes first, blurred into soft rays.
            cg.setShadow(offset: .zero, blur: 5, color: UIColor.white.withAlphaComponent(0.8).cgColor)
            UIColor.white.withAlphaComponent(0.5).setFill()
            cg.fill(CGRect(x: d * 0.06, y: c.y - 0.9, width: d * 0.88, height: 1.8))
            cg.fill(CGRect(x: c.x - 0.9, y: d * 0.06, width: 1.8, height: d * 0.88))
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            // Hot core over a wide soft bloom.
            let colors = [UIColor.white.cgColor,
                          UIColor.white.withAlphaComponent(0.55).cgColor,
                          UIColor.white.withAlphaComponent(0).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: colors as CFArray, locations: [0, 0.16, 1])!
            cg.drawRadialGradient(g, startCenter: c, startRadius: 0,
                                  endCenter: c, endRadius: d / 2, options: [])
        }
    }()

    /// Meteor trail: bright at the head (+x), fading to nothing at the tail.
    static let meteorStreak: UIImage = {
        let size = CGSize(width: 256, height: 16)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor.white.withAlphaComponent(0).cgColor,
                          UIColor(red: 0.75, green: 0.85, blue: 1.0, alpha: 0.5).cgColor,
                          UIColor.white.cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: colors as CFArray, locations: [0, 0.75, 1])!
            cg.clip(to: CGRect(x: 0, y: 5, width: 256, height: 6))
            cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 256, y: 0), options: [])
        }
    }()

    /// A moon disc lit to `fraction` (0…1); `waxing` lights the right limb.
    static func moonImage(fraction: Double, waxing: Bool, diameter: CGFloat = 128) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let f = max(0, min(1, fraction))
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let r = diameter / 2
            let center = CGPoint(x: r, y: r)
            // Unlit base disc.
            cg.setFillColor(UIColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
            // Lit region bounded by the bright limb (semicircle) + terminator (ellipse).
            let path = UIBezierPath()
            let n = 48
            let rx = r * CGFloat(1 - 2 * f)              // terminator horizontal radius (signed)
            let sign: CGFloat = waxing ? 1 : -1
            for i in 0...n {                               // bright limb, top -> bottom
                let phi = CGFloat.pi * CGFloat(i) / CGFloat(n)
                let p = CGPoint(x: center.x + sign * r * sin(phi), y: center.y - r * cos(phi))
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            for i in 0...n {                               // terminator, bottom -> top
                let phi = CGFloat.pi * CGFloat(n - i) / CGFloat(n)
                let p = CGPoint(x: center.x + sign * rx * sin(phi), y: center.y - r * cos(phi))
                path.addLine(to: p)
            }
            path.close()
            UIColor(red: 0.96, green: 0.96, blue: 0.91, alpha: 1).setFill()
            path.fill()
        }
    }
}

// MARK: - Sky scene (nodes attached to the AR scene root)

@MainActor
final class SkyScene {
    private let root: SCNNode
    private weak var engine: SkyEngine?
    private let radius: Double

    private let sunNode = SCNNode()
    private let moonNode = SCNNode()
    private let starsRoot = SCNNode()
    private let starNamesNode = SCNNode()
    private let constellationsNode = SCNNode()
    private let issNode = SCNNode()
    private let planetsNode = SCNNode()
    private var planetNodes: [String: SCNNode] = [:]
    private let milkyWayNode = SCNNode()
    private let starSpritesNode = SCNNode()
    private var starSpriteNodes: [String: SCNNode] = [:]
    private let meteorLayer = SCNNode()
    private var lastOffset = 0.0
    private var lastMirror = false
    private var lastLat = 0.0
    private var lastLon = 0.0

    /// Real spectral tints for the named bright stars — Betelgeuse burns
    /// orange, Rigel blue-white — plus a glow size for the very brightest.
    private static let starStyle: [String: (color: UIColor, size: CGFloat)] = [
        "Sirius":     (UIColor(red: 0.85, green: 0.90, blue: 1.00, alpha: 1), 26),
        "Canopus":    (UIColor(red: 0.97, green: 0.97, blue: 0.94, alpha: 1), 23),
        "Arcturus":   (UIColor(red: 1.00, green: 0.82, blue: 0.60, alpha: 1), 23),
        "Vega":       (UIColor(red: 0.80, green: 0.87, blue: 1.00, alpha: 1), 23),
        "Capella":    (UIColor(red: 1.00, green: 0.94, blue: 0.78, alpha: 1), 22),
        "Rigel":      (UIColor(red: 0.75, green: 0.83, blue: 1.00, alpha: 1), 22),
        "Procyon":    (UIColor(red: 0.98, green: 0.97, blue: 0.90, alpha: 1), 20),
        "Betelgeuse": (UIColor(red: 1.00, green: 0.65, blue: 0.40, alpha: 1), 22),
        "Altair":     (UIColor(red: 0.92, green: 0.95, blue: 1.00, alpha: 1), 20),
        "Aldebaran":  (UIColor(red: 1.00, green: 0.75, blue: 0.55, alpha: 1), 20),
        "Antares":    (UIColor(red: 1.00, green: 0.60, blue: 0.40, alpha: 1), 21),
        "Spica":      (UIColor(red: 0.72, green: 0.80, blue: 1.00, alpha: 1), 20),
        "Pollux":     (UIColor(red: 1.00, green: 0.88, blue: 0.70, alpha: 1), 19),
        "Fomalhaut":  (UIColor(red: 0.88, green: 0.92, blue: 1.00, alpha: 1), 19),
        "Deneb":      (UIColor(red: 0.90, green: 0.94, blue: 1.00, alpha: 1), 20),
        "Regulus":    (UIColor(red: 0.78, green: 0.85, blue: 1.00, alpha: 1), 19),
        "Polaris":    (UIColor(red: 1.00, green: 0.95, blue: 0.85, alpha: 1), 18),
        "Castor":     (UIColor(red: 0.88, green: 0.92, blue: 1.00, alpha: 1), 18),
        "Achernar":   (UIColor(red: 0.75, green: 0.85, blue: 1.00, alpha: 1), 19),
    ]

    /// Tinted glyph sizes per planet — Venus dominates, as in the real sky.
    private static let planetStyle: [String: (size: CGFloat, color: UIColor)] = [
        "Mercury": (7, UIColor(red: 0.78, green: 0.72, blue: 0.66, alpha: 1)),
        "Venus":   (12, UIColor(red: 1.00, green: 0.97, blue: 0.88, alpha: 1)),
        "Mars":    (8, UIColor(red: 1.00, green: 0.62, blue: 0.44, alpha: 1)),
        "Jupiter": (11, UIColor(red: 0.98, green: 0.92, blue: 0.80, alpha: 1)),
        "Saturn":  (9, UIColor(red: 0.95, green: 0.88, blue: 0.66, alpha: 1)),
    ]

    /// Set by the controller once the TLE is fetched.
    var issSatellite: Satellite?

    private var lastStarBuild = Date.distantPast
    private var lastMoonFraction = -1.0
    private var lastMoonWaxing = true
    private var starNameNodes: [String: SCNNode] = [:]
    private var starsBuilding = false

    init(root: SCNNode, engine: SkyEngine?, radius: Double) {
        self.root = root
        self.engine = engine
        self.radius = radius
        buildStaticNodes()
    }

    private func buildStaticNodes() {
        // Sun, wrapped in a wide warm halo — the atmosphere's glare.
        let sunPlane = SCNPlane(width: 70, height: 70)
        sunPlane.firstMaterial?.lightingModel = .constant
        sunPlane.firstMaterial?.diffuse.contents = SkyArt.sunImage()
        sunPlane.firstMaterial?.isDoubleSided = true
        sunNode.geometry = sunPlane
        sunNode.addChildNode(Self.haloNode(
            color: UIColor(red: 1.0, green: 0.85, blue: 0.55, alpha: 1), size: 190, opacity: 0.32))
        sunNode.constraints = [SCNBillboardConstraint()]
        sunNode.isHidden = true
        root.addChildNode(sunNode)

        // Moon, with a cool halo — moonlight scattered through thin air.
        let moonPlane = SCNPlane(width: 44, height: 44)
        moonPlane.firstMaterial?.lightingModel = .constant
        moonPlane.firstMaterial?.isDoubleSided = true
        moonNode.geometry = moonPlane
        moonNode.addChildNode(Self.haloNode(
            color: UIColor(red: 0.80, green: 0.87, blue: 1.0, alpha: 1), size: 115, opacity: 0.28))
        moonNode.constraints = [SCNBillboardConstraint()]
        moonNode.isHidden = true
        root.addChildNode(moonNode)

        // ISS marker: a bright cyan diamond + label.
        buildISSNode()
        root.addChildNode(issNode)
        root.addChildNode(milkyWayNode)
        root.addChildNode(starsRoot)
        root.addChildNode(starSpritesNode)
        root.addChildNode(starNamesNode)
        root.addChildNode(constellationsNode)
        buildPlanetNodes()
        root.addChildNode(planetsNode)
        buildStarNameNodes()
        buildStarSpriteNodes()

        // Meteors, at honest rates: each tick rolls against the real activity
        // level (shower ZHR near its peak, else the rare sporadic background).
        // The action pauses with the scene and stops for Reduce Motion.
        root.addChildNode(meteorLayer)
        if !UIAccessibility.isReduceMotionEnabled {
            let loop = SCNAction.repeatForever(.sequence([
                .wait(duration: 25, withRange: 15),
                .run { [weak self] _ in
                    DispatchQueue.main.async { self?.spawnMeteor() }
                },
            ]))
            meteorLayer.runAction(loop)
        }
    }

    /// A soft additive glow billboard used as an atmospheric halo.
    private static func haloNode(color: UIColor, size: CGFloat, opacity: CGFloat) -> SCNNode {
        let plane = SCNPlane(width: size, height: size)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = SkyArt.glowImage(color: color, diameter: 128)
        mat.blendMode = .add
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        node.opacity = opacity
        node.position.z = -2          // just behind the disc it wraps
        return node
    }

    /// Glow sprites for the famous stars: spectral colour, diffraction spikes,
    /// and a slow twinkle with a random phase per star.
    private func buildStarSpriteNodes() {
        for star in StarCatalog.namedStars {
            let style = Self.starStyle[star.name] ?? (UIColor.white, 18)
            let plane = SCNPlane(width: style.size, height: style.size)
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = SkyArt.starSprite
            mat.multiply.contents = style.color
            mat.blendMode = .add
            mat.isDoubleSided = true
            mat.writesToDepthBuffer = false
            plane.materials = [mat]
            let node = SCNNode(geometry: plane)
            node.constraints = [SCNBillboardConstraint()]
            node.isHidden = true
            if !UIAccessibility.isReduceMotionEnabled {
                let period = Double.random(in: 1.6...3.4)
                let dim = SCNAction.fadeOpacity(to: 0.68, duration: period)
                dim.timingMode = .easeInEaseOut
                let brighten = SCNAction.fadeOpacity(to: 1.0, duration: period)
                brighten.timingMode = .easeInEaseOut
                node.runAction(.sequence([
                    .wait(duration: Double.random(in: 0...2)),
                    .repeatForever(.sequence([dim, brighten])),
                ]))
            }
            starSpriteNodes[star.name] = node
            starSpritesNode.addChildNode(node)
        }
    }

    /// Name labels are created once (SCNText is costly) and only repositioned.
    private func buildStarNameNodes() {
        for star in StarCatalog.namedStars {
            let text = SCNText(string: Celestial.localizedName(star.name), extrusionDepth: 0)
            text.font = .systemFont(ofSize: 7, weight: .semibold)
            text.flatness = 0.3
            let mat = SCNMaterial(); mat.lightingModel = .constant
            mat.diffuse.contents = UIColor(red: 0.85, green: 0.89, blue: 1.0, alpha: 0.85)
            text.materials = [mat]
            let label = SCNNode(geometry: text)
            label.scale = SCNVector3(0.7, 0.7, 0.7)
            let (minB, maxB) = text.boundingBox
            let holder = SCNNode()
            holder.constraints = [SCNBillboardConstraint()]
            label.position = SCNVector3(-(maxB.x - minB.x) * 0.35, 5, 0)
            holder.addChildNode(label)
            holder.isHidden = true
            starNameNodes[star.name] = holder
            starNamesNode.addChildNode(holder)
        }
    }

    private func buildPlanetNodes() {
        for (name, style) in Self.planetStyle {
            let holder = SCNNode()
            holder.constraints = [SCNBillboardConstraint()]

            let plane = SCNPlane(width: style.size, height: style.size)
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = SkyArt.glowImage(color: style.color)
            mat.blendMode = .add
            mat.isDoubleSided = true
            plane.materials = [mat]
            holder.addChildNode(SCNNode(geometry: plane))

            let text = SCNText(string: Celestial.localizedName(name), extrusionDepth: 0)
            text.font = .systemFont(ofSize: 7, weight: .semibold)
            text.flatness = 0.3
            let tmat = SCNMaterial(); tmat.lightingModel = .constant
            tmat.diffuse.contents = style.color.withAlphaComponent(0.9)
            text.materials = [tmat]
            let label = SCNNode(geometry: text)
            label.scale = SCNVector3(0.7, 0.7, 0.7)
            let (minB, maxB) = text.boundingBox
            let labelX: Float = -(maxB.x - minB.x) * 0.35
            let labelY: Float = Float(style.size) * 0.5 + 3
            label.position = SCNVector3(labelX, labelY, 0)
            holder.addChildNode(label)

            holder.isHidden = true
            planetNodes[name] = holder
            planetsNode.addChildNode(holder)
        }
    }

    private func buildISSNode() {
        // Soft cyan glow behind the marker so the station stands out from stars.
        let glowPlane = SCNPlane(width: 34, height: 34)
        let glowMat = SCNMaterial()
        glowMat.lightingModel = .constant
        glowMat.diffuse.contents = SkyArt.glowImage(
            color: UIColor(red: 0.45, green: 0.95, blue: 1.0, alpha: 1))
        glowMat.isDoubleSided = true
        glowMat.blendMode = .add
        glowMat.writesToDepthBuffer = false
        glowPlane.materials = [glowMat]
        let glow = SCNNode(geometry: glowPlane)
        issNode.addChildNode(glow)

        let plane = SCNPlane(width: 13, height: 13)
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor(red: 0.5, green: 1.0, blue: 1.0, alpha: 1)
        mat.isDoubleSided = true
        plane.materials = [mat]
        let glyph = SCNNode(geometry: plane)
        glyph.eulerAngles.z = .pi / 4                      // diamond
        issNode.addChildNode(glyph)

        // Calm breathing pulse — reads as "this one is alive/moving".
        if !UIAccessibility.isReduceMotionEnabled {
            let pulse = SCNAction.repeatForever(.sequence([
                .fadeOpacity(to: 0.55, duration: 1.2),
                .fadeOpacity(to: 1.0, duration: 1.2),
            ]))
            pulse.timingMode = .easeInEaseOut
            glow.runAction(pulse)
        }

        let text = SCNText(string: String(localized: "ISS"), extrusionDepth: 0)
        text.font = .systemFont(ofSize: 10, weight: .bold)
        text.flatness = 0.2
        let tmat = SCNMaterial(); tmat.lightingModel = .constant
        tmat.diffuse.contents = UIColor(red: 0.7, green: 1.0, blue: 1.0, alpha: 1)
        text.materials = [tmat]
        let label = SCNNode(geometry: text)
        label.scale = SCNVector3(0.7, 0.7, 0.7)
        let (minB, maxB) = text.boundingBox
        label.position = SCNVector3(-(maxB.x - minB.x) * 0.35, 11, 0)
        issNode.addChildNode(label)

        issNode.constraints = [SCNBillboardConstraint()]
        issNode.isHidden = true
    }

    // MARK: Tappable bodies

    /// Every celestial mark currently in the sky, for the tap handler's
    /// nearest-glyph search — same forgiving selection planes get.
    func tappableBodies() -> [(body: SelectedBody, node: SCNNode)] {
        var out: [(SelectedBody, SCNNode)] = []
        if !sunNode.isHidden { out.append((SelectedBody(kind: .sun, name: "Sun"), sunNode)) }
        if !moonNode.isHidden { out.append((SelectedBody(kind: .moon, name: "Moon"), moonNode)) }
        for (name, node) in planetNodes where !node.isHidden {
            out.append((SelectedBody(kind: .planet, name: name), node))
        }
        for (name, node) in starSpriteNodes where !node.isHidden {
            let cat = StarCatalog.namedStars.first { $0.name == name }
            out.append((SelectedBody(kind: .star, name: name,
                                     ra: cat?.ra ?? 0, dec: cat?.dec ?? 0), node))
        }
        if !issNode.isHidden { out.append((SelectedBody(kind: .iss, name: "ISS"), issNode)) }
        return out
    }

    // MARK: Update

    func update(date: Date, lat: Double, lon: Double, offset: Double, mirror: Bool, forceStars: Bool) {
        guard let engine else { return }
        lastOffset = offset
        lastMirror = mirror
        lastLat = lat
        lastLon = lon
        updateSun(date: date, lat: lat, lon: lon, offset: offset, mirror: mirror, show: engine.showSun)
        updateMoon(date: date, lat: lat, lon: lon, offset: offset, mirror: mirror, show: engine.showMoon)
        updateISS(date: date, lat: lat, lon: lon, offset: offset, mirror: mirror, show: engine.showISS)
        updatePlanets(date: date, lat: lat, lon: lon, offset: offset, mirror: mirror, show: engine.showPlanets)

        if engine.showStars {
            starsRoot.isHidden = false
            starSpritesNode.isHidden = false
            starNamesNode.isHidden = false
            constellationsNode.isHidden = false
            milkyWayNode.isHidden = !engine.showMilkyWay
            if forceStars || Date().timeIntervalSince(lastStarBuild) > 10 {
                buildStars(date: date, lat: lat, lon: lon, offset: offset, mirror: mirror)
                lastStarBuild = Date()
            }
        } else {
            starsRoot.isHidden = true
            starSpritesNode.isHidden = true
            starNamesNode.isHidden = true
            constellationsNode.isHidden = true
            milkyWayNode.isHidden = true
        }
    }

    func setVisibility() {
        guard let engine else { return }
        sunNode.isHidden = sunNode.isHidden || !engine.showSun
        // Visibility is fully recomputed on the next update(); just hide instantly here.
        if !engine.showSun { sunNode.isHidden = true }
        if !engine.showMoon { moonNode.isHidden = true }
        if !engine.showISS { issNode.isHidden = true }
        planetsNode.isHidden = !engine.showPlanets
        starsRoot.isHidden = !engine.showStars
        starSpritesNode.isHidden = !engine.showStars
        starNamesNode.isHidden = !engine.showStars
        constellationsNode.isHidden = !engine.showStars
        milkyWayNode.isHidden = !(engine.showStars && engine.showMilkyWay)
    }

    private func updatePlanets(date: Date, lat: Double, lon: Double, offset: Double, mirror: Bool, show: Bool) {
        guard show else { planetsNode.isHidden = true; return }
        planetsNode.isHidden = false
        for planet in Celestial.planets(date: date, lat: lat, lon: lon) {
            guard let node = planetNodes[planet.name] else { continue }
            guard planet.el > -1 else { node.isHidden = true; continue }
            node.position = SkyMath.scenePosition(azimuthDeg: planet.az, elevationDeg: planet.el,
                                                  radius: radius * 0.96,
                                                  headingOffsetDeg: offset, mirrorX: mirror)
            node.isHidden = false
        }
    }

    private func updateSun(date: Date, lat: Double, lon: Double, offset: Double, mirror: Bool, show: Bool) {
        guard show else { sunNode.isHidden = true; return }
        let s = Celestial.sun(date: date, lat: lat, lon: lon)
        guard s.el > -3 else { sunNode.isHidden = true; return }
        sunNode.position = SkyMath.scenePosition(azimuthDeg: s.az, elevationDeg: s.el,
                                                 radius: radius, headingOffsetDeg: offset, mirrorX: mirror)
        sunNode.isHidden = false
    }

    private func updateMoon(date: Date, lat: Double, lon: Double, offset: Double, mirror: Bool, show: Bool) {
        guard show else { moonNode.isHidden = true; return }
        let m = Celestial.moon(date: date, lat: lat, lon: lon)
        engine?.moonIllumination = m.illumination
        engine?.moonWaxing = m.waxing
        guard m.el > -3 else { moonNode.isHidden = true; return }
        if abs(m.illumination - lastMoonFraction) > 0.02 || m.waxing != lastMoonWaxing {
            moonNode.geometry?.firstMaterial?.diffuse.contents =
                SkyArt.moonImage(fraction: m.illumination, waxing: m.waxing)
            lastMoonFraction = m.illumination
            lastMoonWaxing = m.waxing
        }
        moonNode.position = SkyMath.scenePosition(azimuthDeg: m.az, elevationDeg: m.el,
                                                  radius: radius, headingOffsetDeg: offset, mirrorX: mirror)
        moonNode.isHidden = false
    }

    private func updateISS(date: Date, lat: Double, lon: Double, offset: Double, mirror: Bool, show: Bool) {
        guard show, let sat = issSatellite,
              let lla = try? sat.geoPosition(julianDays: SkyMath.julianDay(date)) else {
            issNode.isHidden = true; engine?.issVisible = false; return
        }
        let r = SkyMath.azElRange(observerLat: lat, observerLon: lon, observerAltM: 0,
                                  targetLat: lla.lat, targetLon: lla.lon, targetAltM: lla.alt * 1000)
        guard r.elevation > -2 else { issNode.isHidden = true; engine?.issVisible = false; return }
        issNode.position = SkyMath.scenePosition(azimuthDeg: r.azimuth, elevationDeg: r.elevation,
                                                 radius: radius, headingOffsetDeg: offset, mirrorX: mirror)
        issNode.isHidden = false
        engine?.issVisible = true
        // Star Sailor: the station genuinely overhead, at real time — a
        // scrubbed sky doesn't count. The store ignores repeats.
        if let engine, r.elevation > 10, engine.skyTimeOffsetMin == 0 {
            engine.medals.recordISSOverhead(totalSpots: engine.statFlightsSpotted)
        }
    }

    /// The 1,600-star trig sweep runs off the main thread; only the cheap
    /// geometry swap and label repositioning touch the render thread's frame.
    private func buildStars(date: Date, lat: Double, lon: Double, offset: Double, mirror: Bool) {
        guard !starsBuilding else { return }
        starsBuilding = true
        let stars = StarCatalog.shared.stars
        let lines = StarCatalog.shared.lines
        let named = StarCatalog.namedStars
        let cloud = MilkyWay.cloud
        let r = radius

        Task.detached(priority: .userInitiated) {
            var bright: [SCNVector3] = [], medium: [SCNVector3] = [], faint: [SCNVector3] = []
            for s in stars {
                let h = SkyMath.equatorialToHorizontal(raDeg: s.ra, decDeg: s.dec, latDeg: lat, lonDeg: lon, date: date)
                guard h.elevation > 0 else { continue }
                let p = SkyMath.scenePosition(azimuthDeg: h.azimuth, elevationDeg: h.elevation,
                                              radius: r * 0.98, headingOffsetDeg: offset, mirrorX: mirror)
                if s.mag < 1.5 { bright.append(p) } else if s.mag < 3.0 { medium.append(p) } else { faint.append(p) }
            }
            var segs: [SCNVector3] = []
            for line in lines {
                var prev: (SCNVector3, Bool)?
                for pt in line where pt.count == 2 {
                    let h = SkyMath.equatorialToHorizontal(raDeg: pt[0], decDeg: pt[1], latDeg: lat, lonDeg: lon, date: date)
                    let above = h.elevation > 0
                    let v = SkyMath.scenePosition(azimuthDeg: h.azimuth, elevationDeg: max(h.elevation, 0),
                                                  radius: r * 0.98, headingOffsetDeg: offset, mirrorX: mirror)
                    if let (pv, pAbove) = prev, pAbove && above { segs.append(pv); segs.append(v) }
                    prev = (v, above)
                }
            }
            var namePositions: [String: SCNVector3] = [:]
            var spritePositions: [String: SCNVector3] = [:]
            for star in named {
                let h = SkyMath.equatorialToHorizontal(raDeg: star.ra, decDeg: star.dec,
                                                       latDeg: lat, lonDeg: lon, date: date)
                guard h.elevation > 0.5 else { continue }
                spritePositions[star.name] = SkyMath.scenePosition(
                    azimuthDeg: h.azimuth, elevationDeg: h.elevation,
                    radius: r * 0.98, headingOffsetDeg: offset, mirrorX: mirror)
                guard h.elevation > 2 else { continue }
                namePositions[star.name] = SkyMath.scenePosition(
                    azimuthDeg: h.azimuth, elevationDeg: h.elevation,
                    radius: r * 0.97, headingOffsetDeg: offset, mirrorX: mirror)
            }
            // Milky Way cloud: three brightness tiers keyed off the baked-in
            // random weight, drawn slightly behind the catalog stars.
            var mwFaint: [SCNVector3] = [], mwMid: [SCNVector3] = [], mwBright: [SCNVector3] = []
            for s in cloud {
                let h = SkyMath.equatorialToHorizontal(raDeg: s.ra, decDeg: s.dec, latDeg: lat, lonDeg: lon, date: date)
                guard h.elevation > 0 else { continue }
                let p = SkyMath.scenePosition(azimuthDeg: h.azimuth, elevationDeg: h.elevation,
                                              radius: r * 0.995, headingOffsetDeg: offset, mirrorX: mirror)
                if s.mag < 0.5 { mwFaint.append(p) } else if s.mag < 0.85 { mwMid.append(p) } else { mwBright.append(p) }
            }
            // Immutable snapshots — the vars above can't cross into the
            // MainActor closure under Swift 6 isolation checking.
            let result = (bright: bright, medium: medium, faint: faint, segs: segs,
                          names: namePositions, sprites: spritePositions,
                          mwFaint: mwFaint, mwMid: mwMid, mwBright: mwBright)
            await MainActor.run { [weak self] in
                self?.applyStars(bright: result.bright, medium: result.medium, faint: result.faint,
                                 segs: result.segs, namePositions: result.names,
                                 spritePositions: result.sprites,
                                 mwFaint: result.mwFaint, mwMid: result.mwMid, mwBright: result.mwBright)
            }
        }
    }

    private func applyStars(bright: [SCNVector3], medium: [SCNVector3], faint: [SCNVector3],
                            segs: [SCNVector3], namePositions: [String: SCNVector3],
                            spritePositions: [String: SCNVector3],
                            mwFaint: [SCNVector3], mwMid: [SCNVector3], mwBright: [SCNVector3]) {
        starsRoot.childNodes.forEach { $0.removeFromParentNode() }
        starsRoot.addChildNode(SCNNode(geometry: pointGeometry(bright, size: 9, color: UIColor(white: 1, alpha: 1))))
        starsRoot.addChildNode(SCNNode(geometry: pointGeometry(medium, size: 6, color: UIColor(white: 0.95, alpha: 1))))
        starsRoot.addChildNode(SCNNode(geometry: pointGeometry(faint, size: 3.5, color: UIColor(white: 0.8, alpha: 1))))

        // The Milky Way's grain — additive, so overlaps genuinely brighten.
        milkyWayNode.childNodes.forEach { $0.removeFromParentNode() }
        milkyWayNode.addChildNode(SCNNode(geometry: pointGeometry(mwFaint, size: 2.2,
            color: UIColor(red: 0.58, green: 0.64, blue: 0.88, alpha: 0.30), additive: true)))
        milkyWayNode.addChildNode(SCNNode(geometry: pointGeometry(mwMid, size: 2.8,
            color: UIColor(red: 0.66, green: 0.72, blue: 0.95, alpha: 0.42), additive: true)))
        milkyWayNode.addChildNode(SCNNode(geometry: pointGeometry(mwBright, size: 3.4,
            color: UIColor(red: 0.78, green: 0.84, blue: 1.0, alpha: 0.55), additive: true)))

        for (name, node) in starSpriteNodes {
            if let p = spritePositions[name] {
                node.position = p
                node.isHidden = false
            } else {
                node.isHidden = true
            }
        }

        constellationsNode.childNodes.forEach { $0.removeFromParentNode() }
        if !segs.isEmpty {
            constellationsNode.addChildNode(SCNNode(geometry: lineGeometry(segs,
                color: UIColor(red: 0.50, green: 0.62, blue: 0.95, alpha: 0.62))))
        }

        for (name, node) in starNameNodes {
            if let position = namePositions[name] {
                node.position = position
                node.isHidden = false
            } else {
                node.isHidden = true
            }
        }
        starsBuilding = false
    }

    // MARK: Meteors

    /// One shooting star, honestly simulated: the odds of each spawn follow
    /// real meteor activity — a shower's ZHR ramping toward its peak night,
    /// or the sparse sporadic background the rest of the year — and during a
    /// shower the streak fans out of the shower's true radiant in this sky.
    /// (Individual meteors are unpredictable; the pattern is the real part.)
    private func spawnMeteor() {
        guard engine?.showStars == true else { return }
        let now = Date()
        let active = EventsCalendar.activeShower(on: now)

        // Sporadic background ≈ a few naked-eye meteors per hour; a strong
        // shower near peak fires on almost every tick.
        let chance = active.map { min(1.0, 0.1 + Double($0.shower.zhr) / 100 * $0.strength) } ?? 0.08
        guard Double.random(in: 0..<1) < chance else { return }

        var az0 = Double.random(in: 0..<360)
        var el0 = Double.random(in: 28...62)
        var azSpan = Double.random(in: 10...22) * (Bool.random() ? 1 : -1)
        var elSpan = Double.random(in: 8...16)

        // Shower meteors radiate from the radiant: appear some way out from
        // it and fly directly away, just like the real thing.
        if let active, lastLat != 0 || lastLon != 0 {
            let radiant = SkyMath.equatorialToHorizontal(raDeg: active.shower.raDeg,
                                                         decDeg: active.shower.decDeg,
                                                         latDeg: lastLat, lonDeg: lastLon, date: now)
            guard radiant.elevation > 3 else { return }   // radiant set: no shower meteors
            let bearing = Double.random(in: 0..<(2 * .pi))
            let fromRadiant = Double.random(in: 10...30)
            let length = Double.random(in: 10...20)
            el0 = radiant.elevation + cos(bearing) * fromRadiant
            guard el0 > 8, el0 < 80 else { return }
            let stretch = 1 / max(0.25, cos(el0 * .pi / 180))
            az0 = radiant.azimuth + sin(bearing) * fromRadiant * stretch
            elSpan = -cos(bearing) * length                // continue away from the radiant
            azSpan = sin(bearing) * length * stretch
        }

        let p0 = SkyMath.scenePosition(azimuthDeg: az0, elevationDeg: el0,
                                       radius: radius * 0.94, headingOffsetDeg: lastOffset, mirrorX: lastMirror)
        let p1 = SkyMath.scenePosition(azimuthDeg: az0 + azSpan, elevationDeg: el0 - elSpan,
                                       radius: radius * 0.94, headingOffsetDeg: lastOffset, mirrorX: lastMirror)
        let start = simd_float3(p0.x, p0.y, p0.z), end = simd_float3(p1.x, p1.y, p1.z)
        let span = end - start
        let length = simd_length(span)
        guard length > 1 else { return }
        let dir = span / length

        // Container basis: x along the flight path, z facing the observer.
        let z = -simd_normalize((start + end) / 2)
        let x = simd_normalize(dir - z * simd_dot(dir, z))
        let y = simd_cross(z, x)
        let container = SCNNode()
        container.simdTransform = simd_float4x4(columns: (simd_float4(x, 0), simd_float4(y, 0),
                                                          simd_float4(z, 0), simd_float4(start, 1)))
        container.opacity = 0

        let trailLength = CGFloat(length) * 0.85
        let trailPlane = SCNPlane(width: trailLength, height: 3.5)
        let trailMat = SCNMaterial()
        trailMat.lightingModel = .constant
        trailMat.diffuse.contents = SkyArt.meteorStreak
        trailMat.blendMode = .add
        trailMat.isDoubleSided = true
        trailMat.writesToDepthBuffer = false
        trailPlane.materials = [trailMat]
        let trail = SCNNode(geometry: trailPlane)
        // Pivot on the tail edge so scaling stretches the trail out of the
        // spawn point, chasing the head.
        trail.pivot = SCNMatrix4MakeTranslation(Float(-trailLength / 2), 0, 0)
        trail.scale = SCNVector3(0.01, 1, 1)
        container.addChildNode(trail)

        let headPlane = SCNPlane(width: 12, height: 12)
        let headMat = SCNMaterial()
        headMat.lightingModel = .constant
        headMat.diffuse.contents = SkyArt.glowImage(color: .white)
        headMat.blendMode = .add
        headMat.isDoubleSided = true
        headMat.writesToDepthBuffer = false
        headPlane.materials = [headMat]
        let head = SCNNode(geometry: headPlane)
        container.addChildNode(head)

        meteorLayer.addChildNode(container)

        let flight = 0.55
        head.runAction(.moveBy(x: CGFloat(length), y: 0, z: 0, duration: flight))
        trail.runAction(.customAction(duration: flight) { node, t in
            node.scale = SCNVector3(max(0.01, Float(t / flight)), 1, 1)
        })
        container.runAction(.sequence([
            .fadeIn(duration: 0.12),
            .wait(duration: flight - 0.12),
            .fadeOut(duration: 0.4),
            .removeFromParentNode(),
        ]))
    }

    private func pointGeometry(_ verts: [SCNVector3], size: CGFloat, color: UIColor,
                               additive: Bool = false) -> SCNGeometry {
        let src = SCNGeometrySource(vertices: verts)
        let element = SCNGeometryElement(indices: Array(Int32(0)..<Int32(verts.count)), primitiveType: .point)
        element.pointSize = size
        element.minimumPointScreenSpaceRadius = size * 0.4
        element.maximumPointScreenSpaceRadius = size
        let g = SCNGeometry(sources: [src], elements: [element])
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = color; m.isDoubleSided = true
        if additive {
            m.blendMode = .add
            m.writesToDepthBuffer = false
        }
        g.materials = [m]
        return g
    }

    private func lineGeometry(_ verts: [SCNVector3], color: UIColor) -> SCNGeometry {
        let src = SCNGeometrySource(vertices: verts)
        let element = SCNGeometryElement(indices: Array(Int32(0)..<Int32(verts.count)), primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [element])
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = color; m.isDoubleSided = true
        g.materials = [m]
        return g
    }
}
