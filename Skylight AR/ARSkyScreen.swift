//
//  ARSkyScreen.swift
//  Skylight AR
//
//  Hosts ARSkyViewController and lays elegant, minimal chrome over it: a live
//  status pill, a dark-sky / camera toggle, tap-to-identify detail card, and the
//  calibration sheet.
//

import SwiftUI

// MARK: - UIKit bridge

struct ARSkyContainer: UIViewControllerRepresentable {
    var engine: SkyEngine

    func makeUIViewController(context: Context) -> ARSkyViewController {
        let controller = ARSkyViewController()
        controller.engine = engine
        engine.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: ARSkyViewController, context: Context) {}
}

// MARK: - AR screen

struct ARSkyScreen: View {
    @State private var engine = SkyEngine()
    @State private var showSky = false
    @State private var showProfile = false
    @State private var showEvents = false
    @State private var showAircraftDetail = false

    var body: some View {
        ZStack {
            ARSkyContainer(engine: engine)
                .ignoresSafeArea()

            // Subtle vignette keeps overlay chrome legible on a bright sky.
            LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.4)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    profileButton
                    Spacer()
                    if engine.zoomFactor > 1.05 { zoomPill }
                    if engine.skyTimeOffsetMin != 0 { timeOffsetPill }
                    eventsBell
                }
                if engine.compassHintNeeded && !engine.compassHintDismissed {
                    compassHint
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let focus = engine.focusInfo {
                    focusPill(focus)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let transit = engine.transitPrediction {
                    transitBanner(transit)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                // Shutter appears as a transit approaches — catch the crossing.
                if let transit = engine.transitPrediction {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        if transit.date.timeIntervalSinceNow < 15 {
                            shutterButton
                                .padding(.bottom, 14)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                controls
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: engine.selected)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: engine.skyTimeOffsetMin != 0)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSky) {
            SkySheet(engine: engine)
        }
        .sheet(isPresented: $showEvents) {
            NavigationStack { EventsView(engine: engine) }
                .presentationDetents([.medium, .large])
                .presentationBackground {
                    Color.clear
                        .glassEffect(.regular.tint(Theme.nightBottom.opacity(0.45)),
                                     in: .rect(cornerRadius: 38))
                }
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showProfile) {
            NavigationStack { ProfileView(engine: engine) }
                .presentationDetents([.medium, .large])
                .presentationBackground {
                    Color.clear
                        .glassEffect(.regular.tint(Theme.nightBottom.opacity(0.45)),
                                     in: .rect(cornerRadius: 38))
                }
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showAircraftDetail, onDismiss: { engine.deselect() }) {
            AircraftDetailSheet(engine: engine)
        }
        .sheet(item: Bindable(engine).selectedAirport) { airport in
            AirportDetailSheet(airport: airport)
        }
        // Tapping a plane opens the full sheet directly — no intermediate card.
        .onChange(of: engine.selected == nil) { _, deselected in
            showAircraftDetail = !deselected
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            PulsingDot(color: engine.feedOffline ? .orange : Theme.accent)
            Text(statusText)
                .font(Theme.display(14, .medium))
                .foregroundStyle(Theme.textPrimary)
            if !engine.feedOffline, engine.trafficCount > 0 {
                Text("· \(engine.trafficCount)")
                    .font(Theme.display(14, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(engine.feedOffline
            ? "No connection. Showing sky only."
            : "Scanning the sky. \(engine.trafficCount) aircraft overhead.")
    }

    private var statusText: String {
        if engine.feedOffline { return "Sky only — no connection" }
        if engine.usingDemoLocation { return "Demo sky" }
        return "Scanning the sky"
    }

    private var timeOffsetPill: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { engine.skyTimeOffsetMin = 0 }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold))
                Text(timeOffsetText).font(Theme.display(13, .semibold).monospacedDigit())
            }
            .foregroundStyle(Theme.nightBottom)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .glassEffect(.regular.tint(Theme.accent.opacity(0.85)), in: .capsule)
        }
        .accessibilityLabel("Sky time shifted \(timeOffsetText). Return to now.")
    }

    private var timeOffsetText: String { TimeScrub.label(engine.skyTimeOffsetMin) }

