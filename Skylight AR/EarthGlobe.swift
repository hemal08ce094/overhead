//
//  EarthGlobe.swift
//  Overhead
//
//  The orbit view: pinch in from the dark sky and the camera keeps pulling
//  back until Earth hangs in front of you — Blue Marble texture, live
//  day/night terminator (a real directional sun), your beacon, and the ISS
//  riding its actual orbit. Drag to spin, pinch out to fall back into your sky.
//

import Foundation
import SceneKit
import UIKit
import SwiftAA
import SatelliteKit

@MainActor
final class EarthGlobe {

    let root = SCNNode()                  // hidden until orbit view entered
    private let earthNode = SCNNode()     // spins under the user's finger
    private let tiltNode = SCNNode()      // pitch clamp
    private let beaconNode = SCNNode()
    private let issNode = SCNNode()
    private let issRingNode = SCNNode()
    private let sunLight = SCNNode()
    private var built = false

    /// Distance from camera to globe center, driven by pinch.
    var cameraDistance: Double = 2.6

    private static let accent = UIColor(red: 0.60, green: 0.74, blue: 1.0, alpha: 1)

    // MARK: Build

    func buildIfNeeded() {
        guard !built else { return }
        built = true

        // Earth
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 96
        let mat = SCNMaterial()
        let texture = Bundle.main.url(forResource: "earth_day", withExtension: "jpg")
            .flatMap { UIImage(contentsOfFile: $0.path) }
        mat.diffuse.contents = texture ?? UIColor(red: 0.10, green: 0.22, blue: 0.42, alpha: 1)
        mat.diffuse.mipFilter = .linear
        mat.specular.contents = UIColor(white: 0.25, alpha: 1)
        mat.shininess = 8
        sphere.materials = [mat]
        earthNode.geometry = sphere
        tiltNode.addChildNode(earthNode)
        root.addChildNode(tiltNode)

        // Atmosphere rim — inside-out shell, additive, brightest at the limb.
        let atmosphere = SCNSphere(radius: 1.035)
        atmosphere.segmentCount = 64
        let atmMat = SCNMaterial()
        atmMat.lightingModel = .constant
        atmMat.diffuse.contents = UIColor.clear
        atmMat.emission.contents = UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1)
        atmMat.transparency = 0.16
        atmMat.blendMode = .add
        atmMat.cullMode = .front
        atmMat.writesToDepthBuffer = false
        atmosphere.materials = [atmMat]
        tiltNode.addChildNode(SCNNode(geometry: atmosphere))

        // The sun: a real directional light makes the terminator for free.
        // Parented to the earth so day/night stays glued to geography while
        // the globe spins under a finger.
        sunLight.light = SCNLight()
        sunLight.light?.type = .directional
        sunLight.light?.intensity = 1100
        earthNode.addChildNode(sunLight)
        // Night side stays readable (Maps-style), terminator still obvious.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 220
        ambient.light?.color = UIColor(red: 0.55, green: 0.62, blue: 0.85, alpha: 1)
        root.addChildNode(ambient)

        // Your beacon.
        let glow = SCNPlane(width: 0.07, height: 0.07)
        let glowMat = SCNMaterial()
        glowMat.lightingModel = .constant
        glowMat.diffuse.contents = SkyArt.glowImage(color: Self.accent)
        glowMat.blendMode = .add
        glowMat.writesToDepthBuffer = false
        glow.materials = [glowMat]
        beaconNode.geometry = glow
        beaconNode.constraints = [SCNBillboardConstraint()]
        earthNode.addChildNode(beaconNode)

        // ISS marker + orbit ring.
        let issPlane = SCNPlane(width: 0.09, height: 0.09)
        let issMat = SCNMaterial()
        issMat.lightingModel = .constant
        issMat.diffuse.contents = SkyArt.glowImage(color: UIColor(red: 0.5, green: 1, blue: 1, alpha: 1))
        issMat.blendMode = .add
        issMat.writesToDepthBuffer = false
        issPlane.materials = [issMat]
        issNode.geometry = issPlane
        issNode.constraints = [SCNBillboardConstraint()]
        earthNode.addChildNode(issNode)
        earthNode.addChildNode(issRingNode)

        root.isHidden = true
    }

    // MARK: Geometry

    /// Earth-local position for a lat/lon at `radiusFactor` × earth radius.
    /// Mapped to SceneKit's equirectangular sphere wrapping.
    static func position(lat: Double, lon: Double, radiusFactor: Double = 1.0) -> SCNVector3 {
        let phi = lat * .pi / 180
        let lambda = lon * .pi / 180
        let r = radiusFactor
        return SCNVector3(Float(r * cos(phi) * sin(lambda)),
                          Float(r * sin(phi)),
                          Float(r * cos(phi) * cos(lambda)))
    }

    /// Subsolar point (where the sun is overhead right now).
    static func subsolarPoint(date: Date) -> (lat: Double, lon: Double) {
        let jd = JulianDay(date)
        let eq = Sun(julianDay: jd).apparentEquatorialCoordinates
        let gmstDeg = jd.meanGreenwichSiderealTime().value * 15
        var lon = (eq.rightAscension.value * 15 - gmstDeg).truncatingRemainder(dividingBy: 360)
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        return (eq.declination.value, lon)
    }

    // MARK: Live updates

    func update(userLat: Double, userLon: Double, iss: Satellite?, date: Date) {
        buildIfNeeded()
        beaconNode.position = Self.position(lat: userLat, lon: userLon, radiusFactor: 1.012)

        // Sun → terminator (computed in the earth's own frame).
        let sub = Self.subsolarPoint(date: date)
        sunLight.position = Self.position(lat: sub.lat, lon: sub.lon, radiusFactor: 60)
        sunLight.look(at: SCNVector3Zero)

        // ISS now + its orbit ring (±46 min of ground track).
        if let iss {
            if let lla = try? iss.geoPosition(julianDays: SkyMath.julianDay(date)) {
                issNode.isHidden = false
                issNode.position = Self.position(lat: lla.lat, lon: lla.lon, radiusFactor: 1.07)
            }
            var ring: [SCNVector3] = []
            for minute in stride(from: -46.0, through: 46.0, by: 2.0) {
                let t = date.addingTimeInterval(minute * 60)
                if let lla = try? iss.geoPosition(julianDays: SkyMath.julianDay(t)) {
                    ring.append(Self.position(lat: lla.lat, lon: lla.lon, radiusFactor: 1.07))
                }
            }
            if ring.count >= 2 {
                var segs: [SCNVector3] = []
                for i in 1..<ring.count { segs.append(ring[i - 1]); segs.append(ring[i]) }
                let geometry = SCNGeometry.line(segs)
                geometry.firstMaterial?.diffuse.contents =
                    UIColor(red: 0.5, green: 1, blue: 1, alpha: 0.4)
                issRingNode.geometry = geometry
            }
        } else {
            issNode.isHidden = true
        }
    }

    /// Spin under the user's finger; pitch is clamped so it can't flip over.
    func applyDrag(deltaX: Float, deltaY: Float) {
        earthNode.eulerAngles.y += deltaX * 0.005
        tiltNode.eulerAngles.x = max(-1.2, min(1.2, tiltNode.eulerAngles.x + deltaY * 0.005))
    }

    /// Face the user's own location toward the camera on entry.
    func orient(toLat lat: Double, lon: Double) {
        tiltNode.eulerAngles.x = Float(lat * .pi / 180) * 0.6
        earthNode.eulerAngles.y = -Float(lon * .pi / 180)
    }
}
