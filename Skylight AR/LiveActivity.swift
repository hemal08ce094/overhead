//
//  LiveActivity.swift
//  Skylight AR
//
//  App-side Live Activity driver for the focused flight. Foreground v1: the
//  1 Hz poll updates the Activity while the app runs; with no push server the
//  state simply goes stale (per staleDate) once the app suspends.
//

import Foundation
import ActivityKit

/// Mirror of the widget-side attributes — coding shape must stay identical.
struct FlightActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var altitudeFeet: Double
        var distanceNm: Double
        var bearingDeg: Double
        var overhead: Bool
    }
    var callsign: String
    var route: String
}

@MainActor
final class FlightActivityController {
    private var activity: Activity<FlightActivityAttributes>?
    private(set) var callsign: String?

    func start(callsign: String, route: String, state: FlightActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        self.callsign = callsign
        // End stale activities BEFORE requesting the new one, sequentially —
        // an async sweep racing the fresh request kills the new activity too.
        let stale = Activity<FlightActivityAttributes>.activities
        Task {
            for orphan in stale {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
            guard self.callsign == callsign else { return }   // focus moved on
            self.activity = try? Activity.request(
                attributes: FlightActivityAttributes(callsign: callsign, route: route),
                content: .init(state: state, staleDate: Date().addingTimeInterval(90)))
        }
    }

    func update(_ state: FlightActivityAttributes.ContentState) {
        guard let activity else { return }
        Task {
            await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(90)))
        }
    }

    /// End every activity of our type, not just the held instance — after an
    /// app relaunch the system-side activity outlives our handle and would
    /// otherwise be orphaned on the lock screen forever.
    func end() {
        callsign = nil
        activity = nil
        Task {
            for orphan in Activity<FlightActivityAttributes>.activities {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
