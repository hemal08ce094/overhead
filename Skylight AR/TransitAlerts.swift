//
//  TransitAlerts.swift
//  Skylight AR
//
//  The marquee trick only this app can do: with live aircraft tracks and the
//  moon/sun in one geometry engine, predict when a plane will visually cross
//  (or nearly cross) the lunar or solar disc from the observer's position.
//

import Foundation
import UserNotifications

struct TransitPrediction: Equatable {
    enum Body: String {
        case moon = "Moon", sun = "Sun"
        var displayName: String {
            switch self {
            case .moon: return String(localized: "Moon")
            case .sun: return String(localized: "Sun")
            }
        }
    }
    let callsign: String
    let body: Body
    let date: Date
    let azimuth: Double        // where to look when it happens
    let elevation: Double
    let separationDeg: Double  // predicted minimum separation
}

/// A body's sky path over the prediction horizon: az/el at the start and end,
/// linearly interpolated between. The body is NOT fixed in the az/el frame —
/// diurnal rotation sweeps it ~0.25°/min, most of a moon-width across a
/// 3-minute horizon (its drift against the *stars* is the negligible part).
/// Over minutes that sweep is linear to well under the disc radius.
struct BodyTrack {
    let startAz: Double, startEl: Double
    let endAz: Double, endEl: Double
    let horizon: Double

