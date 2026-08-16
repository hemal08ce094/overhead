//
//  ARSkyScreen.swift
//  Skylight AR
//
//  Hosts ARSkyViewController and lays elegant, minimal chrome over it: a
//  liquid-glass cluster that blooms into profile / search / events /
//  calibration, a one-tap AR ↔ dark-sky toggle, tap-to-identify detail card,
//  and the calibration sheet.
//

import SwiftUI
import AVFoundation
import UserNotifications

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
    @State private var showProfile = false
    @State private var showEvents = false
    @State private var showSearch = false
    @State private var showAircraftDetail = false
    /// The chrome cluster: true while the glass orb is bloomed open.
    @State private var menuOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @State private var showMedals = false
    @State private var showPaywallShot = false
    #endif

    var body: some View {
        ZStack {
            ARSkyContainer(engine: engine)
                .ignoresSafeArea()

            // Subtle vignette keeps overlay chrome legible on a bright sky.
            LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.4)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // While the cluster is open, the whole sky is a close target —
            // a stray tap dismisses instead of selecting a plane behind it.
            if menuOpen {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { menuOpen = false }
            }

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    chromeCluster
                    Spacer()
                    if engine.zoomFactor > 1.05 { zoomPill }
                    if engine.skyTimeOffsetMin != 0 { timeOffsetPill }
                    arModeButton
                }
                .zIndex(3)
                if nudgeReady, let nudge = permissionNudge {
                    permissionNudgeBanner(nudge)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if engine.compassHintNeeded && !engine.compassHintDismissed {
                    compassHint
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if engine.realignSuggested && !engine.realignDismissed {
                    realignHint
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
                if let medal = engine.medals.pendingReveal {
                    medalBanner(medal)
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

            // A one-shot confetti blast the instant a medal unlocks, bursting
            // from behind its banner. Self-stops; silent under Reduce Motion.
            if let medal = engine.medals.pendingReveal {
                ConfettiBurst(seed: medal.id, accent: MedalArt.colors(medal.finish).thumbLight)
                    .allowsHitTesting(false)
            }

            if engine.calibrationStep != .idle {
                calibrationOverlay
            }

            #if DEBUG
            if engine.showAccuracyHUD {
                VStack {
                    Spacer()
                    AccuracyHUDView(engine: engine).padding(.bottom, 96)
                }
                .allowsHitTesting(false)
            }
            #endif
        }
        // Let the sky arrive first; the permission tip follows a beat later.
        .task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { nudgeReady = true }
        }
        // Key on the selection IDENTITY, not the struct: distance/azimuth
        // fields tick every feed update, and animating the whole chrome
        // overlay (over a live AR render) once a second is pure waste.
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: engine.selected?.hex)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: engine.medals.pendingReveal)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: engine.skyTimeOffsetMin != 0)
        .animation(.easeInOut(duration: 0.25), value: engine.calibrationStep)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showEvents) {
            NavigationStack { EventsView(engine: engine) }
                .presentationDetents([.medium, .large])
                .presentationBackground {
                    Color.clear
                        .glassEffectCompat(.regular.tint(Theme.nightBottom.opacity(0.45)),
                                     in: .rect(cornerRadius: 38))
                        .allowsHitTesting(false)
                }
                .preferredColorScheme(.dark)
        }
        // Profile is a full-screen destination, not a half sheet — its header
        // scene and pinned glass bar own the whole canvas.
        .fullScreenCover(isPresented: $showProfile) {
            NavigationStack { ProfileView(engine: engine) }
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSearch) {
            FlightSearchView(engine: engine)
                .presentationDetents([.large])
                .presentationBackground {
                    Color.clear
                        .glassEffectCompat(.regular.tint(Theme.nightBottom.opacity(0.45)),
                                     in: .rect(cornerRadius: 38))
                        .allowsHitTesting(false)
                }
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showAircraftDetail, onDismiss: { engine.deselect() }) {
            AircraftDetailSheet(engine: engine)
        }
        .sheet(item: Bindable(engine).selectedAirport) { airport in
            AirportDetailSheet(airport: airport)
        }
        .sheet(item: Bindable(engine).selectedBody) { body in
            BodyDetailSheet(body_: body, engine: engine)
        }
        // Tapping a plane opens the full sheet directly — no intermediate card.
        .onChange(of: engine.selected == nil) { _, deselected in
            showAircraftDetail = !deselected
        }
        // A calibration started from a settings sheet needs the live sky visible.
        .onChange(of: engine.calibrationStep) { _, step in
            if step != .idle { showProfile = false; showEvents = false; showSearch = false; menuOpen = false }
        }
        // While a full-screen chrome sheet covers the sky, pause the live-sky
        // simulation, rendering, and feed — no wasted CPU/GPU/network — and
        // resume the moment it's dismissed.
        .onChange(of: showProfile || showEvents || showSearch) { _, obscured in
            engine.controller?.setSkyObscured(obscured)
        }
        #if DEBUG
        .sheet(isPresented: $showMedals) {
            NavigationStack { MedalsOverviewView(engine: engine) }
        }
        .sheet(isPresented: $showPaywallShot) {
            NavigationStack { PaywallView(source: "shot") }
                .preferredColorScheme(.dark)
        }
        .onAppear {
            switch ShotScreen.current {
            case .events: showEvents = true
            case .profile: showProfile = true
            case .search: showSearch = true
            case .medals, .legend: showMedals = true
            case .viewsky: showProfile = true   // ProfileView auto-pushes View & sky
            case .paywall: showPaywallShot = true
            default: break
            }
            if UserDefaults.standard.bool(forKey: "accuracyHUD") {
                engine.showAccuracyHUD = true
            }
        }
        #endif
    }

    @ViewBuilder private var statusPill: some View {
        if engine.spotlightOnly, let searched = engine.focusedCallsign {
            // Search spotlight: only the searched plane is in the sky. The
            // offline cue must survive here — with every other plane hidden,
            // this pill is the only place a dead feed can show at all.
            HStack(spacing: 8) {
                if engine.feedOffline {
                    PulsingDot(color: .orange)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.gold)
                }
                Text(engine.feedOffline ? "Only \(searched) — no connection" : "Only \(searched)")
                    .font(Theme.display(14, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Button {
                    engine.spotlightOnly = false      // back to the full sky, still tracking
                } label: {
                    Text("Show all")
                        .font(Theme.display(13, .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .contentShape(Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .glassEffectCompat(.regular.tint(Theme.gold.opacity(0.12)), in: .capsule)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(engine.feedOffline
                ? "No connection. Showing only \(searched). Show all planes."
                : "Showing only \(searched). Show all planes.")
        } else {
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
            .glassEffectCompat(.regular, in: .capsule)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(engine.feedOffline
                ? "No connection. Showing sky only."
                : "Scanning the sky. \(engine.trafficCount) aircraft overhead.")
        }
    }

    private var statusText: String {
        if engine.feedOffline { return String(localized: "Sky only — no connection") }
        if engine.usingDemoLocation { return String(localized: "Demo sky") }
        return String(localized: "Scanning the sky")
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
            .glassEffectCompat(.regular.tint(Theme.accent.opacity(0.85)), in: .capsule)
        }
        .accessibilityLabel("Sky time shifted \(timeOffsetText). Return to now.")
    }

    private var timeOffsetText: String { TimeScrub.label(engine.skyTimeOffsetMin) }

    /// The marquee moment: a plane is about to cross the moon or sun.
    private func transitBanner(_ transit: TransitPrediction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: transit.body == .moon ? "moon.fill" : "sun.max.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.gold)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(transit.callsign) crosses the \(transit.body.displayName)")
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
                    .foregroundStyle(Theme.gold)
            } else {
                Text("NOW")
                    .font(Theme.display(15, .bold))
                    .foregroundStyle(Theme.gold)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassEffectCompat(.regular.tint(Theme.gold.opacity(0.18)),
                     in: .rect(cornerRadius: 20))
    }

    /// A medal just unlocked — quiet gold banner; tap to see it on the shelf.
    private func medalBanner(_ medal: Medal) -> some View {
        Button {
            engine.medals.pendingReveal = nil
            showProfile = true
        } label: {
            HStack(spacing: 12) {
                MedalThumb(medal: medal, earnedDate: Date(), progress: medal.target, target: medal.target)
                    .scaleEffect(0.62)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Medal earned")
                        .font(Theme.display(12, .semibold))
                        .foregroundStyle(Theme.gold)
                    Text(medal.name)
                        .font(Theme.display(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 8)
                Button {
                    engine.medals.pendingReveal = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Dismiss medal banner")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
            .glassEffectCompat(.regular.tint(Theme.gold.opacity(0.16)), in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Medal earned: \(medal.name). Opens your medals.")
    }

    /// Big gold shutter for the crossing moment.
    private var shutterButton: some View {
        HStack {
            Spacer()
            Button { engine.captureShareCard(); Analytics.log("Transit.shutterTapped") } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.gold)
                    .frame(width: 68, height: 68)
                    .contentShape(Circle())
                    .glassEffectCompat(.regular.tint(Theme.gold.opacity(0.25)),
                                 in: .circle)
            }
            .accessibilityLabel("Capture the crossing")
            Spacer()
        }
    }

    /// Which missing permission to gently surface, if any. Camera first — it
    /// IS the AR experience — but only while the user actually wants AR mode
    /// (a deliberate dark-sky user is never nagged about the camera). One
    /// nudge at a time; dismissing hides it for the session.
    private enum PermissionNudge { case camera, location }
    private var permissionNudge: PermissionNudge? {
        guard !engine.permissionNudgeDismissed, engine.calibrationStep == .idle else { return nil }
        if engine.cameraPassthrough,
           AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            return .camera
        }
        if engine.usingDemoLocation { return .location }
        return nil
    }

    /// Give the sky a breath before nudging — a banner in the first frames
    /// reads as a permission fight, a few seconds in it reads as a tip.
    @State private var nudgeReady = false

    private func permissionNudgeBanner(_ nudge: PermissionNudge) -> some View {
        HStack(spacing: 10) {
            Image(systemName: nudge == .camera ? "camera.fill" : "location.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(nudge == .camera
                 ? "Turn on the camera to see planes on your real sky"
                 : "This is the demo sky — turn on Location to see yours")
                .font(Theme.display(13, .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Button {
                enablePermission(nudge)
            } label: {
                Text("Turn on")
                    .font(Theme.display(13, .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Capsule())
            }
            Button { engine.permissionNudgeDismissed = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Dismiss permission hint")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffectCompat(.regular.tint(Theme.accentSoft.opacity(0.18)), in: .capsule)
    }

    /// Never-asked permissions get the system prompt right here; denied ones
    /// can only be flipped in Settings, so that's where the button goes.
    private func enablePermission(_ nudge: PermissionNudge) {
        engine.permissionNudgeDismissed = true
        switch nudge {
        case .camera:
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                Task {
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    // Swap the motion sky for a live ARKit session on the
                    // spot — granting from the banner should feel instant.
                    if granted { engine.controller?.cameraAccessChanged() }
                }
            } else if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .location:
            if engine.controller?.locationAskable == true {
                engine.controller?.requestLocationAccess()
            } else if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    /// A quiet nudge when the magnetometer has been struggling for a while.
    private var compassHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.north.line.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Compass looks off")
                .font(Theme.display(13, .medium))
                .foregroundStyle(Theme.textPrimary)
            Button {
                engine.compassHintDismissed = true
                engine.beginCalibration()
            } label: {
                Text("Calibrate")
                    .font(Theme.display(13, .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Capsule())
            }
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
        .glassEffectCompat(.regular.tint(.orange.opacity(0.15)), in: .capsule)
    }

    /// Offered after returning from the background: tracking may have shifted,
    /// so nudge a quick re-align rather than letting the sky sit slightly off.
    private var realignHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.north.line.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Welcome back — re-align the sky?")
                .font(Theme.display(13, .medium))
                .foregroundStyle(Theme.textPrimary)
            Button {
                engine.realignDismissed = true
                withAnimation { engine.beginQuickAlign() }
            } label: {
                Text("Re-align")
                    .font(Theme.display(13, .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Capsule())
            }
            Button { engine.realignDismissed = true } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Dismiss re-align")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffectCompat(.regular.tint(Theme.accentSoft.opacity(0.18)), in: .capsule)
    }

    /// Guided heading calibration: 360° sweep, then a precise lock.
    private var calibrationOverlay: some View {
        ZStack {
            if engine.calibrationStep == .scanning {
                Color.black.opacity(0.55).ignoresSafeArea()
            }
            VStack {
                Spacer()
                Group {
                    if engine.calibrationStep == .scanning { scanCard } else { alignCard }
                }
                .padding(22)
                .frame(maxWidth: .infinity)
                .glassEffectCompat(.regular, in: .rect(cornerRadius: 30))
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
        }
        .transition(.opacity)
    }

    private var scanCard: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 6)
                Circle().trim(from: 0, to: max(0.02, engine.calibrationScanProgress))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 92, height: 92)
            .animation(.easeOut(duration: 0.3), value: engine.calibrationScanProgress)

            Text("Sweep slowly in a full circle")
                .font(Theme.display(18, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Turn your whole body, keeping the phone raised at the sky. This recalibrates the compass and learns true north.")
                .font(Theme.display(13, .regular))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Cancel") { withAnimation { engine.cancelCalibration() } }
                    .buttonStyle(GhostButtonStyle())
                Button("Skip to lock") { withAnimation { engine.skipCalibrationScan() } }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var alignCard: some View {
        VStack(spacing: 14) {
            Image(systemName: engine.calibrationSunUp ? "sun.max.fill"
                  : (engine.calibrationMoonUp ? "moon.fill" : "hand.draw.fill"))
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Lock it in")
                .font(Theme.display(18, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(alignInstruction)
                .font(Theme.display(13, .regular))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            if engine.calibrationSunUp {
                Button { withAnimation { engine.lockToSun() } } label: {
                    Label("Pointing at the Sun — Lock", systemImage: "sun.max.fill")
                }.buttonStyle(PrimaryButtonStyle())
            } else if engine.calibrationMoonUp {
                Button { withAnimation { engine.lockToMoon() } } label: {
                    Label("Pointing at the Moon — Lock", systemImage: "moon.fill")
                }.buttonStyle(PrimaryButtonStyle())
            }

            // All-weather solve: pin a selected plane's known bearing. Secondary
            // when a Sun/Moon lock is already offered, primary otherwise.
            if let sel = engine.selected {
                let label = Label("Centre \(sel.callsign) — Lock to plane", systemImage: "airplane")
                if engine.calibrationSunUp || engine.calibrationMoonUp {
                    Button { withAnimation { engine.lockToSelectedAircraft() } } label: { label }
                        .buttonStyle(GhostButtonStyle())
                } else {
                    Button { withAnimation { engine.lockToSelectedAircraft() } } label: { label }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }

            HStack(spacing: 10) {
                Button("Cancel") { withAnimation { engine.cancelCalibration() } }
                    .buttonStyle(GhostButtonStyle())
                Button("Done") { withAnimation { engine.finishCalibration() } }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var alignInstruction: String {
        if engine.calibrationSunUp {
            return String(localized: "Aim the center of your screen right at the Sun, then tap Lock. Or drag the sky to slide a plane onto its real position, and tap Done.")
        }
        if engine.calibrationMoonUp {
            return String(localized: "Aim the center of your screen right at the Moon, then tap Lock. Or drag the sky to slide a plane onto its real position, and tap Done.")
        }
        if engine.selected != nil {
            return String(localized: "Center the real plane on screen and tap Lock to plane — its exact bearing snaps the sky into place. Or drag the sky until a plane sits where you see it, then tap Done.")
        }
        return String(localized: "Drag the sky left or right until a plane sits exactly where you see it in the air, then tap Done.")
    }

    // MARK: Chrome cluster

    /// One glass orb, top-left, that blooms into the four chrome controls —
    /// profile, search, events, calibration — along a quarter circle. The
    /// drops emerge from the orb and retract into it, so the controls always
    /// visibly live inside the one button. Order matches the old chrome:
    /// profile nearest its old corner, calibration out by the pills.
    private var chromeCluster: some View {
        GlassEffectContainerCompat(spacing: 22) {
            ZStack(alignment: .topLeading) {
                // Only exist while open: a hidden-but-present drop still draws
                // its glass on the container's shared layer and ghosts through
                // the closed orb.
                if menuOpen {
                    satellite(0, profileButton)
                    satellite(1, searchButton)
                    satellite(2, eventsBell)
                    satellite(3, alignButton)
                }
                clusterHub
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: menuOpen)
    }

    private var clusterHub: some View {
        Button {
            withAnimation { menuOpen.toggle() }
        } label: {
            Image(systemName: menuOpen ? "xmark" : "airplane")
                .font(.system(size: 18, weight: .semibold))
                .rotationEffect(.degrees(menuOpen ? 0 : -90))   // nose to the sky
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffectCompat(.regular.interactive(), in: .circle)
                .overlay(alignment: .topTrailing) {
                    // The bell's imminent-event dot surfaces on the closed orb
                    // so the calendar still announces itself from inside.
                    if let soon = imminentEvent, !menuOpen {
                        Circle().fill(soon.kind.tint)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Theme.nightBottom, lineWidth: 1.5))
                            .offset(x: -4, y: 5)
                    }
                }
        }
        .accessibilityLabel(menuOpen ? String(localized: "Close menu") : String(localized: "Menu"))
        .accessibilityHint(menuOpen ? "" : String(localized: "Profile, flight search, sky events and calibration"))
    }

    /// Places one control on the bloom arc: 90° is straight down, 0° is
    /// straight right. Travel and scale ride one spring with a whisper of
    /// stagger (reversed on close, so the farthest drop returns first);
    /// under Reduce Motion the drops simply fade in place.
    private func satellite(_ index: Int, _ content: some View) -> some View {
        let angle = (90 - Double(index) * 30) * .pi / 180
        let dx = 88 * CGFloat(cos(angle))
        let dy = 88 * CGFloat(sin(angle))
        let bloom = AnyTransition.offset(x: -dx, y: -dy)
            .combined(with: .scale(scale: 0.4))
            .combined(with: .opacity)
        return content
            .offset(x: dx, y: dy)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: bloom.animation(.spring(response: 0.38, dampingFraction: 0.8)
                    .delay(Double(index) * 0.04)),
                removal: bloom.animation(.spring(response: 0.38, dampingFraction: 0.8)
                    .delay(Double(3 - index) * 0.04))))
    }

    /// One tap between the camera's real sky and the dark-sky map — the
    /// choice the old chrome buried in a settings sheet. Sits where the bell
    /// used to. No motion beyond the symbol swap: this is a many-times-a-day
    /// switch, and the sky itself is the feedback.
    private var arModeButton: some View {
        Button { toggleARMode() } label: {
            Image(systemName: engine.cameraPassthrough ? "camera.fill" : "moon.stars.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(engine.cameraPassthrough ? Theme.accent : Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffectCompat(.regular, in: .circle)
                .contentTransition(.symbolEffect(.replace))
        }
        .sensoryFeedback(.impact(weight: .light), trigger: engine.cameraPassthrough)
        .accessibilityLabel(engine.cameraPassthrough
                            ? String(localized: "AR sky is on. Switch to dark sky.")
                            : String(localized: "Dark sky is on. Switch to AR sky."))
    }

    private func toggleARMode() {
        if engine.cameraPassthrough {
            engine.cameraPassthrough = false
            Analytics.log("Mode.selected", ["mode": "dark", "source": "chrome"])
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            engine.cameraPassthrough = true
            Analytics.log("Mode.selected", ["mode": "ar", "source": "chrome"])
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if granted {
                    engine.cameraPassthrough = true
                    engine.controller?.cameraAccessChanged()
                    Analytics.log("Mode.selected", ["mode": "ar", "source": "chrome"])
                }
            }
        default:
            // Denied: requesting again is a no-op — Settings is the only path.
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    /// Top-right bell — the sky calendar, one tap from anywhere.
    /// Top-right entry to flight search.
    private var searchButton: some View {
        Button { menuOpen = false; showSearch = true; Analytics.log("Search.opened") } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffectCompat(.regular, in: .circle)
        }
        .accessibilityLabel("Find a flight")
    }

    /// Something within 48 h lights a dot on the bell in the event's colour —
    /// the calendar announces itself only when it has something to say.
    private var imminentEvent: SkyEvent? {
        engine.events.first { $0.date.timeIntervalSinceNow < 48 * 3600 }
    }

    private var eventsBell: some View {
        Button { menuOpen = false; showEvents = true; Analytics.log("Events.opened") } label: {
            Image(systemName: "bell")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffectCompat(.regular, in: .circle)
                .overlay(alignment: .topTrailing) {
                    if let soon = imminentEvent {
                        Circle().fill(soon.kind.tint)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Theme.nightBottom, lineWidth: 1.5))
                            .offset(x: -4, y: 5)
                    }
                }
        }
        .accessibilityLabel(imminentEvent.map { String(localized: "Sky events. \($0.title) within two days.") }
                            ?? String(localized: "Sky events"))
    }

    /// Alignment-confidence chip: the icon's tint reflects how trustworthy the
    /// current heading is (green good → orange poor), and a dot marks a held
    /// manual lock. Tapping opens the tap/drag heading fix on the live screen.
    private var alignButton: some View {
        Button { menuOpen = false; withAnimation { engine.beginQuickAlign() } } label: {
            Image(systemName: "location.north.line.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(alignTint)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffectCompat(.regular, in: .circle)
                .overlay(alignment: .topTrailing) {
                    if !engine.autoAlignEnabled {            // a manual lock is held
                        Circle().fill(Theme.accent)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Theme.nightBottom, lineWidth: 1.5))
                            .offset(x: -3, y: 5)
                    }
                }
        }
        .accessibilityLabel(alignAccessibility)
    }

    private var alignTint: Color {
        switch engine.compassQuality {
        case .good:    return Theme.accent
        case .fair:    return Theme.gold
        case .poor:    return .orange
        case .unknown: return Theme.textSecondary
        }
    }

    private var alignAccessibility: String {
        let base: String
        switch engine.compassQuality {
        case .good:    base = String(localized: "Heading looks good")
        case .fair:    base = String(localized: "Heading is approximate")
        case .poor:    base = String(localized: "Heading is unreliable")
        case .unknown: base = String(localized: "Heading not yet known")
        }
        if let s = engine.secondsSinceAlign, !engine.autoAlignEnabled {
            return String(localized: "\(base). Aligned \(Int(s)) seconds ago. Fix alignment.")
        }
        return String(localized: "\(base). Fix sky alignment.")
    }

    /// Top-left entry to the profile sheet.
    private var profileButton: some View {
        Button { menuOpen = false; showProfile = true; Analytics.log("Profile.opened") } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffectCompat(.regular, in: .circle)
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
        .glassEffectCompat(.regular.tint(Theme.accentSoft.opacity(0.25)), in: .capsule)
    }

    /// Shown while pinch-zoomed; tap to snap back to 1×.
    private var zoomPill: some View {
        Button { engine.resetZoom() } label: {
            Text(String(format: "%.1f×", engine.zoomFactor))
                .font(Theme.display(13, .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Capsule())
                .glassEffectCompat(.regular, in: .capsule)
        }
        .accessibilityLabel("Zoomed to \(String(format: "%.1f", engine.zoomFactor)) times. Reset zoom.")
    }

    /// Bottom edge: just the live status — everything else lives in Profile.
    private var controls: some View {
        HStack(alignment: .center) {
            statusPill
            Spacer()
        }
    }
}

// MARK: - Flight search

/// Search the sky by flight, tail, type, or squawk. In-view matches resolve
/// instantly from the live feed; "Anywhere" reaches any aircraft globally.
/// Picking a result links it to the track (focus) system.
struct FlightSearchView: View {
    @Bindable var engine: SkyEngine
    @Environment(\.dismiss) private var dismiss

    @State private var field: AircraftSearchField = .callsign
    @State private var query = ""
    @State private var inView: [SearchResult] = []
    @State private var anywhere: [SearchResult] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Search by", selection: $field) {
                    ForEach(AircraftSearchField.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                searchField

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            idleState
                        }
                        if !inView.isEmpty {
                            section(String(localized: "In view now"), inView)
                        }
                        if searching && anywhere.isEmpty {
                            HStack(spacing: 10) {
                                ProgressView().tint(Theme.accent)
                                Text("Searching anywhere…")
                                    .font(Theme.display(13, .regular))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.top, 4)
                        }
                        if !anywhere.isEmpty {
                            section(String(localized: "Anywhere"), anywhere)
                        }
                        if shouldShowEmpty {
                            emptyState
                        }
                    }
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .padding(20)
            .navigationTitle("Find a flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(Theme.accent)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in runSearch() }
        .onChange(of: field) { _, _ in runSearch() }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField(field.placeholder, text: $query)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($fieldFocused)
                .foregroundStyle(Theme.textPrimary)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .glassEffectCompat(.regular, in: .capsule)
    }

    private func section(_ title: String, _ results: [SearchResult]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { idx, r in
                    Button { pick(r) } label: { row(r) }
                    if idx < results.count - 1 { settingsDivider }
                }
            }
            .nightCard()
        }
    }

    private func row(_ r: SearchResult) -> some View {
        HStack(spacing: 12) {
            Image(systemName: r.onGround ? "airplane.arrival" : "airplane")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(r.inView ? Theme.accent : Theme.textSecondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title)
                    .font(Theme.display(16, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle = rowSubtitle(r) {
                    Text(subtitle)
                        .font(Theme.display(12, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if r.inView {
                    Text("In view")
                        .font(Theme.display(11, .semibold))
                        .foregroundStyle(Theme.accent)
                } else if let d = r.distanceNm {
                    Text(String(format: "%.0f nm", d))
                        .font(Theme.display(12, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                if r.altitudeFeet > 0, !r.onGround {
                    Text("FL\(Int((r.altitudeFeet / 100).rounded()))")
                        .font(Theme.display(11, .regular).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                } else if r.onGround {
                    Text("on ground")
                        .font(Theme.display(11, .regular))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func rowSubtitle(_ r: SearchResult) -> String? {
        var parts: [String] = []
        if let airline = r.airline { parts.append(airline) }
        if let type = r.type { parts.append(type) }
        if let reg = r.registration, reg != r.title { parts.append(reg) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var shouldShowEmpty: Bool {
        query.trimmingCharacters(in: .whitespaces).count >= 2
            && !searching && inView.isEmpty && anywhere.isEmpty
    }

    /// Before any typing: favorites within reach and worked examples, so the
    /// sheet invites a search instead of opening onto a void.
    private var idleState: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !engine.favorites.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "Favorites"))
                    chipRow(Array(engine.favorites).sorted()) { favorite in
                        field = .callsign
                        query = favorite
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(String(localized: "Try"))
                chipRow(field.placeholder.components(separatedBy: ", ")) { example in
                    query = example
                }
            }
            Text(fieldHint)
                .font(Theme.display(12, .regular))
                .foregroundStyle(Theme.textTertiary)
                .lineSpacing(2)
        }
        .padding(.top, 6)
    }

    private func chipRow(_ items: [String], onTap: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button { onTap(item) } label: {
                        Text(item)
                            .font(Theme.display(14, .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .contentShape(Capsule())
                            .glassEffectCompat(.regular, in: .capsule)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private var fieldHint: String {
        switch field {
        case .callsign:
            return String(localized: "A flight number reaches any aircraft in the world — type it as printed on your ticket.")
        case .registration:
            return String(localized: "A tail number follows one specific airframe wherever it flies.")
        case .type:
            return String(localized: "An aircraft type finds every one aloft nearby — A388 is the A380.")
        case .squawk:
            return String(localized: "Squawk codes are what pilots dial for ATC — 7700 is a declared emergency.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "binoculars")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("No \(field.title.lowercased()) match for “\(query)”.")
                .font(Theme.display(14, .regular))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if field == .callsign || field == .registration {
                let example = field.placeholder.components(separatedBy: ",").first ?? ""
                Text(field == .callsign
                     ? "A global match needs the full flight number — e.g. \(example)."
                     : "A global match needs the full tail — e.g. \(example).")
                    .font(Theme.display(12, .regular))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 24)
    }

    private func pick(_ r: SearchResult) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        engine.track(r)
        dismiss()
    }

    /// In-view filtering is instant on every keystroke; the global lookup is
    /// debounced so we don't hammer the rate-limited feed.
    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        inView = engine.searchInView(field: field, query: q)
        searchTask?.cancel()
        guard q.count >= 2 else { anywhere = []; searching = false; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            let results = await engine.searchAnywhere(field: field, value: q)
            if Task.isCancelled { return }
            let seen = Set(inView.map(\.hex))
            anywhere = results.filter { !seen.contains($0.hex) }
            searching = false
        }
    }
}

// MARK: - Aircraft detail sheet (expanded)

/// Everything we know about the selected flight, live-updating each poll.
struct AircraftDetailSheet: View {
    @Bindable var engine: SkyEngine
    @Environment(\.dismiss) private var dismiss
    // Two-stage dismissal: a downward swipe settles on a compact strip
    // (callsign + airline, sky live and tappable behind it) instead of
    // closing; a further swipe from the strip dismisses for real. The
    // selection resets on each presentation so every plane opens at the
    // half card, not wherever the last drag left the sheet.
    @State private var detent: PresentationDetent = .medium
    private static let mini = PresentationDetent.height(132)

    var body: some View {
        Group {
            if let ac = engine.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header(ac)
                        if let emergency = emergencyMeaning(ac.squawk) { emergencyCard(ac, meaning: emergency) }
                        if let photo = engine.selectedPhoto { photoCard(photo) }
                        if ac.airline != nil || ac.destination != nil { routeCard(ac) }
                        if let arrival = ac.observedArrival { arrivalCard(ac, arrival: arrival) }
                        statsGrid(ac)
                        Text("Live position via airplanes.live / adsb.lol · route via adsbdb · photos via planespotters.net")
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
        .presentationDetents([Self.mini, .medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: Self.mini))
        .presentationBackground {
            Color.clear
                .glassEffectCompat(.regular.tint(Theme.nightBottom.opacity(0.45)),
                             in: .rect(cornerRadius: 38))
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
        .onAppear { detent = .medium }
    }

    private func header(_ ac: SelectedAircraft) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(ac.callsign)
                    .font(Theme.display(30, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text([ac.airline, ac.type, ac.registration].compactMap(\.self).joined(separator: "  ·  "))
                    .font(Theme.display(15, .medium))
                    .foregroundStyle(Theme.textSecondary)
                if let phase = phase(ac) {
                    Label(phase.text, systemImage: phase.icon)
                        .font(Theme.display(13, .medium).monospacedDigit())
                        .foregroundStyle(phase.color)
                        .padding(.top, 2)
                }
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
                                     ? Theme.gold
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

    /// One human line for what the plane is *doing* — climbing, descending or
    /// cruising — from vertical rate and altitude. Small rates read as level
    /// flight; at cruise altitudes the level line speaks flight levels.
    private func phase(_ ac: SelectedAircraft) -> (text: String, icon: String, color: Color)? {
        if ac.onGround {
            return (String(localized: "On the ground"), "airplane", Theme.textTertiary)
        }
        let vr = ac.verticalRateFpm ?? 0
        let rate = "\(Int(abs(vr).rounded()).formatted()) ft/min"
        if vr >= 500 {
            return (String(localized: "Climbing · \(rate)"), "arrow.up.right", Theme.accent)
        }
        if vr <= -500 {
            let text = ac.altitudeFeet < 5000
                ? String(localized: "On approach · \(rate)")
                : String(localized: "Descending · \(rate)")
            return (text, "arrow.down.right", Color(red: 1.00, green: 0.75, blue: 0.40))
        }
        guard ac.altitudeFeet > 0 else { return nil }
        return ac.altitudeFeet >= 18_000
            ? (String(localized: "Cruising at FL\(Int((ac.altitudeFeet / 100).rounded()))"), "arrow.right", Theme.textSecondary)
            : (String(localized: "Level at \(Int((ac.altitudeFeet / 100).rounded()) * 100) ft"), "arrow.right", Theme.textSecondary)
    }

    /// The three transponder codes every spotter knows. Anything else stays
    /// off the sheet — routine squawks are noise.
    private func emergencyMeaning(_ squawk: String?) -> String? {
        switch squawk {
        case "7500": return String(localized: "hijack alert")
        case "7600": return String(localized: "radio failure")
        case "7700": return String(localized: "general emergency")
        default:     return nil
        }
    }

    private func emergencyCard(_ ac: SelectedAircraft, meaning: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.top, 1)
            Text("Squawking \(ac.squawk ?? "") — \(meaning). This aircraft has declared an emergency.")
                .font(Theme.display(13, .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.red.opacity(0.35), lineWidth: 1))
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

    /// Physics doesn't lie: when the plane is visibly on approach, confirm or
    /// contradict the filed route (callsign routes are often one leg of a
    /// multi-stop flight, or outdated).
    private func arrivalCard(_ ac: SelectedAircraft, arrival: String) -> some View {
        let city = ac.observedArrivalCity.map { " (\($0))" } ?? ""
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "airplane.arrival")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ac.routeMismatch ? .orange : Theme.accent)
                .padding(.top, 1)
            Text(ac.routeMismatch
                 ? "Landing now at \(arrival)\(city). The filed route above is likely a different leg of this flight, or out of date."
                 : "Arriving at \(arrival)\(city) now.")
                .font(Theme.display(13, .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((ac.routeMismatch ? Color.orange.opacity(0.08) : Color.white.opacity(0.04)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Origin → destination. With both endpoints located, the card becomes the
    /// route arc — the plane riding the curve at its true progress; otherwise
    /// it falls back to the simple divider layout.
    @ViewBuilder private func routeCard(_ ac: SelectedAircraft) -> some View {
        if let oLat = ac.originLat, let oLon = ac.originLon,
           let dLat = ac.destLat, let dLon = ac.destLon {
            let fraction = RouteProgress.fraction(planeLat: ac.lat, planeLon: ac.lon,
                                                  originLat: oLat, originLon: oLon,
                                                  destLat: dLat, destLon: dLon)
            VStack(spacing: 4) {
                RouteArc(progress: fraction)
                    .frame(height: 64)
                    .padding(.horizontal, 6)
                    .padding(.top, 8)
                HStack(alignment: .top) {
                    endpoint(code: ac.origin, city: ac.originCity, alignment: .leading)
                    Spacer(minLength: 12)
                    endpoint(code: ac.destination, city: ac.destinationCity, alignment: .trailing)
                }
                if let footer = routeFooter(ac, destLat: dLat, destLon: dLon) {
                    Text(footer)
                        .font(Theme.display(12, .medium).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)
                }
            }
            .padding(18)
            .nightCard()
        } else {
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
            .nightCard()
        }
    }

    /// "1,204 nm to go · about 2 h 40 m" — distance from live position,
    /// time at current ground speed (omitted when slow or unknown).
    private func routeFooter(_ ac: SelectedAircraft, destLat: Double, destLon: Double) -> String? {
        let toGo = RouteProgress.distanceNm(ac.lat, ac.lon, destLat, destLon)
        guard toGo > 5 else { return nil }
        let distance = Int(toGo.rounded()).formatted()
        if let gs = ac.groundSpeedKts, gs > 80, !ac.onGround {
            let hours = toGo / gs
            let h = Int(hours)
            let m = Int((hours - Double(h)) * 60)
            return h > 0
                ? String(localized: "\(distance) nm to go · about \(h) h \(String(format: "%02d", m)) m")
                : String(localized: "\(distance) nm to go · about \(m) m")
        }
        return String(localized: "\(distance) nm to go")
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
            stat(ac.onGround ? "—" : "\(Int((ac.altitudeFeet / 100).rounded()) * 100) ft", String(localized: "Altitude"))
            stat(ac.groundSpeedKts.map { "\(Int($0.rounded())) kt" } ?? "—", String(localized: "Ground speed"))
            stat(ac.track.map { "\(compass($0)) \(Int($0.rounded()))°" } ?? "—", String(localized: "Track"))
            stat(String(format: "%.0f nm", ac.distanceNm), String(localized: "Distance"))
            stat("\(compass(ac.azimuth)) \(Int(ac.azimuth.rounded()))°", String(localized: "Bearing"))
            stat("\(Int(ac.elevation.rounded()))°", String(localized: "Elevation"))
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
        .nightCard(cornerRadius: 14)
    }
}

// MARK: - Airport detail sheet

struct AirportDetailSheet: View {
    let airport: SelectedAirport
    @Environment(\.dismiss) private var dismiss
    @State private var weather = AirportWeather.shared
    @State private var showRawMetar = false

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
                    if case .loaded(let m) = weather.state, let cat = m.fltCat {
                        flightCategoryChip(cat)
                    }
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                liveWeatherCard
                trafficCard

                VStack(spacing: 0) {
                    infoRow(String(localized: "Location"), "\(airport.city), \(airport.country)")
                    rowDivider
                    infoRow(String(localized: "ICAO / IATA"), "\(airport.icao) / \(airport.iata)")
                    rowDivider
                    infoRow(String(localized: "Distance"),
                            String(format: String(localized: "%.0f nm from you"), airport.distanceNm))
                    rowDivider
                    infoRow(String(localized: "Bearing"), "\(compass(airport.azimuth)) \(Int(airport.azimuth.rounded()))°")
                    rowDivider
                    infoRow(String(localized: "Coordinates"), String(format: "%.4f°, %.4f°", airport.lat, airport.lon))
                }
                .nightCard()

                if case .loaded(let m) = weather.state, let raw = m.rawOb {
                    Button { withAnimation { showRawMetar.toggle() } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("METAR")
                                    .font(Theme.display(11, .bold)).tracking(1.5)
                                    .foregroundStyle(Theme.textTertiary)
                                Spacer()
                                Image(systemName: showRawMetar ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            if showRawMetar {
                                Text(verbatim: raw)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .nightCard()
                }
            }
            .padding(24)
        }
        .task(id: airport.icao) { weather.load(icao: airport.icao) }
        .scrollContentBackground(.hidden)
        .presentationDetents([.medium, .large])
        .presentationBackground {
            Color.clear
                .glassEffectCompat(.regular.tint(Theme.nightBottom.opacity(0.45)),
                             in: .rect(cornerRadius: 38))
                .allowsHitTesting(false)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Live field weather (NOAA METAR)

    private func flightCategoryChip(_ cat: String) -> some View {
        let color: Color = switch cat {
        case "VFR": Color(red: 0.35, green: 0.85, blue: 0.55)
        case "MVFR": Theme.accent
        case "IFR": Color(red: 0.95, green: 0.45, blue: 0.40)
        default: Color(red: 0.85, green: 0.45, blue: 0.85)   // LIFR
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(verbatim: cat)
                .font(Theme.display(11, .bold)).tracking(1)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
    }

    @ViewBuilder private var liveWeatherCard: some View {
        switch weather.state {
        case .loaded(let m):
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(String(localized: "Right now"))
                    .padding(.horizontal, 16).padding(.top, 12)
                if let spd = m.wspd {
                    HStack(spacing: 6) {
                        if case .degrees(let deg) = m.wdir {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.accent)
                                .rotationEffect(.degrees(deg + 180))  // blowing toward
                        }
                        Text(windLabel(m, speed: spd))
                            .font(Theme.display(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .overlay(alignment: .leading) {
                        Text("Wind")
                            .font(Theme.display(14, .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 16)
                    }
                    rowDivider
                }
                if let ceiling = m.ceiling, let base = ceiling.base {
                    infoRow(String(localized: "Ceiling"),
                            "\(cloudName(ceiling.cover)) \(Int(base).formatted()) ft")
                    rowDivider
                } else if m.clouds?.isEmpty == false {
                    infoRow(String(localized: "Clouds"), cloudName(m.clouds?.first?.cover))
                    rowDivider
                }
                if let vis = m.visib {
                    infoRow(String(localized: "Visibility"), visLabel(vis))
                    rowDivider
                }
                if let temp = m.temp {
                    infoRow(String(localized: "Temperature"),
                            m.dewp.map { String(localized: "\(Int(temp.rounded()))° · dew \(Int($0.rounded()))°") }
                                ?? "\(Int(temp.rounded()))°")
                    rowDivider
                }
                if let altim = m.altim {
                    infoRow(String(localized: "Pressure"), "\(Int(altim.rounded())) hPa")
                }
                if let observed = m.observed {
                    Text(String(localized: "observed \(observed.formatted(.relative(presentation: .named)))"))
                        .font(Theme.display(11, .regular))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 4)
                }
            }
            .nightCard()
        case .loading:
            HStack(spacing: 10) {
                ProgressView().tint(Theme.textTertiary)
                Text("Fetching field weather…")
                    .font(Theme.display(13, .regular))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .nightCard()
        case .unavailable:
            Text("Live weather unavailable for this field.")
                .font(Theme.display(13, .regular))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .nightCard()
        case .idle:
            EmptyView()
        }
    }

    private func windLabel(_ m: Metar, speed: Double) -> String {
        var parts: [String] = []
        switch m.wdir {
        case .degrees(let d): parts.append("\(Int(d))°")
        case .variable: parts.append(String(localized: "variable"))
        case nil: break
        }
        parts.append(speed < 1 ? String(localized: "calm") : "\(Int(speed)) kt")
        if let g = m.wgst { parts.append(String(localized: "gusting \(Int(g))")) }
        return parts.joined(separator: " · ")
    }

    private func visLabel(_ v: Metar.Visib) -> String {
        switch v {
        case .miles(let mi): String(localized: "\(String(format: "%.0f", mi * 1.609)) km")
        case .plus(let mi): String(localized: "\(String(format: "%.0f", mi * 1.609))+ km")
        }
    }

    private func cloudName(_ cover: String?) -> String {
        switch cover {
        case "FEW": String(localized: "Few")
        case "SCT": String(localized: "Scattered")
        case "BKN": String(localized: "Broken")
        case "OVC": String(localized: "Overcast")
        case "VV":  String(localized: "Obscured")
        case "CLR", "SKC", "CAVOK": String(localized: "Clear")
        default: cover ?? ""
        }
    }

    // MARK: Live traffic (from the feed already on screen)

    @ViewBuilder private var trafficCard: some View {
        let t = airport.traffic
        if t.inbound > 0 || t.outbound > 0 {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(String(localized: "Traffic overhead"))
                    .padding(.horizontal, 16).padding(.top, 12)
                infoRow(String(localized: "Within 30 nm"),
                        String(localized: "\(t.inbound) inbound · \(t.outbound) departing"))
                if let next = t.nextArrivalCallsign {
                    rowDivider
                    infoRow(String(localized: "Next arrival"),
                            String(localized: "\(next) · \(Int(t.nextArrivalNm.rounded())) nm out"))
                }
                if let hdg = t.approachHeading {
                    rowDivider
                    infoRow(String(localized: "Approach heading"), "≈ \(String(format: "%03d", hdg))°")
                }
                Color.clear.frame(height: 8)
            }
            .nightCard()
        }
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
    let dirs = [String(localized: "N"), String(localized: "NNE"),
                String(localized: "NE"), String(localized: "ENE"),
                String(localized: "E"), String(localized: "ESE"),
                String(localized: "SE"), String(localized: "SSE"),
                String(localized: "S"), String(localized: "SSW"),
                String(localized: "SW"), String(localized: "WSW"),
                String(localized: "W"), String(localized: "WNW"),
                String(localized: "NW"), String(localized: "NNW")]
    let i = Int((degrees / 22.5).rounded()) % 16
    return dirs[(i + 16) % 16]
}

// MARK: - Profile (pushed inside the Sky sheet)

/// Close control for the full-screen Profile (no sheet grabber to pull down).
/// Lives in the navigation bar, which supplies its own glass backing.
struct ProfileCloseButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
        }
        .accessibilityLabel("Close profile")
    }
}

/// The Profile header's glass surface: a MoonMark avatar and the observer's
/// standing, floated over the living voyage scene. This is the Profile screen's
/// intentional piece of Liquid Glass — it replaces the free-floating lens by
/// holding real content instead of sitting empty in the middle of the sky.
struct ProfileIdentityCard: View {
    @Bindable var engine: SkyEngine

    private var standing: String {
        let nights = engine.statDaysUsed
        let flights = engine.statFlightsSpotted
        let n = nights == 1 ? String(localized: "\(nights) night")
                            : String(localized: "\(nights) nights")
        let f = flights == 1 ? String(localized: "\(flights) flight")
                             : String(localized: "\(flights) flights")
        return String(localized: "\(engine.spotterTier.name) · \(f) · \(n)")
    }

    /// Highest milestone earned — the medal that *is* your rank.
    private var featured: Medal? {
        for id in MedalCatalog.milestoneOrder where engine.medals.earned[id] != nil {
            return MedalCatalog.medal(id)
        }
        return nil
    }

    var body: some View {
        // One card carries the whole identity: the tier medal (live 3D — it
        // flips in and settles as the page opens) is the avatar, name and
        // standing beside it. Tapping opens the Tiers & Medals journey.
        NavigationLink {
            MedalsOverviewView(engine: engine)
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let featured {
                        MedalView3D(medal: featured,
                                    award: engine.medals.earned[featured.id],
                                    cameraDistance: 2.3,
                                    hero: false)
                    } else if let first = MedalCatalog.medal("first") {
                        MedalView3D(medal: first, award: nil,
                                    cameraDistance: 2.3,
                                    hero: false, locked: true)
                    }
                }
                .frame(width: 66, height: 66)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overhead")
                        .font(Theme.display(19, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(standing)
                        .font(Theme.display(12.5, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .contentTransition(.numericText())
                    // The road to the next rung lives here now — this card IS
                    // the tier surface (the separate "Your tier" card said the
                    // same thing twice and went to the same place).
                    if let next = MedalCatalog.nextTier(forSpots: engine.statFlightsSpotted) {
                        Text("\(next.threshold - engine.statFlightsSpotted) flights to \(next.name)")
                            .font(Theme.display(11.5, .regular).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .contentTransition(.numericText())
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            // The medal sheds a quiet stream of star-motes across the card —
            // the tier metal dissolving into night sky. Born at the medal's
            // trailing edge (it spans x 14–80, vertically centered), tinted
            // by the rank's finish, drifting behind the name.
            .background {
                StarDissolve(emitter: CGRect(x: 64, y: 20, width: 14, height: 46),
                             tint: MedalArt.colors(engine.spotterTier.finish).thumbLight)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            }
            // Clear glass, not frosted: the airliner and solar system fly
            // directly behind this card, and their light should bend through.
            .glassEffectCompat(.clear, in: .rect(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
        }
        .buttonStyle(RowPressStyle())
        .accessibilityLabel("Overhead. \(standing). Opens tiers and medals.")
    }
}

struct ProfileView: View {
    @Bindable var engine: SkyEngine
    #if DEBUG
    @State private var shotPushViewSky = false
    #endif

    var body: some View {
        // One identity card at the top of the header — Overhead, your tier
        // medal, your standing — with the living sky behind it: the airliner
        // threads the card's glass, planets drift below. Tap for the journey.
        SettingsScaffold(theme: .profile, title: "Overhead",
                         // Sits clear of the nav bar's floating close button.
                         headerAccessory: AnyView(ProfileIdentityCard(engine: engine)
                            .padding(.top, 30)),
                         headerAccessoryAtTop: true,
                         headerExtraHeight: 30,
                         compactLeading: AnyView(MoonMark().frame(width: 20, height: 20))) {
            VStack(alignment: .leading, spacing: 22) {
                // The identity card in the header is the tier surface — its
                // progress line and destination make a separate "Your tier"
                // card redundant, so content starts with what's used most.
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "Favorite flights"))
                    if engine.favorites.isEmpty {
                        Text("Tap the heart on any flight to keep it here. Favorites get a pink mark in the sky.")
                            .font(Theme.display(13, .regular))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 8)
                            .transition(.opacity)
                    } else {
                        let list = Array(engine.favorites).sorted()
                        VStack(spacing: 0) {
                            ForEach(list, id: \.self) { callsign in
                                favoriteRow(callsign)
                                    .transition(.opacity)
                                if callsign != list.last {
                                    Divider().overlay(.white.opacity(0.08)).padding(.leading, 16)
                                }
                            }
                        }
                        .nightCard()
                    }
                }
                .animation(Theme.Motion.standard, value: engine.favorites)

                // Settings, grouped by purpose — what you see, what reaches
                // you, and where to get help — so the stack reads as a map,
                // not a pile.
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "Your sky"))
                    VStack(spacing: 0) {
                        settingsLink(String(localized: "View & sky"), icon: "moon.stars.fill",
                                     subtitle: engine.cameraPassthrough ? String(localized: "AR sky · layers · sky time") : String(localized: "Dark sky · layers · sky time")) {
                            SkySettingsView(engine: engine)
                        }
                        Divider().overlay(.white.opacity(0.08)).padding(.leading, 56)
                        settingsLink(String(localized: "Aircraft"), icon: "airplane",
                                     subtitle: String(localized: "Visibility, trails, labels, sound")) {
                            AircraftSettingsView(engine: engine)
                        }
                        Divider().overlay(.white.opacity(0.08)).padding(.leading, 56)
                        settingsLink(String(localized: "Airports"), icon: "airplane.arrival",
                                     subtitle: engine.showAirports ? String(localized: "Shown on the horizon") : String(localized: "Hidden")) {
                            AirportSettingsView(engine: engine)
                        }
                        // FR24 temporarily disabled — the Data source row is
                        // hidden until the FR24 path is production-ready.
                        // settingsLink("Data source", icon: "dot.radiowaves.up.forward",
                        //              subtitle: engine.fr24ApiKey.isEmpty ? "airplanes.live (free)" : "Flightradar24") {
                        //     DataSourceSettingsView(engine: engine)
                        // }
                    }
                    .nightCard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "Alerts & precision"))
                    VStack(spacing: 0) {
                        settingsLink(String(localized: "Notifications"), icon: "bell.badge.fill",
                                     subtitle: String(localized: "Transit alarm · ISS passes · event reminders")) {
                            NotificationSettingsView(engine: engine)
                        }
                        Divider().overlay(.white.opacity(0.08)).padding(.leading, 56)
                        settingsLink(String(localized: "Calibration"), icon: "scope",
                                     subtitle: String(localized: "Recalibrate heading · point at the Sun")) {
                            CalibrationView(engine: engine)
                        }
                    }
                    .nightCard()
                }

                // Pro: its own quiet surface while it's still an invitation;
                // once owned it retires to a thank-you row under Support.
                if !ProStore.shared.isPro {
                    proCard
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "Support"))
                    VStack(spacing: 0) {
                        settingsLink(String(localized: "Accessibility"), icon: "accessibility",
                                     subtitle: String(localized: "Hear & feel the sky")) {
                            AccessibilityView(engine: engine)
                        }
                        Divider().overlay(.white.opacity(0.08)).padding(.leading, 56)
                        settingsLink(String(localized: "About & privacy"), icon: "info.circle",
                                     subtitle: String(localized: "How it works · privacy · feedback")) {
                            AboutView()
                        }
                        if ProStore.shared.isPro {
                            Divider().overlay(.white.opacity(0.08)).padding(.leading, 56)
                            settingsLink(ProCatalog.title, icon: "sparkles",
                                         subtitle: String(localized: "Unlocked — thank you")) {
                                PaywallView(source: "settings")
                            }
                        }
                    }
                    .nightCard()
                }

                Text("Position data airplanes.live / adsb.lol · routes adsbdb · photos planespotters.net\nAll stats live on this device only.")
                    .font(Theme.display(11, .regular))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        // Close lives in the nav bar — always reachable, over header and
        // pinned bar alike, with the system's own glass backing.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ProfileCloseButton() }
        }
        #if DEBUG
        // `-shot viewsky` screenshot hook: land directly on View & sky.
        .onAppear { if ShotScreen.current == .viewsky { shotPushViewSky = true } }
        .navigationDestination(isPresented: $shotPushViewSky) { SkySettingsView(engine: engine) }
        #endif
    }

    /// Pro's invitation surface — gold-marked, honest, one row, gone once
    /// it's yours.
    private var proCard: some View {
        NavigationLink {
            PaywallView(source: "settings")
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.gold)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ProCatalog.title)
                        .font(Theme.display(16, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(localized: "Time Machine · event previews · lifetime"))
                        .font(Theme.display(12, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
            .nightCard()
        }
        .buttonStyle(RowPressStyle())
    }

    private func settingsLink<Destination: View>(_ title: String, icon: String,
                                                 subtitle: String,
                                                 @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.display(16, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(Theme.display(12, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
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
                                     ? Theme.gold : Theme.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            Button {
                // Haptic on the commit; the list settles via the card's driver.
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(Theme.Motion.standard) { engine.toggleFavorite(callsign) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Remove favorite")
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
    }
}

// MARK: - Sky events (pushed inside the Sky sheet)

struct EventsView: View {
    @Bindable var engine: SkyEngine

    /// What's already up right now — the calendar shouldn't only be futures.
    private struct TonightGlance {
        let moonThumb: UIImage
        let phaseName: String
        let percent: Int
        let planets: [String]
    }
    @State private var tonight: TonightGlance?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let tonight {
                    Eyebrow(String(localized: "Tonight"))
                    tonightCard(tonight)
                }
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
                    if let next = engine.events.first {
                        Eyebrow(String(localized: "Next in your sky"))
                            .padding(.top, tonight == nil ? 0 : 12)
                        NavigationLink { EventDetailView(event: next, engine: engine) } label: {
                            heroCard(next)
                        }
                        .buttonStyle(.plain)
                    }
                    if engine.events.count > 1 {
                        Eyebrow(String(localized: "The year ahead"))
                            .padding(.top, 12)
                        VStack(spacing: 10) {
                            ForEach(engine.events.dropFirst()) { event in
                                NavigationLink { EventDetailView(event: event, engine: engine) } label: {
                                    eventRow(event)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    // Fireballs are recorded, not predicted — they get their
                    // own shelf below the forecastable sky.
                    if !engine.recentEvents.isEmpty {
                        Eyebrow(String(localized: "Recently in the sky"))
                            .padding(.top, 12)
                        VStack(spacing: 10) {
                            ForEach(engine.recentEvents) { event in
                                NavigationLink { EventDetailView(event: event, engine: engine) } label: {
                                    eventRow(event)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Text("Eclipses and conjunctions are computed for your exact location.")
                        .font(Theme.display(11, .regular))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 6)
                }
            }
            .padding(24)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Sky events")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task { await loadTonight() }
    }

    /// Moon phase + planets currently (or this evening) above the horizon.
    private func loadTonight() async {
        let lat = UserDefaults.standard.double(forKey: SkyDefaults.lastLat)
        let lon = UserDefaults.standard.double(forKey: SkyDefaults.lastLon)
        guard lat != 0 || lon != 0 else { return }
        let (moon, planetsUp) = await Task.detached(priority: .userInitiated) {
            () -> (Celestial.MoonState, [String]) in
            let now = Date()
            let moon = Celestial.moon(date: now, lat: lat, lon: lon)
            // Probe the evening sky (or right now, if it's already dark).
            var probe = now
            if Celestial.sun(date: now, lat: lat, lon: lon).el > -3 {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone.current
                probe = cal.date(bySettingHour: 22, minute: 30, second: 0, of: now) ?? now
            }
            let rank = ["Venus", "Jupiter", "Mars", "Saturn", "Mercury"]
            let up = Celestial.planets(date: probe, lat: lat, lon: lon)
                .filter { $0.el > 8 }
                .map(\.name)
                .sorted { (rank.firstIndex(of: $0) ?? 9) < (rank.firstIndex(of: $1) ?? 9) }
            return (moon, up)
        }.value
        tonight = TonightGlance(
            moonThumb: SkyArt.moonImage(fraction: moon.illumination, waxing: moon.waxing, diameter: 80),
            phaseName: Celestial.phaseName(illumination: moon.illumination, waxing: moon.waxing),
            percent: Int((moon.illumination * 100).rounded()),
            planets: planetsUp)
    }

    private func tonightCard(_ glance: TonightGlance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(uiImage: glance.moonThumb)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .shadow(color: .white.opacity(0.25), radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(glance.phaseName)
                        .font(Theme.display(16, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(glance.percent)% lit")
                        .font(Theme.display(12, .regular).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
            }
            Divider().overlay(.white.opacity(0.08))
            HStack(spacing: 10) {
                Image(systemName: "circle.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                Text(planetsLine(glance.planets))
                    .font(Theme.display(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            if engine.issVisible {
                HStack(spacing: 10) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(red: 0.5, green: 1.0, blue: 1.0))
                        .frame(width: 22)
                    Text("The ISS is crossing your sky right now")
                        .font(Theme.display(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
        .padding(16)
        .nightCard()
    }

    private func planetsLine(_ planets: [String]) -> String {
        // The feed carries the English names (they double as lookup keys);
        // display goes through the localized name table.
        let names = planets.map(Celestial.localizedName)
        switch names.count {
        case 0:  return String(localized: "No naked-eye planets this evening")
        case 1:  return String(localized: "\(names[0]) is up tonight")
        default:
            let head = names.dropLast().joined(separator: ", ")
            return String(localized: "\(head) and \(names.last!) are up tonight")
        }
    }

    /// The soonest event, full-bleed: its artwork with the facts resting on a
    /// scrim along the bottom edge — the sheet opens on a poster, not a list.
    private func heroCard(_ event: SkyEvent) -> some View {
        EventHero(kind: event.kind)
            .overlay(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(Theme.display(19, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(event.date.formatted(date: .abbreviated, time: .shortened))
                            .font(Theme.display(12, .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 10)
                    Text(countdown(to: event.date))
                        .font(Theme.display(15, .bold).monospacedDigit())
                        .foregroundStyle(event.kind.tint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(colors: [.clear, Theme.nightBottom.opacity(0.85)],
                                   startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func eventRow(_ event: SkyEvent) -> some View {
        let tint = event.kind.tint
        return HStack(spacing: 14) {
            // The ring fills as the event approaches — a glance says "soon".
            ZStack {
                Circle().stroke(.white.opacity(0.10), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: proximity(of: event.date))
                    .stroke(tint.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                EventGlyph(kind: event.kind)
                    .frame(width: 22, height: 22)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(Theme.display(16, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(event.subtitle)
                    .font(Theme.display(12, .medium))
                    .foregroundStyle(Theme.textSecondary)
                Text(event.date.formatted(date: .long, time: .shortened))
                    .font(Theme.display(12, .regular))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)
            Text(countdown(to: event.date))
                .font(Theme.display(13, .bold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .padding(14)
        .nightCard()
        .overlay {
            if event.kind.isHeadline {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            }
        }
    }

    /// 0 → a year out … 1 → today.
    private func proximity(of date: Date) -> Double {
        let days = max(0, date.timeIntervalSinceNow / 86_400)
        return max(0.03, min(1, 1 - days / 365))
    }

    private func countdown(to date: Date) -> String {
        let days = date.timeIntervalSinceNow / 86_400
        if days <= -1 { return String(localized: "\(Int(-days))d ago") }   // the "recently" shelf
        if days < 1 { return String(localized: "today") }
        if days < 60 { return String(localized: "\(Int(days))d") }
        return String(localized: "\(Int(days / 30.44))mo")
    }
}

// MARK: - Calibration (pushed inside the Sky sheet)

struct CalibrationView: View {
    @Bindable var engine: SkyEngine

    var body: some View {
        SettingsScaffold(theme: .calibration, title: String(localized: "Calibration"),
                         titleBadge: AnyView(TierBadge(engine: engine, size: 46))) {
                VStack(alignment: .leading, spacing: 22) {
                    ControlCard(String(localized: "Calibrate heading")) {
                        Text("Sweep a full circle, then lock onto the Sun, Moon, or a plane you can see — the most accurate way to line the sky up with reality.")
                            .font(Theme.display(13, .regular))
                            .foregroundStyle(Theme.textSecondary)
                        Button {
                            engine.beginCalibration()   // the main view closes this sheet
                        } label: {
                            Label("Recalibrate now", systemImage: "scope")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        if !engine.cameraPassthrough {
                            Text("This will switch on the camera so you can lock onto the Sun or a plane.")
                                .font(Theme.display(12, .regular))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }

                    ControlCard(String(localized: "Auto-align"),
                                value: engine.autoAlignEnabled ? String(localized: "On") : String(localized: "Locked"),
                                footnote: engine.autoAlignEnabled
                                    ? String(localized: "The sky follows the compass and self-corrects as you pan.")
                                    : String(localized: "Holding your manual lock. Turn on to hand heading back to the compass.")) {
                        Toggle("Follow the compass automatically", isOn: Binding(
                            get: { engine.autoAlignEnabled },
                            set: { on in if on { engine.resetToAutoAlign() } else { engine.autoAlignEnabled = false } }))
                            .tint(Theme.accentSoft)
                    }
                    // The state line crossfades with the toggle instead of
                    // hard-swapping words under the finger.
                    .animation(Theme.Motion.standard, value: engine.autoAlignEnabled)

                    if engine.lidarSupported {
                        ControlCard(String(localized: "Tracking"),
                                    value: engine.lidarActive ? "LiDAR" : String(localized: "Off"),
                                    footnote: String(localized: "Uses the LiDAR scanner to keep the sky steady when the camera can't see much — a blank or night sky. Pro models only; toggle to compare.")) {
                            Toggle("LiDAR tracking assist", isOn: $engine.lidarAssist)
                                .tint(Theme.accentSoft)
                        }
                    }

                    ControlCard(String(localized: "Fine trim"),
                                value: String(format: "%.1f°", engine.headingOffsetDeg),
                                footnote: String(localized: "Manual nudge if it's still a touch off after calibrating.")) {
                        Slider(value: $engine.headingOffsetDeg, in: -20...20, step: 0.5)
                            .tint(Theme.accent)
                    }

                    compassStatus
                }
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
        .padding(16)
        .nightCard()
        // Live status: quality shifts (good ↔ fair ↔ poor) settle in color
        // and words rather than snapping.
        .animation(Theme.Motion.standard, value: engine.compassQuality)
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
        case .good: return String(localized: "Compass: good")
        case .fair: return String(localized: "Compass: fair")
        case .poor: return String(localized: "Compass: poor")
        case .unknown: return String(localized: "Compass: calibrating…")
        }
    }

    private var compassHint: String {
        switch engine.compassQuality {
        case .poor, .fair:
            return String(localized: "Wave the phone in a figure-8 to recalibrate the compass.")
        case .unknown:
            return String(localized: "Heading not available yet — only on device.")
        case .good:
            return engine.headingAccuracyDeg >= 0
                ? String(localized: "Accurate to ±\(Int(engine.headingAccuracyDeg))°")
                : String(localized: "Heading locked.")
        }
    }
}

// MARK: - Settings groups (pushed inside Profile)

/// Shared toggle row for the settings groups.
private struct SettingRow: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool
    var subtitle: String?

    var body: some View {
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
            // The analytics hook lives in the binding's setter so only real
            // user taps land there — programmatic writes (permission
            // rollbacks, didSet coupling) go straight to the source binding
            // and never emit a phantom Setting.toggled.
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { on in
                    isOn = on
                    Analytics.log("Setting.toggled", ["name": title, "on": on ? "true" : "false"])
                }))
                .labelsHidden().tint(Theme.accentSoft)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

private var settingsDivider: some View {
    Divider().overlay(.white.opacity(0.08)).padding(.leading, 56)
}

/// The one surface for a loose control on a settings page — title left, live
/// value right, the control itself, an explainer below, all on the standard
/// card. Nothing floats naked on the backdrop; if it isn't a toggle row or a
/// navigation row, it lives in one of these.
private struct ControlCard<Accessory: View, Content: View>: View {
    private let title: String
    private let value: String?
    private let footnote: String?
    private let accessory: Accessory
    private let content: Content

    init(_ title: String, value: String? = nil, footnote: String? = nil,
         @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.value = value
        self.footnote = footnote
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Theme.display(16, .medium))
                    .foregroundStyle(Theme.textPrimary)
                accessory
                Spacer()
                if let value {
                    Text(value)
                        .font(Theme.display(15, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .contentTransition(.numericText())
                }
            }
            content
            if let footnote {
                Text(footnote)
                    .font(Theme.display(12, .regular))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightCard()
    }
}

extension ControlCard where Accessory == EmptyView {
    init(_ title: String, value: String? = nil, footnote: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title, value: value, footnote: footnote,
                  accessory: { EmptyView() }, content: content)
    }
}

/// The one explainer surface — an icon-labelled title over body copy (plus
/// any inline extras). About, Accessibility, and status cards all read as
/// the same element.
private struct InfoCard<Content: View>: View {
    private let title: String
    private let icon: String
    private let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(Theme.display(16, .semibold))
                .foregroundStyle(Theme.textPrimary)
            content
                .font(Theme.display(13, .regular))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .nightCard()
    }
}

/// View mode + celestial layers + sky time.
struct SkySettingsView: View {
    @Bindable var engine: SkyEngine
    @State private var showPaywall = false

    var body: some View {
        SettingsScaffold(theme: .sky, title: String(localized: "View & sky"),
                         titleBadge: AnyView(TierBadge(engine: engine, size: 46))) {
            VStack(alignment: .leading, spacing: 22) {
                // Three purposes, three groups: how the sky is shown, what's
                // in it, and when it is.
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "Display"))
                    HStack(spacing: 10) {
                        modeChip(String(localized: "AR sky"), "camera.fill", active: engine.cameraPassthrough) {
                            // Without camera access AR mode would just show the
                            // dark dome pretending to be a broken feed — be
                            // honest and route to Settings instead.
                            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                                engine.cameraPassthrough = true
                                Analytics.log("Mode.selected", ["mode": "ar"])
                            } else if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        modeChip(String(localized: "Dark sky"), "moon.stars.fill", active: !engine.cameraPassthrough) {
                            engine.cameraPassthrough = false
                            Analytics.log("Mode.selected", ["mode": "dark"])
                        }
                    }
                    if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
                        Text("AR sky needs camera access — tap AR sky to open Settings.")
                            .font(Theme.display(12, .regular))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    VStack(spacing: 0) {
                        SettingRow(title: String(localized: "Night vision"), icon: "eye.fill", isOn: $engine.nightVision,
                                   subtitle: String(localized: "Deep red display — protects your dark adaptation"))
                    }
                    .padding(.vertical, 4)
                    .nightCard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "Sky layers"))
                    VStack(spacing: 0) {
                        SettingRow(title: String(localized: "Sun"), icon: "sun.max.fill", isOn: $engine.showSun)
                        settingsDivider
                        SettingRow(title: String(localized: "Moon"), icon: "moon.fill", isOn: $engine.showMoon,
                                   subtitle: moonSubtitle)
                        settingsDivider
                        SettingRow(title: String(localized: "Planets"), icon: "circle.circle", isOn: $engine.showPlanets,
                                   subtitle: String(localized: "Mercury through Saturn"))
                        settingsDivider
                        SettingRow(title: String(localized: "Stars"), icon: "sparkles", isOn: $engine.showStars)
                        settingsDivider
                        if engine.showStars {
                            Group {
                                SettingRow(title: String(localized: "Milky Way"), icon: "sparkle", isOn: $engine.showMilkyWay,
                                           subtitle: String(localized: "A soft river of distant starlight"))
                                settingsDivider
                            }
                            .transition(.opacity)
                        }
                        SettingRow(title: String(localized: "ISS"), icon: "diamond.fill", isOn: $engine.showISS,
                                   subtitle: engine.issVisible ? String(localized: "Overhead now") : nil)
                        // ISS pass alerts moved to Profile → Notifications, the
                        // one home for everything that can buzz the phone.
                        settingsDivider
                        SettingRow(title: String(localized: "Satellites"), icon: "smallcircle.filled.circle",
                                   isOn: $engine.showSatellites,
                                   subtitle: String(localized: "The naked-eye fleet — shown only when sunlit against a dark sky"))
                    }
                    .padding(.vertical, 4)
                    .nightCard()
                    // One driver per structural condition — the dependent row
                    // and button fade with the card settling, never popping.
                    .animation(Theme.Motion.standard, value: engine.showStars)

                    if engine.showISS {
                        Button { engine.jumpToNextISSPass() } label: {
                            Label("Jump to next ISS pass", systemImage: "arrow.up.forward.circle.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .transition(.opacity)
                    }
                }
                .animation(Theme.Motion.standard, value: engine.showISS)

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "Time"))
                    timeScrub
                    timeMachine
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            NavigationStack { PaywallView(source: "timeMachine") }
                .preferredColorScheme(.dark)
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
            .glassEffectCompat(active ? .regular.tint(Theme.accentSoft.opacity(0.45)) : .regular,
                         in: .capsule)
        }
        .animation(Theme.Motion.standard, value: active)
    }

    private var moonSubtitle: String {
        let pct = Int((engine.moonIllumination * 100).rounded())
        return engine.moonWaxing ? String(localized: "\(pct)% · waxing")
                                 : String(localized: "\(pct)% · waning")
    }

    private var timeScrub: some View {
        ControlCard(String(localized: "Sky time"),
                    value: TimeScrub.label(engine.skyTimeOffsetMin),
                    footnote: String(localized: "Scrub the sky forward or back to preview the sun, moon, stars and ISS at another time.")) {
            // Clamped proxy: a Time Machine jump can sit far outside the
            // slider's ±12 h — grabbing the slider pulls back into range.
            Slider(value: Binding(get: { max(-720, min(720, engine.skyTimeOffsetMin)) },
                                  set: { engine.skyTimeOffsetMin = $0 }),
                   in: -720...720, step: 5).tint(Theme.accent)
            HStack {
                Text("−12h").font(.caption2).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Now") { engine.skyTimeOffsetMin = 0 }.buttonStyle(GhostButtonStyle())
                Spacer()
                Text("+12h").font(.caption2).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// Pro: the sky on any date — eclipse day, a shower's peak, any night.
    @ViewBuilder private var timeMachine: some View {
        if ProStore.shared.isPro {
            ControlCard(String(localized: "Time Machine"),
                        footnote: String(localized: "Set the whole sky to any date within a year — stand under an eclipse before it happens. (Aircraft stay live; the ISS needs fresh orbit data, so far dates show it approximately.)"),
                        accessory: { ProChip() }) {
                DatePicker("Sky date",
                           selection: Binding(
                               get: { Date().addingTimeInterval(engine.skyTimeOffsetMin * 60) },
                               set: { engine.skyTimeOffsetMin = $0.timeIntervalSinceNow / 60 }),
                           in: Date().addingTimeInterval(-366 * 86_400)...Date().addingTimeInterval(366 * 86_400))
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(Theme.accent)
            }
        } else {
            Button { showPaywall = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.gold)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Time Machine")
                                .font(Theme.display(16, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            ProChip()
                        }
                        Text("Jump the sky to any date — eclipse day, shower peaks, any night.")
                            .font(Theme.display(12, .regular))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            .nightCard()
        }
    }
}

/// Everything aircraft: visibility, ground traffic, trails, labels, sound.
struct AircraftSettingsView: View {
    @Bindable var engine: SkyEngine

    var body: some View {
        SettingsScaffold(theme: .aircraft, title: String(localized: "Aircraft"),
                         titleBadge: AnyView(TierBadge(engine: engine, size: 46))) {
            VStack(alignment: .leading, spacing: 22) {
                // Two purposes, two groups: what traffic is drawn, and how to
                // read what's drawn.
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "Traffic"))
                    VStack(spacing: 0) {
                        SettingRow(title: String(localized: "Aircraft"), icon: "airplane", isOn: $engine.showAircraft,
                                   subtitle: engine.trafficCount > 0 ? String(localized: "\(engine.trafficCount) overhead") : nil)
                        settingsDivider
                        SettingRow(title: String(localized: "Naked-eye visible only"), icon: "eye.fill",
                                   isOn: $engine.nakedEyeOnly,
                                   subtitle: String(localized: "Hide distant planes you couldn't actually see"))
                        settingsDivider
                        SettingRow(title: String(localized: "Aircraft on the ground"), icon: "airplane.arrival",
                                   isOn: $engine.showGroundAircraft,
                                   subtitle: String(localized: "Taxiing and parked planes"))
                        settingsDivider
                        SettingRow(title: String(localized: "Aircraft trails"), icon: "wind", isOn: $engine.showTrails,
                                   subtitle: String(localized: "Fading path behind each plane"))
                        settingsDivider
                        SettingRow(title: String(localized: "Sky sounds"), icon: "speaker.wave.2.fill", isOn: $engine.soundOn,
                                   subtitle: String(localized: "Hear flyovers in 3D — best with AirPods"))
                    }
                    .padding(.vertical, 4)
                    .nightCard()

                    if engine.nakedEyeOnly {
                        ControlCard(String(localized: "Visible range"),
                                    value: "\(Int(engine.nakedEyeRangeNm)) nm",
                                    footnote: String(localized: "Baseline range — high-altitude jets stay visible farther. Planes near the horizon are kept too. Turn the whole filter off to never hide a plane.")) {
                            Slider(value: $engine.nakedEyeRangeNm, in: 15...55, step: 1).tint(Theme.accent)
                        }
                        .transition(.opacity)
                    }
                }
                // The range section rides the toggle with the card settling —
                // no hard column shove when the filter flips.
                .animation(Theme.Motion.standard, value: engine.nakedEyeOnly)

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "Reading the sky"))
                    ControlCard(String(localized: "Labels")) {
                        Picker("Labels", selection: $engine.labelMode) {
                            ForEach(SkyEngine.LabelMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    PlaneColorLegend()
                }
            }
        }
    }
}

/// Explains what an aircraft's colour and markers mean in the sky. Mirrors
/// `AircraftNode.altitudeColor` and the favorite/focus styling.
private struct PlaneColorLegend: View {
    // Matches AircraftNode.altitudeColor hue ramp (orange low → cyan high).
    private func altColor(_ t: Double) -> Color {
        Color(hue: 0.08 + t * (0.55 - 0.08), saturation: 0.85, brightness: 1.0)
    }

    var body: some View {
        // Same element as every explainer card — the title lives inside the
        // surface, not floating above it.
        ControlCard(String(localized: "What the colors mean")) {
            VStack(alignment: .leading, spacing: 14) {
                // Altitude ramp.
                VStack(alignment: .leading, spacing: 6) {
                    LinearGradient(colors: [altColor(0), altColor(0.4), altColor(0.7), altColor(1)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 10)
                        .clipShape(Capsule())
                    HStack {
                        Text("Low").font(Theme.display(11, .regular)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("High / cruising").font(Theme.display(11, .regular)).foregroundStyle(Theme.textSecondary)
                    }
                    Text("A plane's color is its altitude — warm orange down low, shifting to cyan up at cruise.")
                        .font(Theme.display(12, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }

                legendRow(swatch: .dot(Color(white: 0.6)), title: String(localized: "Gray plane"),
                          detail: String(localized: "On the ground — taxiing or parked."))
                legendRow(swatch: .heart, title: String(localized: "Pink heart"),
                          detail: String(localized: "A flight you've favorited."))
                legendRow(swatch: .ring(Theme.gold), title: String(localized: "Gold ring"),
                          detail: String(localized: "The flight you're tracking right now."))
            }
        }
    }

    private enum Swatch {
        case dot(Color), ring(Color), heart
    }

    private func legendRow(swatch: Swatch, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Group {
                switch swatch {
                case .dot(let c):
                    Circle().fill(c).frame(width: 16, height: 16)
                case .ring(let c):
                    Circle().stroke(c, lineWidth: 3).frame(width: 16, height: 16)
                case .heart:
                    Image(systemName: "heart.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.58))
                }
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.display(15, .medium)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(Theme.display(12, .regular)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Choose the live-traffic provider. The free airplanes.live feed is sparse
/// over the Gulf/oceans; a Flightradar24 token gives global, satellite coverage.
struct DataSourceSettingsView: View {
    @Bindable var engine: SkyEngine
    @State private var token: String = ""

    private var usingFR24: Bool { !engine.fr24ApiKey.isEmpty }

    var body: some View {
        SettingsScaffold(theme: .dataSource, title: String(localized: "Data source"),
                         titleBadge: AnyView(TierBadge(engine: engine, size: 46))) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(usingFR24 ? "Flightradar24" : "airplanes.live / adsb.lol (free)",
                          systemImage: usingFR24 ? "globe" : "dot.radiowaves.left.and.right")
                        .font(Theme.display(17, .semibold))
                        .foregroundStyle(usingFR24 ? Theme.accent : Theme.textPrimary)
                    Text(usingFR24
                         ? "Satellite-backed global coverage, including the Gulf and oceans. Billed per call, so the app polls gently (about every 8 seconds)."
                         : "Community ADS-B, with automatic fallback between feeds — excellent over the US and Europe, but sparse over the Gulf, the Middle East, and oceans. Free and non-commercial.")
                        .font(Theme.display(13, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .nightCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Flightradar24 API token")
                        .font(Theme.display(16, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    TextField("Paste your FR24 token", text: $token, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(12)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    HStack(spacing: 10) {
                        Button("Use this token") {
                            engine.fr24ApiKey = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if usingFR24 {
                            Button("Use free feed") {
                                token = ""
                                engine.fr24ApiKey = ""
                            }
                            .buttonStyle(GhostButtonStyle())
                        }
                    }
                    Text("Get a token at fr24api.flightradar24.com — free sandbox, or the $9/mo Explorer plan. Leave empty to use the free community feeds.")
                        .font(Theme.display(12, .regular))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .onAppear { token = engine.fr24ApiKey }
    }
}

/// Accessibility: find aircraft eyes-free, by spatial sound and proximity
/// haptics. A headline feature for low-vision and blind users.
/// Everything that can buzz the phone, in one place: the transit alarm, ISS
/// pass alerts, and the sky-event reminders set from event pages. The
/// pending-notification queue is the single source of truth throughout —
/// the reminder list below is read straight from it.
struct NotificationSettingsView: View {
    @Bindable var engine: SkyEngine
    @State private var authDenied = false
    @State private var reminders: [PendingReminder] = []

    private struct PendingReminder: Identifiable, Equatable {
        let id: String
        let title: String
        let fireDate: Date?
    }

    var body: some View {
        SettingsScaffold(theme: .alerts, title: String(localized: "Notifications")) {
            VStack(alignment: .leading, spacing: 22) {
                if authDenied { deniedCard }

                // Grouped by horizon: the perishable now, the plannable week,
                // and the reminders you set by hand.
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "While you watch"))
                    VStack(spacing: 0) {
                        SettingRow(title: String(localized: "Transit alarm"), icon: "airplane",
                                   isOn: $engine.transitAlarm,
                                   subtitle: String(localized: "\(TransitAlertScheduler.leadPhrase(engine.transitAlarmLeadSec)) before a plane crosses the Sun or Moon"))
                        if engine.transitAlarm {
                            Group {
                                settingsDivider
                                leadRow
                                settingsDivider
                                SettingRow(title: String(localized: "Moon crossings"), icon: "moon.fill",
                                           isOn: $engine.transitAlarmMoon)
                                settingsDivider
                                SettingRow(title: String(localized: "Sun crossings"), icon: "sun.max.fill",
                                           isOn: $engine.transitAlarmSun)
                            }
                            .transition(.opacity)
                        }
                    }
                    .padding(.vertical, 4)
                    .nightCard()
                    // One driver for the card's structure: the reveal springs
                    // (and the subtitle's lead phrase keeps step), no popping.
                    .animation(Theme.Motion.standard, value: engine.transitAlarm)
                    .animation(Theme.Motion.standard, value: engine.transitAlarmLeadSec)

                    Text("Aircraft transits can only be predicted about three minutes ahead, and only while Overhead is open — the alarm covers the moment your phone is locked while you set up. The longest lead fires the instant a transit is found.")
                        .font(Theme.display(12, .regular))
                        .foregroundStyle(Theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "Days ahead"))
                    VStack(spacing: 0) {
                        SettingRow(title: String(localized: "ISS pass alerts"), icon: "diamond.fill",
                                   isOn: $engine.issAlerts,
                                   subtitle: String(localized: "A nudge 10 minutes before it rises"))
                        settingsDivider
                        SettingRow(title: String(localized: "Meteor shower peaks"), icon: "sparkles",
                                   isOn: $engine.showerAlerts,
                                   subtitle: String(localized: "An hour before each major shower peaks"))
                        settingsDivider
                        SettingRow(title: String(localized: "Tonight's sky"), icon: "moon.stars.fill",
                                   isOn: $engine.skyDigest,
                                   subtitle: String(localized: "A quiet daily note as the first stars come out"))
                    }
                    .padding(.vertical, 4)
                    .nightCard()

                    Text("Tonight's sky waits silently in your notification list — moon phase and the planets up this evening, timed to your local sunset. Nothing lights the phone.")
                        .font(Theme.display(12, .regular))
                        .foregroundStyle(Theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(String(localized: "Event reminders"))
                    if reminders.isEmpty {
                        Text("None scheduled. Set one from any sky event's page — you'll hear an hour before it begins.")
                            .font(Theme.display(13, .regular))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .nightCard()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(reminders) { reminder in
                                reminderRow(reminder)
                                    .transition(.opacity)
                                if reminder != reminders.last { settingsDivider }
                            }
                        }
                        .padding(.vertical, 4)
                        .nightCard()
                        .animation(Theme.Motion.standard, value: reminders)
                    }
                }
            }
        }
        .task { await refresh() }
    }

    /// Lead-time picker, laid out like a SettingRow so the card reads as one
    /// family. Physics note: choices stop at 3 minutes — the predictor's
    /// entire horizon.
    private var leadRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "timer")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            Text(String(localized: "Alert lead"))
                .font(Theme.display(16, .medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Picker(String(localized: "Alert lead"), selection: $engine.transitAlarmLeadSec) {
                ForEach(TransitAlertScheduler.leadChoices, id: \.self) { lead in
                    Text(TransitAlertScheduler.leadPhrase(lead)).tag(lead)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(minHeight: 44)
    }

    private func reminderRow(_ reminder: PendingReminder) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "bell.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.gold)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title)
                    .font(Theme.display(15, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let fireDate = reminder.fireDate {
                    Text(fireDate.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.display(12, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Button {
                // Haptic on the causal frame: the commit is the removal.
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(withIdentifiers: [reminder.id])
                withAnimation(Theme.Motion.standard) { reminders.removeAll { $0.id == reminder.id } }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Remove reminder for \(reminder.title)"))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var deniedCard: some View {
        InfoCard(String(localized: "Notifications are off for Overhead"), icon: "bell.slash.fill") {
            Text("Alerts and reminders can't be delivered until notifications are allowed in Settings.")
            Button(String(localized: "Open Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(Theme.display(14, .semibold))
            .foregroundStyle(Theme.accent)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    private func refresh() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        authDenied = settings.authorizationStatus == .denied
        let pending = await center.pendingNotificationRequests()
        reminders = pending
            .filter { $0.identifier.hasPrefix("skyevent-") }
            .map { request in
                PendingReminder(
                    id: request.identifier,
                    title: request.content.title,
                    fireDate: (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate())
            }
            .sorted { ($0.fireDate ?? .distantFuture) < ($1.fireDate ?? .distantFuture) }
    }
}

struct AccessibilityView: View {
    @Bindable var engine: SkyEngine

    var body: some View {
        SettingsScaffold(theme: .accessibility, title: String(localized: "Accessibility"),
                         titleBadge: AnyView(TierBadge(engine: engine, size: 46))) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 0) {
                    SettingRow(title: String(localized: "Hear & feel the sky"), icon: "dot.radiowaves.left.and.right",
                               isOn: $engine.hearFeelSky,
                               subtitle: String(localized: "Find planes by sound and touch — eyes-free"))
                }
                .padding(.vertical, 4)
                .nightCard()

                InfoCard(String(localized: "Hear it"), icon: "airpods") {
                    Text("Every nearby aircraft becomes a 3D-positioned engine hum — to your left, your right, above. Close your eyes, point toward the sound, and you're facing the plane. Best with AirPods for full spatial audio.")
                }
                InfoCard(String(localized: "Feel it"), icon: "hand.tap") {
                    Text("As a plane nears the center of where you're pointing, the phone pulses — slow and soft when it's off to the side, fast and firm when you're aimed right at it. Sweep the sky and feel for the plane, no screen needed.")
                }
                InfoCard(String(localized: "For everyone"), icon: "accessibility") {
                    Text("Built for blind and low-vision skywatchers first — but anyone can find a plane without staring at the screen. Overhead also respects Reduce Motion, Dynamic Type, and works with VoiceOver.")
                }
            }
        }
    }
}

/// About, how-it-works, the reference-only disclaimer, privacy, and feedback.
struct AboutView: View {
    @Environment(\.openURL) private var openURL
    @State private var shareUsageStats = !Analytics.isOptedOut
    private let feedbackEmail = AppInfo.feedbackEmail

    var body: some View {
        SettingsScaffold(theme: .about, title: String(localized: "About & privacy")) {
            VStack(alignment: .leading, spacing: 22) {
                InfoCard(String(localized: "What it is"), icon: "sparkles") {
                    Text("Hold your phone up and Overhead labels the sky around you — live aircraft, the Sun, the Moon, the planets, stars, and the ISS, each placed at its real position in augmented reality.")
                }

                InfoCard(String(localized: "Reference only"), icon: "exclamationmark.triangle") {
                    Text("Overhead is a reference and educational tool, and we've worked hard to place everything as accurately as we can. Even so, we can't guarantee it: positions, routes, and identities come from public data that can be delayed, incomplete, or wrong, and many aircraft (parked, military, or not equipped) don't broadcast at all. Please don't use Overhead for navigation, safety, or any operational decision — we take no responsibility for the accuracy or completeness of what's shown.")
                }

                InfoCard(String(localized: "Best under open sky"), icon: "location.north.line") {
                    Text("Overhead points the sky using your iPhone's compass and motion sensors, so it's happiest outdoors in the open. Magnetometers can read a few degrees off — and the structural steel, wiring, and electronics inside airports, terminals, and buildings can pull them well off — so indoors the whole sky may sit noticeably rotated, and near metal, cars, speakers, or a magnetic case too. Hold still, and if something looks off, tap a plane or the Sun to re-align (or run Calibration). Accuracy also drifts while you're walking or in a moving vehicle.")
                }

                InfoCard(String(localized: "Privacy"), icon: "lock.shield") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No account. No tracking. No ads.")
                            .font(Theme.display(13, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Your location places the sky around you, and is sent to public flight services like airplanes.live to fetch the aircraft near you — never linked to an account, logged by us, or used to track you. Favorites and stats live only on this device.\n\nTo improve the app, Overhead may collect anonymous usage statistics — which features get used, never who you are, where you are, or what you looked at. You can turn this off below.\n\nAircraft data comes from public feeds: airplanes.live and adsb.lol (positions), adsbdb (routes), planespotters.net (photos), CelesTrak (orbits). Those services have their own terms.")
                        Toggle(isOn: $shareUsageStats) {
                            Text("Share anonymous usage statistics")
                                .font(Theme.display(13, .medium))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .tint(Theme.accentSoft)
                        .padding(.top, 4)
                        .onChange(of: shareUsageStats) { _, share in
                            Analytics.setOptedOut(!share)
                        }
                    }
                }

                Button {
                    let subject = String(localized: "\(AppInfo.name) feedback")
                    if let url = URL(string: "mailto:\(feedbackEmail)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                        openURL(url)
                    }
                } label: {
                    Label("Share feedback", systemImage: "envelope")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button {
                    openURL(AppInfo.writeReviewURL)
                } label: {
                    Label("Rate Overhead on the App Store", systemImage: "star")
                }
                .buttonStyle(GhostButtonStyle())
                .frame(maxWidth: .infinity)

                Text("Feedback goes to \(feedbackEmail)")
                    .font(Theme.display(11, .regular))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

/// Airport layer settings.
struct AirportSettingsView: View {
    @Bindable var engine: SkyEngine

    var body: some View {
        SettingsScaffold(theme: .airport, title: String(localized: "Airports"),
                         titleBadge: AnyView(TierBadge(engine: engine, size: 46))) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 0) {
                    SettingRow(title: String(localized: "Airports"), icon: "airplane.arrival",
                               isOn: $engine.showAirports,
                               subtitle: String(localized: "Nearby fields on the horizon"))
                }
                .padding(.vertical, 4)
                .nightCard()
                Text("Major airports within 150 nautical miles are pinned at their true bearing with their IATA code. Tap one in the sky for details.")
                    .font(Theme.display(12, .regular))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

enum TimeScrub {
    /// "Now", "+2h 15m", "−45m", "+32d 4h" … from a minute offset.
    static func label(_ minutes: Double) -> String {
        if abs(minutes) < 0.5 { return String(localized: "Now") }
        let sign = minutes >= 0 ? "+" : "−"
        let total = Int(abs(minutes).rounded())
        let h = total / 60, m = total % 60
        // Time Machine territory: day-scale offsets read as days, not hours.
        if h >= 48 {
            let d = h / 24, rh = h % 24
            return rh > 0 ? "\(sign)\(d)d \(rh)h" : "\(sign)\(d)d"
        }
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
                .glassEffectCompat(.regular, in: .circle)
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
