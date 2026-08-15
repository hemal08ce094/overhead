//
//  SkyScanHome.swift
//  Overhead
//
//  The landing scope: a night-sky dial in Overhead's own indigo and gold —
//  live aircraft by bearing and range, the ISS and the moon pinned to the
//  rim at their true azimuth, and one gold door into the AR sky. Home is
//  the overview; AR stays the magic. Runs its own light poll of the same
//  free feed the AR view uses, so nothing here touches the AR pipeline.
//

import SwiftUI
import CoreLocation
import SatelliteKit

// MARK: - Model

@MainActor
@Observable
final class SkyScanModel: NSObject, CLLocationManagerDelegate {

    var aircraft: [Aircraft] = []
    var observer: CLLocation?
    var placeName: String?
    var usingDemoLocation = false

    /// Scope radius, nm — the chip row. Persisted so the dial reopens as left.
    var rangeNm: Double {
        didSet {
            UserDefaults.standard.set(rangeNm, forKey: SkyDefaults.scanRangeNm)
            pollSoon()
        }
    }

    // Celestial rim marks + the subline facts.
    var moonIllumination = 0.0
    var moonAzimuth: Double?          // nil while below the horizon
    var issAzimuth: Double?           // nil while below the horizon
    var issRise: Date?
    var issMaxEl = 0

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let source: any DataSource = FallbackSource.freeFeeds()
    private var pollTask: Task<Void, Never>?
    private var issSatellite: Satellite?

    override init() {
        let stored = UserDefaults.standard.object(forKey: SkyDefaults.scanRangeNm) as? Double ?? 40
        rangeNm = [10.0, 25, 40, 60, 80].contains(stored) ? stored : 40
        super.init()
    }

    func start() {
        manager.delegate = self
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            adoptDemoLocation()
        }
        loadISS()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Same stand-in sky the AR view falls back to when location is denied.
    private func adoptDemoLocation() {
        usingDemoLocation = true
        observer = CLLocation(latitude: 37.6213, longitude: -122.3790)
        placeName = String(localized: "Demo sky")
        pollSoon()
    }

    private func pollSoon() { Task { await poll() } }

    private func poll() async {
        guard let observer else { return }
        let lat = observer.coordinate.latitude
        let lon = observer.coordinate.longitude
        if let traffic = try? await source.aircraft(lat: lat, lon: lon, radiusNm: Int(rangeNm)) {
            // The scope promises "overhead" — taxiing metal stays off the dial.
            aircraft = traffic.filter { !$0.onGround }
        }
        updateCelestial()
    }

    private func updateCelestial() {
        guard let observer else { return }
        let lat = observer.coordinate.latitude
        let lon = observer.coordinate.longitude
        let now = Date()
        let moon = Celestial.moon(date: now, lat: lat, lon: lon)
        moonIllumination = moon.illumination
        moonAzimuth = moon.el > 0 ? moon.az : nil

        guard let sat = issSatellite else { return }
        if let lla = try? sat.geoPosition(julianDays: SkyMath.julianDay(now)) {
            let fix = SkyMath.azElRange(observerLat: lat, observerLon: lon, observerAltM: 0,
                                        targetLat: lla.lat, targetLon: lla.lon,
                                        targetAltM: lla.alt * 1000)
            issAzimuth = fix.elevation > 0 ? fix.azimuth : nil
        }
        // Next rise above 10°, scanning 12 h ahead — the subline's headline fact.
        if issRise == nil || issRise! < now {
            var t = 60.0
            var rise: Date?
            var maxEl = 0.0
            while t < 12 * 3600 {
                let date = now.addingTimeInterval(t)
                if let lla = try? sat.geoPosition(julianDays: SkyMath.julianDay(date)) {
                    let el = SkyMath.azElRange(observerLat: lat, observerLon: lon, observerAltM: 0,
                                               targetLat: lla.lat, targetLon: lla.lon,
                                               targetAltM: lla.alt * 1000).elevation
                    if el > 10 {
                        if rise == nil { rise = date }
                        maxEl = max(maxEl, el)
                    } else if rise != nil { break }
                }
                t += 30
            }
            issRise = rise
            issMaxEl = Int(maxEl.rounded())
        }
    }

