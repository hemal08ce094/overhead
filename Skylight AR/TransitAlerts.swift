//
//  TransitAlerts.swift
//  Skylight AR
//
//  The marquee trick only this app can do: with live aircraft tracks and the
//  moon/sun in one geometry engine, predict when a plane will visually cross
//  (or nearly cross) the lunar or solar disc from the observer's position.
//

import Foundation

struct TransitPrediction: Equatable {
    enum Body: String { case moon = "Moon", sun = "Sun" }
    let callsign: String
    let body: Body
    let date: Date
    let azimuth: Double        // where to look when it happens
    let elevation: Double
    let separationDeg: Double  // predicted minimum separation
}

enum TransitPredictor {

    /// Angular separation between two sky positions, degrees.
    nonisolated static func separation(az1: Double, el1: Double, az2: Double, el2: Double) -> Double {
        let e1 = el1 * .pi / 180, e2 = el2 * .pi / 180
        let dAz = (az1 - az2) * .pi / 180
        let cosSep = sin(e1) * sin(e2) + cos(e1) * cos(e2) * cos(dAz)
        return acos(max(-1, min(1, cosSep))) * 180 / .pi
    }

    /// Earliest predicted near-transit of any aircraft across the moon or sun
    /// within the next `horizon` seconds. Dead-reckons each track at its
    /// current ground speed; bodies are treated as fixed over the horizon
    /// (the moon moves ~0.03° in 3 minutes — far below the disc radius).
    nonisolated static func predict(aircraft: [Aircraft],
                        observerLat: Double, observerLon: Double, observerAltM: Double,
                        moon: (az: Double, el: Double)?,
                        sun: (az: Double, el: Double)?,
                        horizon: Double = 180,
                        thresholdDeg: Double = 0.45) -> TransitPrediction? {
        var targets: [(TransitPrediction.Body, (az: Double, el: Double))] = []
        if let moon, moon.el > 5 { targets.append((.moon, moon)) }
        if let sun, sun.el > 5 { targets.append((.sun, sun)) }
        guard !targets.isEmpty else { return nil }

        let earthR = 6_371_000.0
        var best: TransitPrediction?

        for ac in aircraft {
            guard let callsign = ac.callsign,
                  let track = ac.track,
                  let gs = ac.groundSpeedKts, gs > 60,
                  !ac.onGround else { continue }
            let speedMps = gs * 0.514444
            let trackRad = track * .pi / 180
            let cosLat = cos(ac.lat * .pi / 180)

            // Separation from `fix` at dead-reckoned time t; ∞ below 8° elevation.
            func sep(at t: Double, from fix: (az: Double, el: Double)) -> Double {
                let d = speedMps * t
                let lat = ac.lat + (d * cos(trackRad) / earthR) * 180 / .pi
                let lon = ac.lon + (d * sin(trackRad) / (earthR * cosLat)) * 180 / .pi
                let pos = SkyMath.azElRange(observerLat: observerLat, observerLon: observerLon,
                                            observerAltM: observerAltM,
                                            targetLat: lat, targetLon: lon,
                                            targetAltM: ac.altitudeMeters)
                guard pos.elevation > 8 else { return .infinity }
                return separation(az1: pos.azimuth, el1: pos.elevation,
                                  az2: fix.az, el2: fix.el)
            }

            // A nearby jet crosses the disc at up to several °/s, so a 2 s grid
            // can straddle the whole transit with both samples far outside the
            // threshold. Instead of testing samples directly, find each local
            // minimum of separation on the coarse grid and refine it finely.
            let coarseStep = 2.0, coarseGateDeg = 10.0, fineStep = 0.05
            for (body, fix) in targets {
                var sPrev2 = Double.infinity   // sep at t - 2·step
                var sPrev = Double.infinity    // sep at t - step
                var t = 0.0
                while t <= horizon + coarseStep {   // one step past, so a minimum at the horizon is seen
                    let s = sep(at: min(t, horizon), from: fix)
                    if sPrev <= sPrev2, sPrev <= s, sPrev < coarseGateDeg {
                        var bestT = t - coarseStep, bestSep = sPrev
                        var ft = max(0, t - 2 * coarseStep)
                        let fEnd = min(horizon, t)
                        while ft <= fEnd {
                            let fs = sep(at: ft, from: fix)
                            if fs < bestSep { bestSep = fs; bestT = ft }
                            ft += fineStep
                        }
                        if bestSep < thresholdDeg {
                            let when = Date().addingTimeInterval(bestT)
                            if best == nil || when < best!.date {
                                best = TransitPrediction(callsign: callsign, body: body,
                                                         date: when,
                                                         azimuth: fix.az, elevation: fix.el,
                                                         separationDeg: bestSep)
                            }
                        }
                    }
                    sPrev2 = sPrev; sPrev = s
                    t += coarseStep
                }
            }
        }
        return best
    }
}
