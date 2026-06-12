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

// MARK: - Celestial computations

enum Celestial {
    /// Sun azimuth (from north) + elevation for the observer at `date`.
    nonisolated static func sun(date: Date, lat: Double, lon: Double) -> (az: Double, el: Double) {
        let geo = GeographicCoordinates(positivelyWestwardLongitude: Degree(-lon), latitude: Degree(lat))
        let h = Sun(julianDay: JulianDay(date)).makeHorizontalCoordinates(with: geo)
        return (h.northBasedAzimuth.value, h.altitude.value)
    }

    struct MoonState { var az: Double; var el: Double; var illumination: Double; var waxing: Bool }

    struct PlanetFix { let name: String; let az: Double; let el: Double }

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
                         illumination: f0, waxing: f1 >= f0)
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
        // Sun
        let sunPlane = SCNPlane(width: 70, height: 70)
        sunPlane.firstMaterial?.lightingModel = .constant
        sunPlane.firstMaterial?.diffuse.contents = SkyArt.sunImage()
        sunPlane.firstMaterial?.isDoubleSided = true
        sunNode.geometry = sunPlane
        sunNode.constraints = [SCNBillboardConstraint()]
        sunNode.isHidden = true
        root.addChildNode(sunNode)

        // Moon
        let moonPlane = SCNPlane(width: 44, height: 44)
        moonPlane.firstMaterial?.lightingModel = .constant
        moonPlane.firstMaterial?.isDoubleSided = true
        moonNode.geometry = moonPlane
        moonNode.constraints = [SCNBillboardConstraint()]
        moonNode.isHidden = true
        root.addChildNode(moonNode)

        // ISS marker: a bright cyan diamond + label.
        buildISSNode()
        root.addChildNode(issNode)
        root.addChildNode(starsRoot)
        root.addChildNode(starNamesNode)
        root.addChildNode(constellationsNode)
        buildPlanetNodes()
        root.addChildNode(planetsNode)
        buildStarNameNodes()
    }

    /// Name labels are created once (SCNText is costly) and only repositioned.
    private func buildStarNameNodes() {
        for star in StarCatalog.namedStars {
            let text = SCNText(string: star.name, extrusionDepth: 0)
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

            let text = SCNText(string: name, extrusionDepth: 0)
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

        let text = SCNText(string: "ISS", extrusionDepth: 0)
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

    // MARK: Update

    func update(date: Date, lat: Double, lon: Double, offset: Double, mirror: Bool, forceStars: Bool) {
        guard let engine else { return }
        updateSun(date: date, lat: lat, lon: lon, offset: offset, mirror: mirror, show: engine.showSun)
        updateMoon(date: date, lat: lat, lon: lon, offset: offset, mirror: mirror, show: engine.showMoon)
        updateISS(date: date, lat: lat, lon: lon, offset: offset, mirror: mirror, show: engine.showISS)
        updatePlanets(date: date, lat: lat, lon: lon, offset: offset, mirror: mirror, show: engine.showPlanets)

        if engine.showStars {
            starsRoot.isHidden = false
            starNamesNode.isHidden = false
            constellationsNode.isHidden = false
            if forceStars || Date().timeIntervalSince(lastStarBuild) > 10 {
                buildStars(date: date, lat: lat, lon: lon, offset: offset, mirror: mirror)
                lastStarBuild = Date()
            }
        } else {
            starsRoot.isHidden = true
            starNamesNode.isHidden = true
            constellationsNode.isHidden = true
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
        starNamesNode.isHidden = !engine.showStars
        constellationsNode.isHidden = !engine.showStars
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
    }

    /// The 1,600-star trig sweep runs off the main thread; only the cheap
    /// geometry swap and label repositioning touch the render thread's frame.
    private func buildStars(date: Date, lat: Double, lon: Double, offset: Double, mirror: Bool) {
        guard !starsBuilding else { return }
        starsBuilding = true
        let stars = StarCatalog.shared.stars
        let lines = StarCatalog.shared.lines
        let named = StarCatalog.namedStars
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
            for star in named {
                let h = SkyMath.equatorialToHorizontal(raDeg: star.ra, decDeg: star.dec,
                                                       latDeg: lat, lonDeg: lon, date: date)
                guard h.elevation > 2 else { continue }
                namePositions[star.name] = SkyMath.scenePosition(
                    azimuthDeg: h.azimuth, elevationDeg: h.elevation,
                    radius: r * 0.97, headingOffsetDeg: offset, mirrorX: mirror)
            }
            await MainActor.run { [weak self] in
                self?.applyStars(bright: bright, medium: medium, faint: faint,
                                 segs: segs, namePositions: namePositions)
            }
        }
    }

    private func applyStars(bright: [SCNVector3], medium: [SCNVector3], faint: [SCNVector3],
                            segs: [SCNVector3], namePositions: [String: SCNVector3]) {
        starsRoot.childNodes.forEach { $0.removeFromParentNode() }
        starsRoot.addChildNode(SCNNode(geometry: pointGeometry(bright, size: 9, color: UIColor(white: 1, alpha: 1))))
        starsRoot.addChildNode(SCNNode(geometry: pointGeometry(medium, size: 6, color: UIColor(white: 0.95, alpha: 1))))
        starsRoot.addChildNode(SCNNode(geometry: pointGeometry(faint, size: 3.5, color: UIColor(white: 0.8, alpha: 1))))

        constellationsNode.childNodes.forEach { $0.removeFromParentNode() }
        if !segs.isEmpty {
            constellationsNode.addChildNode(SCNNode(geometry: lineGeometry(segs,
                color: UIColor(red: 0.45, green: 0.55, blue: 0.85, alpha: 0.5))))
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

    private func pointGeometry(_ verts: [SCNVector3], size: CGFloat, color: UIColor) -> SCNGeometry {
        let src = SCNGeometrySource(vertices: verts)
        let element = SCNGeometryElement(indices: Array(Int32(0)..<Int32(verts.count)), primitiveType: .point)
        element.pointSize = size
        element.minimumPointScreenSpaceRadius = size * 0.4
        element.maximumPointScreenSpaceRadius = size
        let g = SCNGeometry(sources: [src], elements: [element])
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = color; m.isDoubleSided = true
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
