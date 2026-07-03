//
//  RouteArc.swift
//  Skylight AR
//
//  The flight detail's signature moment: origin → destination as a drawn arc,
//  the plane riding it at the flight's true progress. The flown portion draws
//  itself in when the sheet opens (skipped under Reduce Motion) and the plane
//  glides along the curve as fresh fixes land.
//

import SwiftUI

/// Quadratic arc between two ground stations, trimmable for the flown segment.
private struct ArcShape: Shape {
    let a: CGPoint, c: CGPoint, b: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: c)
        return p
    }
}

/// Positions (and banks) its content along the arc at parameter `t`, animating
/// smoothly *along the curve* rather than cutting straight between points.
private struct AlongArc: ViewModifier, Animatable {
    var t: CGFloat
    let a: CGPoint, c: CGPoint, b: CGPoint

    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    func body(content: Content) -> some View {
        let u = 1 - t
        let point = CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                            y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        let tangent = CGPoint(x: 2 * u * (c.x - a.x) + 2 * t * (b.x - c.x),
                              y: 2 * u * (c.y - a.y) + 2 * t * (b.y - c.y))
        content
            .rotationEffect(.radians(atan2(tangent.y, tangent.x)))
            .position(point)
    }
}

/// The arc itself: dashed route ahead, glowing flown segment behind, endpoint
/// markers, and the plane at `progress` (0 = at origin, 1 = at destination).
struct RouteArc: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0

    /// Keep the plane visually on the arc even right at the endpoints.
    private var target: CGFloat { CGFloat(min(max(progress, 0.02), 0.98)) }

    var body: some View {
        GeometryReader { geo in
            let a = CGPoint(x: 8, y: geo.size.height - 10)
            let b = CGPoint(x: geo.size.width - 8, y: geo.size.height - 10)
            let c = CGPoint(x: geo.size.width / 2, y: -geo.size.height * 0.35)
            ZStack {
                // The route still to fly.
                ArcShape(a: a, c: c, b: b)
                    .stroke(.white.opacity(0.16),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 5.5]))
                // The part already flown.
                ArcShape(a: a, c: c, b: b)
                    .trim(from: 0, to: drawn)
                    .stroke(
                        LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.accent],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .shadow(color: Theme.accent.opacity(0.45), radius: 5)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .position(a)
                Circle()
                    .strokeBorder(.white.opacity(0.55), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .position(b)
                Image(systemName: "airplane")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.6), radius: 4)
                    .modifier(AlongArc(t: max(drawn, 0.001), a: a, c: c, b: b))
            }
        }
        .onAppear {
            if reduceMotion {
                drawn = target
            } else {
                withAnimation(.spring(response: 1.2, dampingFraction: 0.9)) { drawn = target }
            }
        }
        // Fresh fixes nudge the plane further along the curve.
        .onChange(of: progress) { _, _ in
            withAnimation(.easeInOut(duration: 0.6)) { drawn = target }
        }
        .accessibilityHidden(true)   // the endpoints and stats carry the facts
    }
}

// MARK: - Route geometry

enum RouteProgress {
    /// Great-circle distance between two coordinates, nautical miles.
    static func distanceNm(_ lat1: Double, _ lon1: Double,
                           _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * atan2(sqrt(h), sqrt(1 - h)) * 3440.065   // Earth radius in nm
    }

    /// Fraction of the way from origin to destination, judged by distance.
    static func fraction(planeLat: Double, planeLon: Double,
                         originLat: Double, originLon: Double,
                         destLat: Double, destLon: Double) -> Double {
        let flown = distanceNm(originLat, originLon, planeLat, planeLon)
        let toGo = distanceNm(planeLat, planeLon, destLat, destLon)
        guard flown + toGo > 1 else { return 0.5 }
        return flown / (flown + toGo)
    }
}

#Preview {
    ZStack {
        Theme.skyGradient.ignoresSafeArea()
        RouteArc(progress: 0.62)
            .frame(height: 70)
            .padding(30)
    }
}
