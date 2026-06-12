//
//  OverheadVisionApp.swift
//  OverheadVision
//
//  Overhead on Apple Vision Pro: the sky — live aircraft, sun, moon,
//  planets, stars, the ISS — anchored into the room around you.
//  Fully self-contained target; shares nothing with the iOS app but ideas.
//

import SwiftUI
import RealityKit

@main
struct OverheadVisionApp: App {
    @State private var model = VisionSkyModel()

    var body: some SwiftUI.Scene {
        WindowGroup {
            ControlPanelView(model: model)
        }
        .defaultSize(width: 420, height: 520)

        ImmersiveSpace(id: "sky") {
            SkyImmersiveView(model: model)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

// MARK: - Control window

struct ControlPanelView: View {
    @Bindable var model: VisionSkyModel
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("Overhead")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(model.statusLine)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    if model.skyOpen {
                        await dismissSpace()
                        model.skyOpen = false
                    } else {
                        await openSpace(id: "sky")
                        model.skyOpen = true
                    }
                }
            } label: {
                Label(model.skyOpen ? "Close the sky" : "Open the sky",
                      systemImage: model.skyOpen ? "xmark" : "moon.stars.fill")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.45, green: 0.58, blue: 0.95))

            if model.skyOpen {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Align to north")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("Vision Pro has no compass. Drag until a known direction — the sun, the moon, or a landmark flight — lines up with the real world.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.secondary)
                    Slider(value: $model.northOffsetDeg, in: -180...180, step: 1) {
                        Text("North")
                    } minimumValueLabel: {
                        Text("−180°").font(.caption2)
                    } maximumValueLabel: {
                        Text("180°").font(.caption2)
                    }
                    Text(String(format: "%+.0f°", model.northOffsetDeg))
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .frame(maxWidth: .infinity)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }

            Spacer(minLength: 0)
            Text("Aircraft via airplanes.live · ephemeris on device")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .task {
            model.start()
            #if DEBUG
            // Simulator harness: mouse/HID injection can't reach in-sim UI,
            // so `defaults write … debugOpenSky 1` stands in for the button.
            if UserDefaults.standard.bool(forKey: "debugOpenSky"), !model.skyOpen {
                await openSpace(id: "sky")
                model.skyOpen = true
            }
            #endif
        }
    }
}