    /// The marquee moment: a plane is about to cross the moon or sun.
    private func transitBanner(_ transit: TransitPrediction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: transit.body == .moon ? "moon.fill" : "sun.max.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.45))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(transit.callsign) crosses the \(transit.body.rawValue)")
                    .font(Theme.display(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Look \(compass(transit.azimuth)) · \(Int(transit.elevation.rounded()))° up")
                    .font(Theme.display(12, .regular))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if transit.date > Date() {
                Text(timerInterval: Date()...transit.date, countsDown: true)
                    .font(Theme.display(16, .bold).monospacedDigit())
                    .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.45))
            } else {
                Text("NOW")
                    .font(Theme.display(15, .bold))
                    .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.45))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassEffect(.regular.tint(Color(red: 1.0, green: 0.82, blue: 0.45).opacity(0.18)),
                     in: .rect(cornerRadius: 20))
    }

    /// Big gold shutter for the crossing moment.
    private var shutterButton: some View {
        HStack {
            Spacer()
            Button { engine.captureShareCard() } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.45))
                    .frame(width: 68, height: 68)
                    .contentShape(Circle())
                    .glassEffect(.regular.tint(Color(red: 1.0, green: 0.82, blue: 0.45).opacity(0.25)),
                                 in: .circle)
            }
            .accessibilityLabel("Capture the crossing")
            Spacer()
        }
    }

    /// A quiet nudge when the magnetometer has been struggling for a while.
    private var compassHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.north.line.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Wave your phone in a figure-8 to fix the compass")
                .font(Theme.display(13, .medium))
                .foregroundStyle(Theme.textPrimary)
            Button { engine.compassHintDismissed = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Dismiss compass hint")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .capsule)
    }

    /// Top-right bell — the sky calendar, one tap from anywhere.
    private var eventsBell: some View {
        Button { showEvents = true } label: {
            Image(systemName: "bell")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffect(.regular, in: .circle)
        }
        .accessibilityLabel("Sky events")
    }

    /// Top-left entry to the profile sheet.
    private var profileButton: some View {
        Button { showProfile = true } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffect(.regular, in: .circle)
        }
        .accessibilityLabel("Profile")
    }

    /// Focused-flight guidance: distance plus a find-it arrow when off screen.
    /// The pill itself opens the flight's full detail; ✕ stops tracking.
    private func focusPill(_ focus: SkyEngine.FocusInfo) -> some View {
        HStack(spacing: 8) {
            Button { engine.openFocusedDetail() } label: {
                HStack(spacing: 8) {
                    if let angle = focus.arrowAngle {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .rotationEffect(.degrees(angle))
                    } else if focus.overhead {
                        Image(systemName: "scope")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(focus.overhead
                         ? "\(focus.callsign) · \(String(format: "%.0f nm", focus.distanceNm))"
                         : "\(focus.callsign) · not overhead")
                        .font(Theme.display(13, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                .contentShape(Capsule())
            }
            Button { engine.focusedCallsign = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Stop tracking")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular.tint(Theme.accentSoft.opacity(0.25)), in: .capsule)
    }

    /// Shown while pinch-zoomed; tap to snap back to 1×.
    private var zoomPill: some View {
        Button { engine.resetZoom() } label: {
            Text(String(format: "%.1f×", engine.zoomFactor))
                .font(Theme.display(13, .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Capsule())
                .glassEffect(.regular, in: .capsule)
        }
        .accessibilityLabel("Zoomed to \(String(format: "%.1f", engine.zoomFactor)) times. Reset zoom.")
    }

    /// Bottom edge: live status on the left, the celestial orb on the right —
    /// the top of the sky stays clear.
    private var controls: some View {
        HStack(alignment: .center) {
            statusPill
            Spacer()
            Button { showSky = true } label: {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 60, height: 60)
                    .contentShape(Circle())
                    .glassEffect(.regular, in: .circle)
            }
            .accessibilityLabel("Sky controls")
        }
    }
}

// MARK: - Aircraft detail sheet (expanded)

/// Everything we know about the selected flight, live-updating each poll.
struct AircraftDetailSheet: View {
    @Bindable var engine: SkyEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let ac = engine.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header(ac)
                        if let photo = engine.selectedPhoto { photoCard(photo) }
                        if ac.airline != nil || ac.destination != nil { routeCard(ac) }
                        statsGrid(ac)
                        Text("Live position via airplanes.live · route via adsbdb · photos via planespotters.net")
                            .font(Theme.display(11, .regular))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(24)
                }
                .scrollContentBackground(.hidden)
            } else {
                // Selection went stale (plane left the feed) — nothing to show.
                Color.clear.onAppear { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground {
            Color.clear
                .glassEffect(.regular.tint(Theme.nightBottom.opacity(0.45)),
                             in: .rect(cornerRadius: 38))
        }
        .preferredColorScheme(.dark)
    }

    private func header(_ ac: SelectedAircraft) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ac.callsign)
                    .font(Theme.display(30, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text([ac.airline, ac.type].compactMap(\.self).joined(separator: "  ·  "))
                    .font(Theme.display(15, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button {
                engine.toggleFavorite(ac.callsign)
            } label: {
Image(systemName: engine.isFavorite(ac.callsign) ? "heart.fill" : "heart")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(engine.isFavorite(ac.callsign)
                                     ? Color(red: 1.0, green: 0.42, blue: 0.58)
                                     : Theme.textTertiary)
            }
            .accessibilityLabel(engine.isFavorite(ac.callsign) ? "Remove from favorites" : "Add to favorites")
            Button {
                engine.focusedCallsign = ac.callsign
                dismiss()
            } label: {
Image(systemName: "scope")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(engine.focusedCallsign == ac.callsign
                                     ? Color(red: 1.0, green: 0.82, blue: 0.45)
                                     : Theme.textTertiary)
            }
            .accessibilityLabel("Track this flight")
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.textTertiary)
            }
            .accessibilityLabel("Close")
        }
    }

    /// The actual airframe, when planespotters has one.
    private func photoCard(_ photo: PlanePhoto) -> some View {
        AsyncImage(url: photo.url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.white.opacity(0.04))
                .overlay(ProgressView().tint(Theme.textTertiary))
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if !photo.photographer.isEmpty {
                Text("© \(photo.photographer)")
                    .font(Theme.display(10, .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(8)
            }
        }
    }

    /// Origin → destination, with city names when the route resolved.
    private func routeCard(_ ac: SelectedAircraft) -> some View {
        HStack(spacing: 14) {
            endpoint(code: ac.origin, city: ac.originCity, alignment: .leading)
            VStack(spacing: 3) {
                Image(systemName: "airplane")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Rectangle()
                    .fill(Theme.accent.opacity(0.35))
                    .frame(height: 1)
            }
            .frame(maxWidth: .infinity)
            endpoint(code: ac.destination, city: ac.destinationCity, alignment: .trailing)
        }
        .padding(18)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func endpoint(code: String?, city: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(code ?? "—")
                .font(Theme.display(24, .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(city ?? " ")
                .font(Theme.display(12, .regular))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    private func statsGrid(_ ac: SelectedAircraft) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                  spacing: 14) {
            stat(ac.onGround ? "—" : "\(Int((ac.altitudeFeet / 100).rounded()) * 100) ft", "Altitude")
            stat(ac.groundSpeedKts.map { "\(Int($0.rounded())) kt" } ?? "—", "Ground speed")
            stat(ac.track.map { "\(compass($0)) \(Int($0.rounded()))°" } ?? "—", "Track")
            stat(String(format: "%.0f nm", ac.distanceNm), "Distance")
            stat("\(compass(ac.azimuth)) \(Int(ac.azimuth.rounded()))°", "Bearing")
            stat("\(Int(ac.elevation.rounded()))°", "Elevation")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(Theme.display(17, .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(label)
                .font(Theme.display(11, .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Airport detail sheet

struct AirportDetailSheet: View {
    let airport: SelectedAirport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(airport.iata)
                            .font(Theme.display(34, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(airport.name)
                            .font(Theme.display(16, .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                VStack(spacing: 0) {
                    infoRow("Location", "\(airport.city), \(airport.country)")
                    rowDivider
                    infoRow("ICAO / IATA", "\(airport.icao) / \(airport.iata)")
                    rowDivider
                    infoRow("Distance", String(format: "%.0f nm from you", airport.distanceNm))
                    rowDivider
                    infoRow("Bearing", "\(compass(airport.azimuth)) \(Int(airport.azimuth.rounded()))°")
                    rowDivider
                    infoRow("Coordinates", String(format: "%.4f°, %.4f°", airport.lat, airport.lon))
                }
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(24)
        }
        .scrollContentBackground(.hidden)
        .presentationDetents([.medium])
        .presentationBackground {
            Color.clear
                .glassEffect(.regular.tint(Theme.nightBottom.opacity(0.45)),
                             in: .rect(cornerRadius: 38))
        }
        .preferredColorScheme(.dark)
    }

    private var rowDivider: some View {
        Divider().overlay(.white.opacity(0.08)).padding(.leading, 16)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.display(14, .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(Theme.display(14, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// 16-point compass label for an azimuth in degrees.
func compass(_ degrees: Double) -> String {
    let dirs = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    let i = Int((degrees / 22.5).rounded()) % 16
    return dirs[(i + 16) % 16]
}

// MARK: - Profile (pushed inside the Sky sheet)

struct ProfileView: View {
    @Bindable var engine: SkyEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    MoonMark().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sky watcher")
                            .font(Theme.display(22, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Watching since day one")
                            .font(Theme.display(13, .regular))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                HStack(spacing: 12) {
                    statTile("\(engine.statFlightsSpotted)", "Flights spotted")
                    statTile("\(engine.favorites.count)", "Favorites")
                    statTile("\(engine.statDaysUsed)", "Days under the sky")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Favorite flights")
                        .font(Theme.display(16, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if engine.favorites.isEmpty {
                        Text("Tap the heart on any flight to keep it here. Favorites get a pink mark in the sky.")
                            .font(Theme.display(13, .regular))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(engine.favorites).sorted(), id: \.self) { callsign in
                                favoriteRow(callsign)
                                if callsign != Array(engine.favorites).sorted().last {
                                    Divider().overlay(.white.opacity(0.08)).padding(.leading, 16)
                                }
                            }
                        }
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }

                Text("Position data airplanes.live · routes adsbdb · photos planespotters.net\nAll stats live on this device only.")
                    .font(Theme.display(11, .regular))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(24)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(Theme.display(22, .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(Theme.display(11, .medium))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func favoriteRow(_ callsign: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.58))
            Text(callsign)
                .font(Theme.display(16, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                engine.focusedCallsign = callsign
            } label: {
                Label("Focus", systemImage: "scope")
                    .font(Theme.display(13, .semibold))
                    .foregroundStyle(engine.focusedCallsign == callsign
                                     ? Color(red: 1.0, green: 0.82, blue: 0.45) : Theme.accent)
            }
            Button {
                engine.toggleFavorite(callsign)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
            }
            .accessibilityLabel("Remove favorite")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

// MARK: - Sky events (pushed inside the Sky sheet)

struct EventsView: View {
    @Bindable var engine: SkyEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if engine.events.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.textTertiary)
                        Text("Reading the year ahead…")
                            .font(Theme.display(14, .regular))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 30)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(engine.events) { event in
                        NavigationLink {
                            EventDetailView(event: event)
                        } label: {
                            eventCard(event)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Eclipse circumstances are computed for your exact location.")
                        .font(Theme.display(11, .regular))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(24)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Sky events")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private let gold = Color(red: 1.0, green: 0.82, blue: 0.45)

    private func eventCard(_ event: SkyEvent) -> some View {
        let isEclipse = event.kind == .eclipse
        return HStack(alignment: .top, spacing: 14) {
            EventGlyph(kind: event.kind)
                .frame(width: 26, height: 26)
                .frame(width: 32)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title)
                        .font(Theme.display(isEclipse ? 18 : 16, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(countdown(to: event.date))
                        .font(Theme.display(13, .bold).monospacedDigit())
                        .foregroundStyle(isEclipse ? gold : Theme.accent)
                }
                Text(event.subtitle)
                    .font(Theme.display(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(event.date.formatted(date: .long, time: .shortened))
                    .font(Theme.display(12, .regular))
                    .foregroundStyle(Theme.textTertiary)
                Text(event.detail)
                    .font(Theme.display(12, .regular))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(16)
        .background(
            (isEclipse ? gold.opacity(0.07) : Color.white.opacity(0.04)),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if isEclipse {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(gold.opacity(0.35), lineWidth: 1)
            }
        }
    }

    private func countdown(to date: Date) -> String {
        let days = date.timeIntervalSinceNow / 86_400
        if days < 1 { return "today" }
        if days < 60 { return "\(Int(days))d" }
        return "\(Int(days / 30.44))mo"
    }
}

// MARK: - Calibration (pushed inside the Sky sheet)

struct CalibrationView: View {
    @Bindable var engine: SkyEngine

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Heading offset", trailing: String(format: "%.1f°", engine.headingOffsetDeg)) {
                        Slider(value: $engine.headingOffsetDeg, in: -20...20, step: 0.5)
                            .tint(Theme.accent)
                        Text("Nudge until a known plane lines up with the real sky. Corrects compass bias — planes move as you drag.")
                            .font(Theme.display(13, .regular))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Toggle(isOn: $engine.mirrorX) {
                        Text("Mirror horizontally")
                            .font(Theme.display(16, .medium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .tint(Theme.accentSoft)

                    section("Labels", trailing: nil) {
                        Picker("Labels", selection: $engine.labelMode) {
                            ForEach(SkyEngine.LabelMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    compassStatus
                }
                .padding(24)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Calibration")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, trailing: String?,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(Theme.display(16, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(Theme.display(16, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
            }
            content()
        }
    }

    private var compassStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.north.line.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(compassColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(compassTitle)
                    .font(Theme.display(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(compassHint)
                    .font(Theme.display(12, .regular))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var compassColor: Color {
        switch engine.compassQuality {
        case .good: return Theme.accent
        case .fair: return .yellow
        case .poor: return .orange
        case .unknown: return Theme.textTertiary
        }
    }

    private var compassTitle: String {
        switch engine.compassQuality {
        case .good: return "Compass: good"
        case .fair: return "Compass: fair"
        case .poor: return "Compass: poor"
        case .unknown: return "Compass: calibrating…"
        }
    }

    private var compassHint: String {
        switch engine.compassQuality {
        case .poor, .fair:
            return "Wave the phone in a figure-8 to recalibrate the compass."
        case .unknown:
            return "Heading not available yet — only on device."
        case .good:
            return engine.headingAccuracyDeg >= 0 ? "Accurate to ±\(Int(engine.headingAccuracyDeg))°" : "Heading locked."
        }
    }
}

// MARK: - Sky sheet (mode, layers, time scrub, calibration)

struct SkySheet: View {
    @Bindable var engine: SkyEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    modeSwitch

                    VStack(spacing: 0) {
                        row("Aircraft", "airplane", $engine.showAircraft,
                            subtitle: engine.trafficCount > 0 ? "\(engine.trafficCount) overhead" : nil)
                        divider
                        row("Sun", "sun.max.fill", $engine.showSun)
                        divider
                        row("Moon", "moon.fill", $engine.showMoon, subtitle: moonSubtitle)
                        divider
                        row("Planets", "circle.circle", $engine.showPlanets,
                            subtitle: "Mercury through Saturn")
                        divider
                        row("Stars", "sparkles", $engine.showStars)
                        divider
                        row("ISS", "diamond.fill", $engine.showISS,
                            subtitle: engine.issVisible ? "Overhead now" : nil)
                        divider
                        row("Aircraft trails", "wind", $engine.showTrails,
                            subtitle: "Fading path behind each plane")
                        divider
                        row("Airports", "airplane.arrival", $engine.showAirports,
                            subtitle: "Nearby fields on the horizon")
                        divider
                        row("Sky sounds", "speaker.wave.2.fill", $engine.soundOn,
                            subtitle: "Hear flyovers in 3D — best with AirPods")
                    }
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    if engine.showISS {
                        Button { engine.jumpToNextISSPass() } label: {
                            Label("Jump to next ISS pass", systemImage: "arrow.up.forward.circle.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }

                    timeScrub

                    calibrationLink
                }
                .padding(24)
            }
            .scrollContentBackground(.hidden)
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground {
            Color.clear
                .glassEffect(.regular.tint(Theme.nightBottom.opacity(0.45)),
                             in: .rect(cornerRadius: 38))
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Sky")
                .font(Theme.display(26, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if engine.trafficCount > 0 {
                Text("\(engine.trafficCount) aircraft")
                    .font(Theme.display(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.06), in: Capsule())
            }
            NavigationLink {
                ProfileView(engine: engine)
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 25))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityLabel("Profile")
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.textTertiary)
            }
            .accessibilityLabel("Close")
        }
    }

    /// AR sky ↔ dark sky, as a two-chip glass switch.
    private var modeSwitch: some View {
        HStack(spacing: 10) {
            modeChip("AR sky", "camera.fill", active: engine.cameraPassthrough) {
                engine.cameraPassthrough = true
            }
            modeChip("Dark sky", "moon.stars.fill", active: !engine.cameraPassthrough) {
                engine.cameraPassthrough = false
            }
        }
    }

    private func modeChip(_ title: String, _ icon: String, active: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                Text(title).font(Theme.display(15, .semibold))
            }
            .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Capsule())
            .glassEffect(active ? .regular.tint(Theme.accentSoft.opacity(0.45)) : .regular,
                         in: .capsule)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: active)
    }

    /// Push into the sky calendar.
    private var eventsLink: some View {
        NavigationLink {
            EventsView(engine: engine)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "calendar")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sky events")
                        .font(Theme.display(16, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(nextEventSubtitle)
                        .font(Theme.display(12, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var nextEventSubtitle: String {
        guard let next = engine.events.first else { return "Eclipses, meteor showers, full moons" }
        let days = max(0, Int(next.date.timeIntervalSinceNow / 86_400))
        return days == 0 ? "\(next.title) — today" : "\(next.title) in \(days) days"
    }

    /// Push into the full calibration controls.
    private var calibrationLink: some View {
        NavigationLink {
            CalibrationView(engine: engine)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Calibration")
                        .font(Theme.display(16, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(compassSubtitle)
                        .font(Theme.display(12, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var compassSubtitle: String {
        switch engine.compassQuality {
        case .good: return "Compass: good"
        case .fair: return "Compass: fair — figure-8 to improve"
        case .poor: return "Compass: poor — figure-8 to recalibrate"
        case .unknown: return "Heading offset, mirroring, labels"
        }
    }

    private var divider: some View { Divider().overlay(.white.opacity(0.08)).padding(.leading, 56) }

    private func row(_ title: String, _ icon: String, _ binding: Binding<Bool>, subtitle: String? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.display(16, .medium))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.display(12, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(Theme.accentSoft)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var moonSubtitle: String {
        "\(Int((engine.moonIllumination * 100).rounded()))% · \(engine.moonWaxing ? "waxing" : "waning")"
    }

    private var timeScrub: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sky time")
                    .font(Theme.display(16, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(TimeScrub.label(engine.skyTimeOffsetMin))
                    .font(Theme.display(15, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            Slider(value: $engine.skyTimeOffsetMin, in: -720...720, step: 5).tint(Theme.accent)
            HStack {
                Text("−12h").font(.caption2).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Now") { engine.skyTimeOffsetMin = 0 }.buttonStyle(GhostButtonStyle())
                Spacer()
                Text("+12h").font(.caption2).foregroundStyle(Theme.textTertiary)
            }
            Text("Scrub the sky forward or back to preview the sun, moon, stars and ISS at another time.")
                .font(Theme.display(12, .regular))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

enum TimeScrub {
    /// "Now", "+2h 15m", "−45m" … from a minute offset.
    static func label(_ minutes: Double) -> String {
        if abs(minutes) < 0.5 { return "Now" }
        let sign = minutes >= 0 ? "+" : "−"
        let total = Int(abs(minutes).rounded())
        let h = total / 60, m = total % 60
        if h > 0 && m > 0 { return "\(sign)\(h)h \(m)m" }
        if h > 0 { return "\(sign)\(h)h" }
        return "\(sign)\(m)m"
    }
}

// MARK: - Small controls

private struct CircleControl: View {
    let systemName: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
                .glassEffect(.regular, in: .circle)
        }
    }
}

private struct PulsingDot: View {
    var color: Color = Theme.accent
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color, radius: on ? 5 : 1)
            .opacity(on ? 1 : 0.5)
            .onAppear {
                guard !reduceMotion else { on = true; return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true }
            }
    }
}