    /// Cached TLE first (shared keys with the AR controller), network only
    /// when missing or stale — the same courtesy the rest of the app pays
    /// Celestrak.
    private func loadISS() {
        let d = UserDefaults.standard
        if let lines = d.stringArray(forKey: SkyDefaults.issTLELines), lines.count >= 3,
           let elements = try? Elements(lines[0], lines[1], lines[2]) {
            let sat = Satellite(withTLE: elements)
            issSatellite = sat
        }
        let fetchedAt = d.object(forKey: SkyDefaults.issTLEDate) as? Date
        let stale = fetchedAt.map { Date().timeIntervalSince($0) > 86_400 } ?? true
        guard issSatellite == nil || stale else { return }
        Task { [weak self] in
            guard let url = URL(string: "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=tle"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard lines.count >= 3,
                  let elements = try? Elements(lines[0], lines[1], lines[2]) else { return }
            let sat = Satellite(withTLE: elements)
            let defaults = UserDefaults.standard
            defaults.set(Array(lines.prefix(3)), forKey: SkyDefaults.issTLELines)
            defaults.set(Date(), forKey: SkyDefaults.issTLEDate)
            guard let self else { return }
            self.issSatellite = sat
            self.updateCelestial()
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            case .denied, .restricted: self.adoptDemoLocation()
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.usingDemoLocation = false
            self.observer = location
            self.pollSoon()
            if self.placeName == nil || self.placeName == String(localized: "Demo sky") {
                let marks = try? await self.geocoder.reverseGeocodeLocation(location)
                if let city = marks?.first?.locality ?? marks?.first?.administrativeArea {
                    self.placeName = city
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if self.observer == nil { self.adoptDemoLocation() }
        }
    }

    // MARK: Geometry for the dial

    /// (bearing° from north, fraction of scope radius) for a track — nil when
    /// it has drifted outside the dial.
    func polar(of ac: Aircraft) -> (bearing: Double, fraction: Double)? {
        guard let observer else { return nil }
        let lat1 = observer.coordinate.latitude * .pi / 180
        let lon1 = observer.coordinate.longitude * .pi / 180
        let lat2 = ac.lat * .pi / 180, lon2 = ac.lon * .pi / 180
        let dLon = lon2 - lon1
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var bearing = atan2(y, x) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        let a = sin((lat2 - lat1) / 2), b = sin(dLon / 2)
        let h = a * a + cos(lat1) * cos(lat2) * b * b
        let nm = 6_371 * 2 * atan2(sqrt(h), sqrt(1 - h)) / 1.852
        guard nm <= rangeNm * 1.02 else { return nil }
        return (bearing, nm / rangeNm)
    }
}

// MARK: - Home view

struct SkyScanHome: View {
    /// The gold door — RootView swaps to the AR experience.
    var onEnterSky: () -> Void

    @State private var model = SkyScanModel()
    /// A private engine that only feeds the Events sheet — the AR screen
    /// still owns its own when it opens.
    @State private var eventsEngine = SkyEngine()
    @State private var showEvents = false
    @State private var showPass = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private static let rangeChoices: [Double] = [10, 25, 40, 60, 80]

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    scope
                        .frame(width: min(geo.size.width - 48, 360),
                               height: min(geo.size.width - 48, 360))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    metaRow
                    chipRow
                        .padding(.top, 12)
                    enterSkyButton
                        .padding(.top, 18)
                    quickRow
                        .padding(.top, 10)
                }
                .padding(24)
            }
        }
        .background(
            LinearGradient(colors: [Theme.nightTop, Theme.nightBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.start() } else { model.stop() }
        }
        .onChange(of: model.observer) { _, observer in
            guard let observer else { return }
            eventsEngine.loadEventsIfNeeded(lat: observer.coordinate.latitude,
                                            lon: observer.coordinate.longitude)
        }
        .sheet(isPresented: $showEvents) {
            NavigationStack { EventsView(engine: eventsEngine) }
                .presentationDetents([.medium, .large])
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showPass) {
            issPassSheet
                .presentationDetents([.height(280)])
                .preferredColorScheme(.dark)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("SKY LIVE")
                .font(Theme.display(11, .bold))
                .tracking(3.2)
                .foregroundStyle(Theme.gold)
            Group {
                if model.aircraft.isEmpty {
                    Text("Reading your sky…")
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    (Text("\(model.aircraft.count) aircraft ").foregroundStyle(Theme.gold)
                     + Text("overhead.").foregroundStyle(Theme.textPrimary))
                }
            }
            .font(Theme.display(30, .bold))
            subline
        }
    }

    @ViewBuilder private var subline: some View {
        HStack(spacing: 6) {
            if model.issAzimuth != nil {
                Text("◆ ISS crossing your sky now")
                    .foregroundStyle(Color(red: 0.5, green: 1.0, blue: 1.0))
                    .fontWeight(.semibold)
            } else if let rise = model.issRise, rise.timeIntervalSinceNow < 12 * 3600 {
                Text("◆ ISS rises in \(Int(max(1, rise.timeIntervalSinceNow / 60))) min")
                    .foregroundStyle(Color(red: 0.5, green: 1.0, blue: 1.0))
                    .fontWeight(.semibold)
            }
            Text("Moon \(Int((model.moonIllumination * 100).rounded()))% lit")
                .foregroundStyle(Theme.textSecondary)
        }
        .font(Theme.display(12.5, .medium))
    }

