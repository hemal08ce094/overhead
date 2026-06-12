//
//  SkyImmersiveView.swift
//  OverheadVision
//
//  The sky, anchored into your room: stars and constellations on a distant
//  dome, sun/moon/planets at true positions, live aircraft with floating
//  callsigns, the ISS in cyan. Mixed immersion — the room stays visible.
//

import SwiftUI
import RealityKit

struct SkyImmersiveView: View {
    @Bindable var model: VisionSkyModel

    @State private var skyRoot = Entity()
    @State private var staticBuilt = false
    @State private var aircraftEntities: [String: Entity] = [:]
    @State private var bodyEntities: [String: Entity] = [:]   // sun/moon/planets/iss

    private let starRadius: Float = 95
    private let bodyRadius: Float = 90
    private let planeRadius: Float = 70

    var body: some View {
        RealityView { content in
            skyRoot.position = .zero
            content.add(skyRoot)
        } update: { _ in
            // The one calibration knob: rotate the whole sky to true north.
            skyRoot.orientation = simd_quatf(angle: Float(-model.northOffsetDeg * .pi / 180),
                                             axis: SIMD3(0, 1, 0))
        }
        .task { await liveLoop() }
    }

    // MARK: Live loop

    private func liveLoop() async {
        while !Task.isCancelled {
            if let here = model.location {
                let lat = here.coordinate.latitude
                let lon = here.coordinate.longitude
                if !staticBuilt, !model.stars.isEmpty {
                    buildStars(lat: lat, lon: lon)
                    staticBuilt = true
                }
                updateBodies(lat: lat, lon: lon)
                updateAircraft(lat: lat, lon: lon)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: Stars & constellations (built once; sky rotation is negligible
    // over a session at this fidelity)

    private func buildStars(lat: Double, lon: Double) {
        let date = Date()
        let starMesh = MeshResource.generateSphere(radius: 1)
        let starMaterial = UnlitMaterial(color: .white)

        for star in model.stars where star.mag < 3.2 {
            let h = VSkyMath.equatorialToHorizontal(raDeg: star.ra, decDeg: star.dec,
                                                    latDeg: lat, lonDeg: lon, date: date)
            guard h.elevation > 0 else { continue }
            let entity = ModelEntity(mesh: starMesh, materials: [starMaterial])
            let size: Float = star.mag < 1.5 ? 0.34 : star.mag < 2.5 ? 0.22 : 0.13
            entity.scale = SIMD3(repeating: size)
            entity.position = VSkyMath.domePosition(azimuthDeg: h.azimuth, elevationDeg: h.elevation,
                                                    radius: Double(starRadius), northOffsetDeg: 0)
            skyRoot.addChild(entity)
        }

        // Constellation segments: one shared unit mesh, scaled per segment.
        let lineMesh = MeshResource.generateBox(size: SIMD3(0.05, 0.05, 1))
        let lineMaterial = UnlitMaterial(color: UIColor(red: 0.45, green: 0.55, blue: 0.85, alpha: 0.55))
        for line in model.constellations {
            var previous: SIMD3<Float>?
            for point in line where point.count == 2 {
                let h = VSkyMath.equatorialToHorizontal(raDeg: point[0], decDeg: point[1],
                                                        latDeg: lat, lonDeg: lon, date: date)
                guard h.elevation > 0 else { previous = nil; continue }
                let p = VSkyMath.domePosition(azimuthDeg: h.azimuth, elevationDeg: h.elevation,
                                              radius: Double(starRadius) * 0.99, northOffsetDeg: 0)
                if let a = previous {
                    let segment = ModelEntity(mesh: lineMesh, materials: [lineMaterial])
                    let mid = (a + p) / 2
                    let delta = p - a
                    segment.position = mid
                    segment.scale = SIMD3(1, 1, simd_length(delta))
                    segment.look(at: p, from: mid, relativeTo: skyRoot)
                    skyRoot.addChild(segment)
                }
                previous = p
            }
        }
    }

    // MARK: Sun, moon, planets, ISS

    private func updateBodies(lat: Double, lon: Double) {
        let date = Date()
        let sun = VCelestial.sun(date: date, lat: lat, lon: lon)
        placeBody("sun", az: sun.az, el: sun.el, size: 2.2,
                  color: UIColor(red: 1.0, green: 0.93, blue: 0.75, alpha: 1))
        let moon = VCelestial.moon(date: date, lat: lat, lon: lon)
        placeBody("moon", az: moon.az, el: moon.el, size: 1.7,
                  color: UIColor(red: 0.96, green: 0.96, blue: 0.91, alpha: 1))
        if let iss = model.issSatellite,
           let lla = try? iss.geoPosition(julianDays: VSkyMath.julianDay(date)) {
            let r = VSkyMath.azElRange(observerLat: lat, observerLon: lon,
                                       targetLat: lla.lat, targetLon: lla.lon,
                                       targetAltM: lla.alt * 1000)
            placeBody("iss", az: r.azimuth, el: r.elevation, size: 0.7,
                      color: UIColor(red: 0.5, green: 1.0, blue: 1.0, alpha: 1))
        }
    }

    private func placeBody(_ key: String, az: Double, el: Double, size: Float, color: UIColor) {
        guard el > -2 else {
            bodyEntities[key]?.isEnabled = false
            return
        }
        let entity: Entity
        if let existing = bodyEntities[key] {
            entity = existing
        } else {
            let model = ModelEntity(mesh: .generateSphere(radius: 1),
                                    materials: [UnlitMaterial(color: color)])
            bodyEntities[key] = model
            skyRoot.addChild(model)
            entity = model
        }
        entity.isEnabled = true
        entity.scale = SIMD3(repeating: size)
        entity.position = VSkyMath.domePosition(azimuthDeg: az, elevationDeg: el,
                                                radius: Double(bodyRadius), northOffsetDeg: 0)
    }

    // MARK: Aircraft

    private func updateAircraft(lat: Double, lon: Double) {
        var seen = Set<String>()
        for plane in model.traffic {
            let geometry = VSkyMath.azElRange(observerLat: lat, observerLon: lon,
                                              targetLat: plane.lat, targetLon: plane.lon,
                                              targetAltM: plane.altM)
            guard geometry.elevation > 0 else { continue }
            seen.insert(plane.hex)
            let entity: Entity
            if let existing = aircraftEntities[plane.hex] {
                entity = existing
            } else {
                entity = makeAircraftEntity(callsign: plane.callsign ?? plane.hex.uppercased())
                aircraftEntities[plane.hex] = entity
                skyRoot.addChild(entity)
            }
            entity.position = VSkyMath.domePosition(azimuthDeg: geometry.azimuth,
                                                    elevationDeg: geometry.elevation,
                                                    radius: Double(planeRadius), northOffsetDeg: 0)
        }
        for (hex, entity) in aircraftEntities where !seen.contains(hex) {
            entity.removeFromParent()
            aircraftEntities[hex] = nil
        }
    }

    private func makeAircraftEntity(callsign: String) -> Entity {
        let root = Entity()
        let glyph = ModelEntity(mesh: .generateSphere(radius: 0.28),
                                materials: [UnlitMaterial(color: UIColor(red: 0.55, green: 0.95, blue: 0.75, alpha: 1))])
        root.addChild(glyph)

        let textMesh = MeshResource.generateText(callsign,
                                                 extrusionDepth: 0.01,
                                                 font: .systemFont(ofSize: 0.55, weight: .semibold),
                                                 containerFrame: .zero,
                                                 alignment: .center,
                                                 lineBreakMode: .byTruncatingTail)
        let label = ModelEntity(mesh: textMesh, materials: [UnlitMaterial(color: .white)])
        let bounds = textMesh.bounds
        label.position = SIMD3(-bounds.extents.x / 2, 0.6, 0)
        label.components.set(BillboardComponent())
        root.addChild(label)
        return root
    }
}