    func at(_ t: Double) -> (az: Double, el: Double) {
        let f = horizon > 0 ? min(max(t / horizon, 0), 1) : 0
        var dAz = endAz - startAz
        if dAz > 180 { dAz -= 360 } else if dAz < -180 { dAz += 360 }
        var az = startAz + dAz * f
        if az < 0 { az += 360 } else if az >= 360 { az -= 360 }
        return (az, startEl + (endEl - startEl) * f)
    }
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
    /// current ground speed against the body's own moving sky path.
    /// Refraction is applied to neither side: at transit the plane and the
    /// body sit at the same elevation, so it lifts both nearly equally and
    /// cancels in the separation.
    nonisolated static func predict(aircraft: [Aircraft],
                        observerLat: Double, observerLon: Double, observerAltM: Double,
                        moon: BodyTrack?,
                        sun: BodyTrack?,
                        horizon: Double = 180,
                        thresholdDeg: Double = 0.45) -> TransitPrediction? {
        var targets: [(TransitPrediction.Body, BodyTrack)] = []
        if let moon, moon.startEl > 5 { targets.append((.moon, moon)) }
        if let sun, sun.startEl > 5 { targets.append((.sun, sun)) }
        guard !targets.isEmpty else { return nil }

        let earthR = 6_371_000.0
        var best: TransitPrediction?

        for ac in aircraft {
            // 25 kt floor: below that a track is mostly noise (hovering
            // helicopters), above it slow GA and helicopters in cruise get
            // transit predictions too — they cross the disc slowly, which
            // makes them the *easiest* shots to catch.
            guard let callsign = ac.callsign,
                  let track = ac.track,
                  let gs = ac.groundSpeedKts, gs > 25,
                  !ac.onGround else { continue }
            let speedMps = gs * 0.514444
            let trackRad = track * .pi / 180
            let cosLat = cos(ac.lat * .pi / 180)

            // Separation from the body at dead-reckoned time t — both the
            // plane and the body evaluated at t; ∞ below 8° elevation.
            func sep(at t: Double, from body: BodyTrack) -> Double {
                let d = speedMps * t
                let lat = ac.lat + (d * cos(trackRad) / earthR) * 180 / .pi
                let lon = ac.lon + (d * sin(trackRad) / (earthR * cosLat)) * 180 / .pi
                let pos = SkyMath.azElRange(observerLat: observerLat, observerLon: observerLon,
                                            observerAltM: observerAltM,
                                            targetLat: lat, targetLon: lon,
                                            targetAltM: ac.altitudeMeters)
                guard pos.elevation > 8 else { return .infinity }
                let fix = body.at(t)
                return separation(az1: pos.azimuth, el1: pos.elevation,
                                  az2: fix.az, el2: fix.el)
            }

            // A nearby jet crosses the disc at up to several °/s, so a 2 s grid
            // can straddle the whole transit with both samples far outside the
            // threshold. Instead of testing samples directly, find each local
            // minimum of separation on the coarse grid and refine it finely.
            let coarseStep = 2.0, coarseGateDeg = 10.0, fineStep = 0.05
            for (body, track) in targets {
                var sPrev2 = Double.infinity   // sep at t - 2·step
                var sPrev = Double.infinity    // sep at t - step
                var t = 0.0
                while t <= horizon + coarseStep {   // one step past, so a minimum at the horizon is seen
                    let s = sep(at: min(t, horizon), from: track)
                    if sPrev <= sPrev2, sPrev <= s, sPrev < coarseGateDeg {
                        var bestT = t - coarseStep, bestSep = sPrev
                        var ft = max(0, t - 2 * coarseStep)
                        let fEnd = min(horizon, t)
                        while ft <= fEnd {
                            let fs = sep(at: ft, from: track)
                            if fs < bestSep { bestSep = fs; bestT = ft }
                            ft += fineStep
                        }
                        if bestSep < thresholdDeg {
                            let when = Date().addingTimeInterval(bestT)
                            if best == nil || when < best!.date {
                                // Look-here direction = the body at crossing
                                // time, not where it hangs now.
                                let at = track.at(bestT)
                                best = TransitPrediction(callsign: callsign, body: body,
                                                         date: when,
                                                         azimuth: at.az, elevation: at.el,
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

// MARK: - Transit alarm (local notification, T−60 s)

/// The "phone in the pocket" alarm: a local notification one minute before a
/// predicted crossing, so the observer who set the tripod up and locked the
/// phone still gets tapped on the shoulder. Aircraft transits are knowable
/// only minutes ahead and only while the feed runs, so the schedule simply
/// mirrors the live prediction 1:1 — it never promises more than the
/// predictor knows.
enum TransitAlertScheduler {
    /// The lead choices offered in Notifications settings. Physics caps the
    /// ceiling: the predictor sees ~3 minutes out, so the longest lead means
    /// "the moment a transit is predicted."
    static let leadChoices: [TimeInterval] = [30, 60, 120, 180]

    /// The last (identity × settings) we scheduled — re-predictions of the
    /// *same* transit refine the date by fractions of a second every poll
    /// tick; comparing keys here keeps the per-tick call free (no
    /// UNUserNotificationCenter XPC round-trip unless something changed).
    private static var scheduledKey: String?

    /// One identity per physical transit: plane × body × minute bucket.
    private static func identifier(for p: TransitPrediction) -> String {
        "transit-\(p.callsign)-\(p.body.rawValue)-\(Int(p.date.timeIntervalSince1970 / 60))"
    }

    /// "30 seconds" / "1 minute" / "2 minutes" / "3 minutes" — bucketed so a
    /// capped lead still reads honestly as an "about".
    static func leadPhrase(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<45:  String(localized: "30 seconds")
        case ..<90:  String(localized: "1 minute")
        case ..<150: String(localized: "2 minutes")
        default:     String(localized: "3 minutes")
        }
    }

    /// Remove any pending transit alarm (alarm switched off, or app teardown).
    static func cancel() {
        guard scheduledKey != nil else { return }
        scheduledKey = nil
        Task {
            let center = UNUserNotificationCenter.current()
            let ours = await center.pendingNotificationRequests()
                .map(\.identifier).filter { $0.hasPrefix("transit-") }
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }
    }

    /// Mirror the live prediction under the user's settings: schedule when a
    /// qualifying transit exists, clear when it dissolves. The notification
    /// fires `leadSeconds` before the crossing — or immediately, when the
    /// prediction is already inside the lead. Safe to call every tick.
    static func sync(_ prediction: TransitPrediction?, enabled: Bool,
                     leadSeconds: TimeInterval, moon: Bool, sun: Bool) {
        // Body filter first: a disabled body is the same as no prediction.
        let qualified: TransitPrediction? = {
            guard enabled, let p = prediction else { return nil }
            switch p.body {
            case .moon: return moon ? p : nil
            case .sun:  return sun ? p : nil
            }
        }()
        // Under ~15 s out there is nothing useful left to say from a pocket.
        let target: (key: String, p: TransitPrediction)? = qualified.flatMap { p in
            guard p.date.timeIntervalSinceNow > 15 else { return nil }
            return ("\(identifier(for: p))-L\(Int(leadSeconds))", p)
        }
        guard target?.key != scheduledKey else { return }   // nothing changed
        scheduledKey = target?.key

        Task {
            let center = UNUserNotificationCenter.current()
            let stale = await center.pendingNotificationRequests()
                .map(\.identifier)
                .filter { $0.hasPrefix("transit-") && $0 != target?.key }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            guard let target else { return }

            let p = target.p
            let remaining = p.date.timeIntervalSinceNow
            // Already inside the lead → fire now, and say the real time left.
            let fireDelay = max(1, remaining - leadSeconds)
            let shownLead = min(leadSeconds, remaining - fireDelay)

            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(p.callsign) crosses the \(p.body.displayName) in \(leadPhrase(shownLead))")
            content.body = String(localized: "Look \(compass(p.azimuth)), \(Int(p.elevation.rounded()))° up — open Overhead for the shutter.")
            content.sound = .default
            content.threadIdentifier = "transit"
            // A transit is a genuinely perishable moment — the one alert in
            // the app that earns breaking through Focus (requires the
            // time-sensitive entitlement; downgrades gracefully without it).
            content.interruptionLevel = .timeSensitive
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDelay, repeats: false)
            try? await center.add(UNNotificationRequest(
                identifier: target.key, content: content, trigger: trigger))
        }
    }
}