    // MARK: Scope

    private var scope: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 3600 : 1.0 / 30)) { timeline in
            Canvas { context, size in
                drawScope(context: &context, size: size, date: timeline.date)
            }
        }
        .accessibilityLabel(Text("Sky scope: \(model.aircraft.count) aircraft within \(Int(model.rangeNm)) nautical miles"))
    }

    private func drawScope(context: inout GraphicsContext, size: CGSize, date: Date) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = min(size.width, size.height) / 2 - 20
        let dial = Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))

        // Ground: a whisper of deep indigo, darker than the page.
        context.fill(dial, with: .radialGradient(
            Gradient(colors: [Theme.indigo.opacity(0.30), Color.black.opacity(0.45)]),
            center: c, startRadius: 0, endRadius: R))

        // Range rings, the outermost firm.
        for i in 1...4 {
            let r = R * CGFloat(i) / 4
            let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.stroke(ring, with: .color(Theme.accent.opacity(i == 4 ? 0.32 : 0.13)),
                           lineWidth: i == 4 ? 1.6 : 0.8)
            if i < 4 {
                let label = Int((model.rangeNm * Double(i) / 4).rounded())
                context.draw(Text("\(label)").font(Theme.display(9, .semibold))
                                .foregroundStyle(Theme.textTertiary),
                             at: CGPoint(x: c.x + 9, y: c.y - r + 8))
            }
        }
        // Cross hairs.
        var cross = Path()
        cross.move(to: CGPoint(x: c.x - R, y: c.y)); cross.addLine(to: CGPoint(x: c.x + R, y: c.y))
        cross.move(to: CGPoint(x: c.x, y: c.y - R)); cross.addLine(to: CGPoint(x: c.x, y: c.y + R))
        context.stroke(cross, with: .color(Theme.accent.opacity(0.08)), lineWidth: 0.8)

        // Cardinals — N in gold, like the AR compass.
        context.draw(Text("N").font(Theme.display(13, .bold)).foregroundStyle(Theme.gold),
                     at: CGPoint(x: c.x, y: c.y - R - 10))
        for (label, dx, dy): (String, CGFloat, CGFloat) in [("S", 0, 1), ("W", -1, 0), ("E", 1, 0)] {
            context.draw(Text(label).font(Theme.display(13, .bold)).foregroundStyle(Theme.textTertiary),
                         at: CGPoint(x: c.x + dx * (R + 10), y: c.y + dy * (R + 10)))
        }

        // The sweep: a slow observatory drive, 12 s per turn. Trailing lines
        // fade behind the leading edge; Reduce Motion parks it.
        let sweepDeg = reduceMotion ? -70.0
            : date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12) / 12 * 360
        for i in 0..<14 {
            let a = (sweepDeg - Double(i) * 2.6) * .pi / 180
            let tip = CGPoint(x: c.x + sin(a) * R, y: c.y - cos(a) * R)
            var line = Path()
            line.move(to: c); line.addLine(to: tip)
            context.stroke(line, with: .color(Theme.gold.opacity(i == 0 ? 0.65 : 0.30 * (1 - Double(i) / 14))),
                           lineWidth: i == 0 ? 1.6 : 1.1)
        }

        // Aircraft: altitude-tinted, rotated to their track.
        for ac in model.aircraft {
            guard let polar = model.polar(of: ac) else { continue }
            let a = polar.bearing * .pi / 180
            let p = CGPoint(x: c.x + sin(a) * polar.fraction * R,
                            y: c.y - cos(a) * polar.fraction * R)
            var glyph = context.resolve(Image(systemName: "airplane"))
            glyph.shading = .color(Color(uiColor: AircraftNode.altitudeColor(feet: ac.altitudeFeet,
                                                                             onGround: false)))
            context.drawLayer { layer in
                layer.translateBy(x: p.x, y: p.y)
                layer.rotate(by: .degrees((ac.track ?? 0) - 90))   // the symbol points east
                layer.opacity = 0.92
                layer.draw(glyph, in: CGRect(x: -7, y: -7, width: 14, height: 14))
            }
        }

        // The rim carries what a map can't: the moon and the ISS at their
        // true azimuth — direction to look, not distance on the ground.
        if let az = model.moonAzimuth {
            let a = az * .pi / 180
            let p = CGPoint(x: c.x + sin(a) * (R - 4), y: c.y - cos(a) * (R - 4))
            context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                         with: .color(Theme.moonlight))
        }
        if let az = model.issAzimuth {
            let a = az * .pi / 180
            let p = CGPoint(x: c.x + sin(a) * (R - 4), y: c.y - cos(a) * (R - 4))
            let cyan = Color(red: 0.5, green: 1.0, blue: 1.0)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)),
                         with: .radialGradient(Gradient(colors: [cyan.opacity(0.35), .clear]),
                                               center: p, startRadius: 1, endRadius: 12))
            context.drawLayer { layer in
                layer.translateBy(x: p.x, y: p.y)
                layer.rotate(by: .degrees(45))
                layer.fill(Path(CGRect(x: -4.5, y: -4.5, width: 9, height: 9)), with: .color(cyan))
            }
            context.draw(Text("ISS").font(Theme.display(9, .bold)).foregroundStyle(cyan),
                         at: CGPoint(x: p.x, y: p.y - 15))
        }

        // The observer.
        context.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)),
                     with: .color(Theme.gold))
        context.stroke(Path(ellipseIn: CGRect(x: c.x - 7.5, y: c.y - 7.5, width: 15, height: 15)),
                       with: .color(Theme.gold.opacity(0.5)), lineWidth: 1.2)
    }

    // MARK: Meta + chips

    private var metaRow: some View {
        HStack {
            Text((model.placeName ?? String(localized: "Locating…")).uppercased())
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("RANGE \(Int(model.rangeNm)) NM")
                .foregroundStyle(Theme.textTertiary)
        }
        .font(Theme.display(11, .semibold).monospacedDigit())
        .tracking(1.4)
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            Text("RANGE")
                .font(Theme.display(10, .semibold))
                .tracking(1.8)
                .foregroundStyle(Theme.textTertiary)
            ForEach(Self.rangeChoices, id: \.self) { choice in
                Button {
                    model.rangeNm = choice
                } label: {
                    Text("\(Int(choice))")
                        .font(Theme.display(13, .semibold).monospacedDigit())
                        .foregroundStyle(model.rangeNm == choice ? Color.black.opacity(0.85) : Theme.textSecondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(model.rangeNm == choice ? AnyShapeStyle(Theme.gold)
                                                              : AnyShapeStyle(Color.white.opacity(0.06))))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(.white.opacity(model.rangeNm == choice ? 0 : 0.10), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .animation(Theme.Motion.standard, value: model.rangeNm)
    }

    // MARK: CTA + quick row

    private var enterSkyButton: some View {
        Button(action: onEnterSky) {
            HStack(spacing: 8) {
                Text("Point at the sky")
                Image(systemName: "arrow.up.forward")
            }
            .font(Theme.display(17, .bold))
            .foregroundStyle(Color.black.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.gold, Theme.gold.opacity(0.82)],
                                         startPoint: .top, endPoint: .bottom)))
            .shadow(color: Theme.gold.opacity(0.25), radius: 14, y: 5)
        }
        .buttonStyle(.plain)
    }

    private var quickRow: some View {
        HStack(spacing: 8) {
            quickButton(String(localized: "Sky events")) { showEvents = true }
            quickButton(String(localized: "Find a flight")) { onEnterSky() }
            quickButton(String(localized: "Next ISS pass")) { showPass = true }
        }
    }

    private func quickButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.display(12.5, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(.white.opacity(0.055)))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(.white.opacity(0.09), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: ISS pass sheet

    private var issPassSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NEXT ISS PASS")
                .font(Theme.display(11, .bold))
                .tracking(2.4)
                .foregroundStyle(Color(red: 0.5, green: 1.0, blue: 1.0))
            if model.issAzimuth != nil {
                Text("The station is crossing your sky right now — step outside and look up.")
                    .font(Theme.display(16, .semibold))
                    .foregroundStyle(Theme.textPrimary)
            } else if let rise = model.issRise {
                Text(timerInterval: Date()...max(Date().addingTimeInterval(1), rise), countsDown: true)
                    .font(Theme.display(34, .bold).monospacedDigit())
                    .foregroundStyle(Color(red: 0.5, green: 1.0, blue: 1.0))
                Text("Rises at \(rise.formatted(date: .omitted, time: .shortened)) and peaks \(model.issMaxEl)° above the horizon.")
                    .font(Theme.display(14, .medium))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("No pass above 10° in the next 12 hours.")
                    .font(Theme.display(15, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            LinearGradient(colors: [Theme.nightTop, Theme.nightBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
    }
}

#Preview {
    SkyScanHome(onEnterSky: {})
}
