//
//  SkylightWidgets.swift
//  SkylightWidgets
//
//  Live Activity for a focused flight: lock screen card + Dynamic Island.
//  Foreground-driven v1 — the app updates while active; states go stale
//  gracefully when it suspends.
//

import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

/// Mirror of the app-side attributes — coding shape must stay identical.
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

@main
struct SkylightWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FlightLiveActivity()
        OpenSkyControl()
        MoonClockWidget()
    }
}

// MARK: - Control Center / Action button control

struct OpenSkyIntent: AppIntent {
    static let title: LocalizedStringResource = "Open the Sky"
    static let description = IntentDescription("Open Overhead and start scanning the sky.")
    static let opensAppWhenRun: Bool = true
    func perform() async throws -> some IntentResult { .result() }
}

/// One press — from the Action button or Control Center — and the sky opens.
struct OpenSkyControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "hemal.Skylight-AR.openSky") {
            ControlWidgetButton(action: OpenSkyIntent()) {
                Label("Open the Sky", systemImage: "moon.stars.fill")
            }
        }
        .displayName("Open the Sky")
        .description("Open Overhead and start scanning the sky.")
    }
}

struct FlightLiveActivity: Widget {
    private let night = Color(red: 0.05, green: 0.06, blue: 0.13)
    private let accent = Color(red: 0.60, green: 0.74, blue: 1.00)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            // Lock screen / banner
            HStack(spacing: 14) {
                Image(systemName: "airplane")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent)
                    .rotationEffect(.degrees(context.state.bearingDeg - 90))
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.callsign)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    if !context.attributes.route.isEmpty {
                        Text(context.attributes.route)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(context.state.overhead
                         ? String(format: "%.0f nm", context.state.distanceNm)
                         : "—")
                        .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(accent)
                    Text(context.state.overhead
                         ? "\(Int(context.state.altitudeFeet / 100) * 100) ft"
                         : "not overhead")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .activityBackgroundTint(night.opacity(0.85))
            .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "airplane")
                            .foregroundStyle(accent)
                        Text(context.attributes.callsign)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.overhead
                         ? String(format: "%.0f nm", context.state.distanceNm)
                         : "—")
                        .font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if !context.attributes.route.isEmpty {
                            Text(context.attributes.route)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(context.state.overhead
                             ? "\(Int(context.state.altitudeFeet / 100) * 100) ft · \(Int(context.state.bearingDeg.rounded()))°"
                             : "waiting for next pass")
                            .font(.system(size: 13, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "airplane")
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text(context.state.overhead
                     ? String(format: "%.0fnm", context.state.distanceNm)
                     : "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(accent)
            } minimal: {
                Image(systemName: "airplane")
                    .foregroundStyle(accent)
            }
        }
    }
}
