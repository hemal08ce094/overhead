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
    /// All ActivityKit calls chain through here, so a start / update / end
    /// can never apply out of order (an unordered end sweep racing a fresh
    /// request used to kill the new activity; stale updates could land last).
    private var queue: Task<Void, Never>?

    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        queue = Task { [previous = queue] in
            await previous?.value
            await op()
        }
    }

    func start(callsign: String, route: String, state: FlightActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        self.callsign = callsign
        enqueue { [weak self] in
            // End stale activities BEFORE requesting the new one, sequentially.
            for orphan in Activity<FlightActivityAttributes>.activities {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
            guard let self, self.callsign == callsign else { return }   // focus moved on
            self.activity = try? Activity.request(
                attributes: FlightActivityAttributes(callsign: callsign, route: route),
                content: .init(state: state, staleDate: Date().addingTimeInterval(90)))
        }
    }

    func update(_ state: FlightActivityAttributes.ContentState) {
        guard activity != nil else { return }
        enqueue { [weak self] in
            await self?.activity?.update(.init(state: state, staleDate: Date().addingTimeInterval(90)))
        }
    }

    /// One orphan sweep per launch is enough — after that, an `end()` with no
    /// live activity must be a pure no-op. (Even *querying* `.activities` is
    /// an ActivityKit XPC round-trip, and this is called every poll tick
    /// while unfocused — it was spamming the console once per second.)
    private var orphansSwept = false

    /// End every activity of our type, not just the held instance — after an
    /// app relaunch the system-side activity outlives our handle and would
    /// otherwise be orphaned on the lock screen forever.
    func end() {
        guard callsign != nil || activity != nil || !orphansSwept else { return }
        orphansSwept = true
        callsign = nil
        activity = nil
        enqueue {
            for orphan in Activity<FlightActivityAttributes>.activities {
                await orphan.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
