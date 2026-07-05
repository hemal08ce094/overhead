//
//  MedalViews.swift
//  Skylight AR
//
//  The medals themselves. Fully procedural, Fitness-award quality: a lathe-like
//  disc built from SceneKit primitives, physically-based metals lit by a
//  generated studio environment, and an engraved face whose normal map is
//  computed at runtime from a drawn emblem — no shipped assets. Drag to spin
//  with momentum; hero medals idle in a slow perpetual turn like Fitness
//  awards. Unearned medals render the same 3D disc as a colourless blank.
//  The shelf grid uses cheap 2D thumbs.
//

import SwiftUI
import SceneKit
import StoreKit

// MARK: - Emblem art (shared by 2D thumbs and the 3D engraving)

@MainActor
enum MedalArt {

    /// Rendered art is immutable per medal — cache everything. Emblems are
    /// re-requested on every thumb body evaluation and the engraving normal
    /// maps cost two full-image CPU passes; neither should ever run twice.
    private static var emblemCache: [String: UIImage] = [:]
    private static var normalCache: [String: UIImage] = [:]

    /// Diffuse tint + 2D thumb gradient per finish.
    static func colors(_ finish: Medal.Finish) -> (base: UIColor, thumbLight: Color, thumbDark: Color) {
        switch finish {
        case .bronze: return (UIColor(red: 0.72, green: 0.46, blue: 0.28, alpha: 1),
                              Color(red: 0.80, green: 0.55, blue: 0.36), Color(red: 0.38, green: 0.22, blue: 0.12))
        case .steel:  return (UIColor(red: 0.62, green: 0.67, blue: 0.74, alpha: 1),
                              Color(red: 0.70, green: 0.75, blue: 0.82), Color(red: 0.25, green: 0.29, blue: 0.36))
        case .silver: return (UIColor(red: 0.84, green: 0.86, blue: 0.90, alpha: 1),
                              Color(red: 0.88, green: 0.90, blue: 0.94), Color(red: 0.40, green: 0.43, blue: 0.50))
        case .gold:   return (UIColor(red: 1.00, green: 0.78, blue: 0.42, alpha: 1),
                              Color(red: 1.00, green: 0.83, blue: 0.50), Color(red: 0.48, green: 0.32, blue: 0.10))
        case .night:  return (UIColor(red: 0.34, green: 0.37, blue: 0.56, alpha: 1),
                              Color(red: 0.46, green: 0.50, blue: 0.74), Color(red: 0.10, green: 0.11, blue: 0.22))
        }
    }

    static func roughness(_ finish: Medal.Finish) -> CGFloat {
        switch finish {
        case .bronze: return 0.34
        case .steel:  return 0.28
        case .silver: return 0.22
        case .gold:   return 0.24
        case .night:  return 0.30
        }
    }

    /// The emblem drawn white on transparent — used directly by 2D thumbs and
    /// composited onto black as the height field for the 3D engraving.
    static func emblemImage(for medal: Medal, size: CGFloat = 512) -> UIImage {
        let key = "\(medal.id)-\(Int(size))"
        if let cached = emblemCache[key] { return cached }
        let image = renderEmblem(for: medal, size: size)
        emblemCache[key] = image
        return image
    }

    private static func renderEmblem(for medal: Medal, size: CGFloat) -> UIImage {
        let s = CGSize(width: size, height: size)
        return UIGraphicsImageRenderer(size: s).image { ui in
            let ctx = ui.cgContext
            let hasCaption = medal.caption != nil
            let center = CGPoint(x: size / 2, y: size * (hasCaption ? 0.46 : 0.5))
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.setStrokeColor(UIColor.white.cgColor)

            switch medal.emblem {
            case .symbol(let name):
                drawSymbol(name, at: center, height: size * 0.34, in: ctx)
            case .count(let n):
                let text = "\(n)"
                draw(text: text, font: .systemFont(ofSize: size * 0.30, weight: .heavy),
                     rounded: true, at: center, in: ctx)
            case .constellation:
                drawConstellation(center: center, radius: size * 0.24, in: ctx)
            case .rotor:
                drawRotor(center: center, radius: size * 0.22, in: ctx)
            case .transit:
                // Moon disc with the plane crossing it.
                ctx.setLineWidth(size * 0.018)
                ctx.strokeEllipse(in: CGRect(x: center.x - size * 0.20, y: center.y - size * 0.20,
                                             width: size * 0.40, height: size * 0.40))
                drawSymbol("airplane", at: center, height: size * 0.17, in: ctx)
            case .issStreak:
                drawISS(center: center, size: size, in: ctx)
            }

            if let caption = medal.caption {
                draw(text: caption, font: .systemFont(ofSize: size * 0.072, weight: .bold),
                     rounded: true, kern: size * 0.012,
                     at: CGPoint(x: size / 2, y: size * 0.72), in: ctx)
            }
            // Engraved ring inside the rim ties every face together.
            ctx.setLineWidth(size * 0.008)
            ctx.strokeEllipse(in: CGRect(x: size * 0.09, y: size * 0.09,
                                         width: size * 0.82, height: size * 0.82))
        }
    }

    private static func drawSymbol(_ name: String, at center: CGPoint, height: CGFloat, in ctx: CGContext) {
        let config = UIImage.SymbolConfiguration(pointSize: height, weight: .medium)
        guard let symbol = UIImage(systemName: name, withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
        let aspect = symbol.size.width / max(symbol.size.height, 1)
        let rect = CGRect(x: center.x - height * aspect / 2, y: center.y - height / 2,
                          width: height * aspect, height: height)
        symbol.draw(in: rect)
    }

    private static func draw(text: String, font: UIFont, rounded: Bool, kern: CGFloat = 0,
                             at center: CGPoint, in ctx: CGContext) {
        var f = font
        if rounded, let d = font.fontDescriptor.withDesign(.rounded) {
            f = UIFont(descriptor: d, size: font.pointSize)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: UIColor.white,
                                                    .kern: kern]
        let str = NSAttributedString(string: text, attributes: attrs)
        let bounds = str.size()
        str.draw(at: CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2))
    }

    private static func drawConstellation(center: CGPoint, radius r: CGFloat, in ctx: CGContext) {
        // A little dipper of our own — stable, recognisable, ours.
        let pts = [CGPoint(x: -1.0, y: 0.55), CGPoint(x: -0.45, y: 0.28), CGPoint(x: 0.05, y: 0.38),
                   CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.95, y: -0.15), CGPoint(x: 0.55, y: -0.55),
                   CGPoint(x: 0.0, y: -0.42)]
            .map { CGPoint(x: center.x + $0.x * r, y: center.y + $0.y * r) }
        ctx.setLineWidth(3)
        ctx.beginPath()
        ctx.addLines(between: pts)
        ctx.strokePath()
        for (i, p) in pts.enumerated() {
            let rr: CGFloat = i % 3 == 0 ? 11 : 7
            ctx.fillEllipse(in: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2))
        }
    }

    private static func drawRotor(center: CGPoint, radius r: CGFloat, in ctx: CGContext) {
        for i in 0..<4 {
            let angle = CGFloat(i) * .pi / 2   // + pattern reads as a rotor, × reads as "close"
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: angle)
            let blade = CGRect(x: r * 0.12, y: -r * 0.09, width: r, height: r * 0.18)
            ctx.addPath(CGPath(roundedRect: blade, cornerWidth: r * 0.09, cornerHeight: r * 0.09, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.fillEllipse(in: CGRect(x: center.x - r * 0.14, y: center.y - r * 0.14,
                                   width: r * 0.28, height: r * 0.28))
    }

    private static func drawISS(center: CGPoint, size: CGFloat, in ctx: CGContext) {
        // Trail sweeping in, station diamond at its head.
        ctx.setLineWidth(size * 0.014)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: center.x - size * 0.26, y: center.y + size * 0.16))
        ctx.addLine(to: CGPoint(x: center.x + size * 0.08, y: center.y - size * 0.04))
        ctx.strokePath()
        let d = size * 0.085
        let c = CGPoint(x: center.x + size * 0.14, y: center.y - size * 0.075)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: c.x, y: c.y - d))
        ctx.addLine(to: CGPoint(x: c.x + d, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + d))
        ctx.addLine(to: CGPoint(x: c.x - d, y: c.y))
        ctx.closePath()
        ctx.fillPath()
        for star in [CGPoint(x: -0.3, y: -0.24), CGPoint(x: 0.3, y: 0.2), CGPoint(x: -0.05, y: 0.3)] {
            let p = CGPoint(x: center.x + star.x * size, y: center.y + star.y * size)
            ctx.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
        }
    }

    // MARK: Height → normal map

    /// White-on-black height field for the face: emblem over black, softened
    /// so the engraving reads as a bevel, not a paper cutout.
    static func heightField(for medal: Medal, size: Int = 512) -> UIImage {
        let s = CGSize(width: size, height: size)
        let emblem = emblemImage(for: medal, size: CGFloat(size))
        return UIGraphicsImageRenderer(size: s).image { ui in
            UIColor.black.setFill()
            ui.fill(CGRect(origin: .zero, size: s))
            // Drawing twice with a shadow blurs the edges into a soft bevel.
            ui.cgContext.setShadow(offset: .zero, blur: 7, color: UIColor.white.cgColor)
            emblem.draw(in: CGRect(origin: .zero, size: s))
            emblem.draw(in: CGRect(origin: .zero, size: s))
        }
    }

    /// Cached engraving normal for a medal's face — computed once per medal.
    static func faceNormal(for medal: Medal) -> UIImage? {
        let key = "face-\(medal.id)"
        if let cached = normalCache[key] { return cached }
        let map = normalMap(from: heightField(for: medal))
        if let map { normalCache[key] = map }
        return map
    }

    /// Cached engraving normal for a medal's back (varies with the award).
    static func backNormal(for medal: Medal, award: MedalAward?) -> UIImage? {
        let stamp = award.map { "\($0.date.timeIntervalSince1970)-\($0.detail ?? "")" } ?? "locked"
        let key = "back-\(medal.id)-\(stamp)"
        if let cached = normalCache[key] { return cached }
        let map = normalMap(from: backHeightField(for: medal, award: award))
        if let map { normalCache[key] = map }
        return map
    }

    /// Sobel over the height field → tangent-space normal map. Raw-buffer
    /// interior loop (no per-pixel clamping); the border is uniform black in
    /// every height field, so its true normal is flat and is written directly.
    static func normalMap(from height: UIImage, strength: Float = 2.6) -> UIImage? {
        guard let cg = height.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 2, h > 2 else { return nil }
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let grayCtx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        grayCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Flat normal (0, 0, 1) everywhere first; interior overwritten below.
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4] = 128; rgba[i * 4 + 1] = 128; rgba[i * 4 + 2] = 255; rgba[i * 4 + 3] = 255
        }
        gray.withUnsafeBufferPointer { g in
            rgba.withUnsafeMutableBufferPointer { out in
                let scale = strength / 255
                for y in 1..<(h - 1) {
                    let row = y * w
                    for x in 1..<(w - 1) {
                        let dx = (Float(g[row + x + 1]) - Float(g[row + x - 1])) * scale
                        let dy = (Float(g[row + w + x]) - Float(g[row - w + x])) * scale
                        let inv = 1 / (dx * dx + dy * dy + 1).squareRoot()
                        let i = (row + x) * 4
                        out[i]     = UInt8(((-dx * inv) * 0.5 + 0.5) * 255)
                        out[i + 1] = UInt8((( dy * inv) * 0.5 + 0.5) * 255)
                        out[i + 2] = UInt8(((inv) * 0.5 + 0.5) * 255)
                    }
                }
            }
        }
        guard let outCtx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                     bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let out = outCtx.makeImage() else { return nil }
        return UIImage(cgImage: out)
    }

    /// Back-face height field: the award engraved in words.
    static func backHeightField(for medal: Medal, award: MedalAward?, size: Int = 512) -> UIImage {
        let s = CGSize(width: size, height: size)
        return UIGraphicsImageRenderer(size: s).image { ui in
            UIColor.black.setFill()
            ui.fill(CGRect(origin: .zero, size: s))
            let ctx = ui.cgContext
            // The back cap is read after a 180° flip, which mirrors it left-to-
            // right in screen space. Pre-mirror the engraving here so the words
            // come out the right way round once the medal is turned over.
            ctx.translateBy(x: CGFloat(size), y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.setShadow(offset: .zero, blur: 6, color: UIColor.white.cgColor)
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(CGFloat(size) * 0.008)
            ctx.strokeEllipse(in: CGRect(x: CGFloat(size) * 0.09, y: CGFloat(size) * 0.09,
                                         width: CGFloat(size) * 0.82, height: CGFloat(size) * 0.82))
            var lines = ["OVERHEAD"]
            if let award {
                lines.append(award.date.formatted(date: .abbreviated, time: .omitted).uppercased())
                if let detail = award.detail { lines.append(detail.uppercased()) }
            }
            for (i, line) in lines.enumerated() {
                draw(text: line,
                     font: .systemFont(ofSize: CGFloat(size) * (i == 0 ? 0.075 : 0.058), weight: .bold),
                     rounded: true, kern: CGFloat(size) * 0.012,
                     at: CGPoint(x: CGFloat(size) / 2,
                                 y: CGFloat(size) * (0.38 + CGFloat(i) * 0.13)), in: ctx)
            }
        }
    }

    /// Small generated "studio" — an equirect panel of soft light bands that
    /// gives the metal its liquid specular sweeps.
    static let studioEnvironment: UIImage = {
        let s = CGSize(width: 512, height: 256)
        return UIGraphicsImageRenderer(size: s).image { ui in
            let ctx = ui.cgContext
            UIColor(white: 0.04, alpha: 1).setFill()
            ui.fill(CGRect(origin: .zero, size: s))
            // Ceiling glow.
            let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [UIColor(white: 0.45, alpha: 1).cgColor,
                                          UIColor(white: 0.02, alpha: 1).cgColor] as CFArray,
                                 locations: [0, 0.45])!
            ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: 130), options: [])
            // Three tall softboxes; the middle one slightly warm.
            for (fx, warm, width) in [(0.18, false, 46.0), (0.52, true, 66.0), (0.85, false, 40.0)] {
                let cx = s.width * fx
                let color = warm ? UIColor(red: 1, green: 0.93, blue: 0.82, alpha: 1)
                                 : UIColor(white: 0.95, alpha: 1)
                let band = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [color.withAlphaComponent(0).cgColor,
                                               color.cgColor,
                                               color.withAlphaComponent(0).cgColor] as CFArray,
                                      locations: [0, 0.5, 1])!
                ctx.saveGState()
                ctx.clip(to: CGRect(x: cx - width, y: 26, width: width * 2, height: 190))
                ctx.drawLinearGradient(band, start: CGPoint(x: cx - width, y: 0),
                                       end: CGPoint(x: cx + width, y: 0), options: [])
                ctx.restoreGState()
            }
        }
    }()
}

// MARK: - 3D medal scene

enum MedalScene {

    /// Rotate/mirror a cap texture about its center in UV space:
    /// recenter → rotate → (mirror) → restore, concatenated explicitly.
    private static func capTransform(rotate: Float, mirror: Bool) -> SCNMatrix4 {
        var m = SCNMatrix4MakeTranslation(-0.5, -0.5, 0)
        m = SCNMatrix4Mult(m, SCNMatrix4MakeRotation(rotate, 0, 0, 1))
        if mirror { m = SCNMatrix4Mult(m, SCNMatrix4MakeScale(-1, 1, 1)) }
        return SCNMatrix4Mult(m, SCNMatrix4MakeTranslation(0.5, 0.5, 0))
    }

    static func make(for medal: Medal, award: MedalAward?, hero: Bool = true,
                     locked: Bool = false) -> (SCNScene, SCNNode) {
        let scene = SCNScene()
        scene.lightingEnvironment.contents = MedalArt.studioEnvironment
        scene.lightingEnvironment.intensity = locked ? 1.3 : 1.7
        scene.background.contents = UIColor.clear

        let (base, _, _) = MedalArt.colors(medal.finish)
        let rough = MedalArt.roughness(medal.finish)

        func metal() -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            if locked {
                // Unstruck blank: colourless graphite with a duller grind. The
                // engraving still catches light, so what you're working toward
                // stays legible — it just hasn't been struck in metal yet.
                m.diffuse.contents = UIColor(white: 0.46, alpha: 1)
                m.metalness.contents = 0.85
                m.roughness.contents = 0.48
            } else {
                m.diffuse.contents = base
                m.metalness.contents = 1.0
                m.roughness.contents = rough
                if medal.finish == .night {
                    m.clearCoat.contents = 0.9
                    m.clearCoatRoughness.contents = 0.15
                }
            }
            return m
        }

        // Face: engraved normal map on the disc's front cap (cached per medal).
        let face = metal()
        face.normal.contents = MedalArt.faceNormal(for: medal)
        let back = metal()
        back.normal.contents = MedalArt.backNormal(for: medal, award: award)
        // Cap UV conventions (verified by screenshot): the camera-facing cap
        // renders a quarter-turn rotated and mirrored; the away cap is true.
        face.normal.contentsTransform = capTransform(rotate: .pi / 2, mirror: true)

        let disc = SCNCylinder(radius: 0.97, height: 0.14)
        disc.radialSegmentCount = 96
        disc.materials = [metal(), back, face]

        let rim = SCNTorus(ringRadius: 0.965, pipeRadius: 0.075)
        rim.ringSegmentCount = 128
        rim.materials = [metal()]

        let medalNode = SCNNode()
        medalNode.addChildNode(SCNNode(geometry: disc))
        medalNode.addChildNode(SCNNode(geometry: rim))
        medalNode.eulerAngles.x = -.pi / 2     // emblem cap toward the camera

        let spinner = SCNNode()                // all interaction rotates this
        spinner.addChildNode(medalNode)
        scene.rootNode.addChildNode(spinner)

        // Locked medals sit in a quieter studio — same rig, lights turned down.
        let lightScale: CGFloat = locked ? 0.8 : 1

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 420 * lightScale
        key.eulerAngles = SCNVector3(-0.5, -0.4, 0)
        scene.rootNode.addChildNode(key)

        // Cool fill softens the shadow side so the metal never goes muddy.
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 130 * lightScale
        fill.light?.color = UIColor(red: 0.80, green: 0.86, blue: 1.0, alpha: 1)
        fill.eulerAngles = SCNVector3(0.4, 0.7, 0)
        scene.rootNode.addChildNode(fill)

        // Rim light from behind catches the bevel and rings the edge — the
        // "expensive medal" highlight.
        let rimLight = SCNNode()
        rimLight.light = SCNLight()
        rimLight.light?.type = .directional
        rimLight.light?.intensity = 260 * lightScale
        rimLight.eulerAngles = SCNVector3(0.2, .pi - 0.3, 0)
        scene.rootNode.addChildNode(rimLight)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        // HDR + bloom only where the medal is the hero; a 66pt avatar doesn't
        // need an HDR offscreen pass.
        camera.camera?.wantsHDR = hero
        camera.camera?.wantsExposureAdaptation = false
        if hero { camera.camera?.bloomIntensity = locked ? 0.05 : 0.12 }
        camera.position = SCNVector3(0, 0, 3.1)
        scene.rootNode.addChildNode(camera)

        return (scene, spinner)
    }
}

/// Interactive medal: drag to spin with momentum. Hero medals live like
/// Fitness awards — the reveal is one fast turn that relaxes into a perpetual
/// slow rotation, and a fling glides back to that idle turn instead of
/// braking. The small avatar (and Reduce Motion) reveals once and rests, so
/// nothing renders forever where it shouldn't.
struct MedalView3D: UIViewRepresentable {
    let medal: Medal
    let award: MedalAward?
    /// Camera pull-back; smaller = the medal fills more of the view.
    var cameraDistance: Float = 3.1
    /// Full quality (HDR, bloom, 4× MSAA, 60 fps) for the big viewers;
    /// the small avatar renders lighter with no visible difference at its size.
    var hero: Bool = true
    /// Unearned: the same medal struck as a colourless blank — still spinnable.
    var locked: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = hero ? .multisampling4X : .multisampling2X
        view.preferredFramesPerSecond = hero ? 60 : 30
        let (scene, spinner) = MedalScene.make(for: medal, award: award, hero: hero, locked: locked)
        scene.rootNode.childNodes.first { $0.camera != nil }?.position.z = cameraDistance
        view.scene = scene
        context.coordinator.spinner = spinner

        if reduceMotion {
            spinner.eulerAngles.y = 0
        } else if hero {
            // Reveal: a fast turn that eases into the endless idle rotation.
            context.coordinator.idleSpeed = 0.3
            context.coordinator.startSpin(initialVelocity: -6.8)
        } else {
            // Avatar reveal: one graceful turn that lands face-on and stops.
            spinner.eulerAngles.y = -2 * .pi * 0.9
            let settle = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 1.4, usesShortestUnitArc: false)
            settle.timingMode = .easeOut
            spinner.runAction(settle)
        }

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.pan(_:)))
        view.addGestureRecognizer(pan)
        view.isAccessibilityElement = true
        view.accessibilityLabel = locked
            ? "\(medal.name) medal, not yet earned. Drag to rotate."
            : "\(medal.name) medal. Drag to rotate."
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.stopSpin()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        var spinner: SCNNode?
        /// The slow perpetual turn the medal relaxes back to. 0 (avatar,
        /// Reduce Motion) means flings settle on the nearest face instead.
        var idleSpeed: Float = 0
        private var velocity: Float = 0
        private var startY: Float = 0
        private var dragging = false
        private var lastTime: CFTimeInterval = 0
        private var link: CADisplayLink?

        func startSpin(initialVelocity: Float) {
            velocity = initialVelocity
            lastTime = 0
            guard link == nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(step(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }

        func stopSpin() {
            link?.invalidate()
            link = nil
        }

        @objc private func step(_ link: CADisplayLink) {
            let dt = lastTime == 0 ? 0 : Float(link.timestamp - lastTime)
            lastTime = link.timestamp
            guard let spinner, !dragging, dt > 0 else { return }
            // Exponential glide from the current speed down to the idle turn —
            // a fling never brakes to a stop, it just becomes the slow spin.
            let idle = idleSpeed * (velocity < 0 ? -1 : 1)
            velocity = idle + (velocity - idle) * expf(-dt / 0.85)
            spinner.eulerAngles.y += velocity * dt
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let spinner else { return }
            switch gesture.state {
            case .began:
                dragging = true
                spinner.removeAllActions()
                startY = spinner.eulerAngles.y
            case .changed:
                let dx = Float(gesture.translation(in: gesture.view).x)
                spinner.eulerAngles.y = startY + dx * 0.012
            case .ended, .cancelled:
                dragging = false
                let v = max(-14, min(14, Float(gesture.velocity(in: gesture.view).x) * 0.012))
                if idleSpeed > 0 {
                    startSpin(initialVelocity: v)
                } else {
                    // Coast on the fling, then settle on whichever face is nearest.
                    let projected = spinner.eulerAngles.y + v * 0.32
                    let settled = (projected / .pi).rounded() * .pi
                    let action = SCNAction.rotateTo(x: 0, y: CGFloat(settled), z: 0,
                                                    duration: 0.85, usesShortestUnitArc: false)
                    action.timingMode = .easeOut
                    spinner.runAction(action)
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
            default:
                break
            }
        }
    }
}

// MARK: - 2D shelf thumb

/// Cheap, pretty medal chip for the Profile shelf. Locked medals show a dark
/// silhouette with a progress arc — the pull toward the next one.
struct MedalThumb: View {
    let medal: Medal
    let earnedDate: Date?
    let progress: Int
    let target: Int
    var size: CGFloat = 64

    private var fraction: Double { target > 0 ? Double(progress) / Double(target) : 0 }

    var body: some View {
        let (_, light, dark) = MedalArt.colors(medal.finish)
        let earnedMedal = earnedDate != nil
        let rim = max(1, size * 0.032)
        ZStack {
            // Struck-metal disc + emblem + a polished sheen, kept inside the rim.
            ZStack {
                Circle().fill(
                    earnedMedal
                    ? AnyShapeStyle(RadialGradient(colors: [light, dark],
                                                   center: UnitPoint(x: 0.36, y: 0.27),
                                                   startRadius: 2, endRadius: size * 0.76))
                    : AnyShapeStyle(RadialGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0.02)],
                                                   center: .center, startRadius: 2, endRadius: size * 0.72)))
                Image(uiImage: MedalArt.emblemImage(for: medal, size: 160))
                    .resizable()
                    .frame(width: size * 0.875, height: size * 0.875)
                    .opacity(earnedMedal ? 0.95 : 0.30)
                // Glossy top sheen — the catch of light that reads as polished metal.
                if earnedMedal {
                    Ellipse()
                        .fill(LinearGradient(colors: [.white.opacity(0.55), .clear],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: size * 0.82, height: size * 0.52)
                        .offset(y: -size * 0.22)
                        .blendMode(.screen)
                        .blur(radius: size * 0.015)
                }
            }
            .clipShape(Circle())

            // Beveled metallic rim: lit top-left, shadowed bottom-right.
            Circle().strokeBorder(
                earnedMedal
                ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.9), light.opacity(0.45), dark.opacity(0.75)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                : AnyShapeStyle(Color.white.opacity(0.12)),
                lineWidth: earnedMedal ? rim : 1.5)

            if !earnedMedal, fraction > 0 {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Theme.accent.opacity(0.85),
                            style: StrokeStyle(lineWidth: max(2, size * 0.04), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: earnedMedal ? dark.opacity(0.6) : .clear, radius: size * 0.125, y: size * 0.06)
        .accessibilityLabel(earnedMedal
            ? "\(medal.name) medal, earned"
            : "\(medal.name) medal, locked. \(progress) of \(target).")
    }
}

/// The spotter's current tier as a miniature medal — carried into every
/// settings header so your standing travels with you. Tapping it opens the
/// Tiers & Medals journey (except on that screen itself).
struct TierBadge: View {
    @Bindable var engine: SkyEngine
    var size: CGFloat = 26
    var tappable: Bool = true

    var body: some View {
        let id = MedalCatalog.medalID(for: engine.spotterTier)
        if let medal = MedalCatalog.medal(id) {
            let thumb = MedalThumb(medal: medal,
                                   earnedDate: engine.medals.earned[id]?.date ?? Date(),
                                   progress: medal.target, target: medal.target,
                                   size: size)
            if tappable {
                NavigationLink {
                    MedalsOverviewView(engine: engine)
                } label: {
                    thumb
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Your tier: \(engine.spotterTier.name). Opens tiers and medals.")
            } else {
                thumb
            }
        }
    }
}

// MARK: - Tiers & medals overview

/// The full progression, one tap from the Profile header: your current tier
/// in 3D, the ladder of tiers, and every medal grouped for browsing.
struct MedalsOverviewView: View {
    @Bindable var engine: SkyEngine

    private var featured: Medal? {
        for id in MedalCatalog.milestoneOrder where engine.medals.earned[id] != nil {
            return MedalCatalog.medal(id)
        }
        return nil
    }

    private static let milestoneIDs = Set(MedalCatalog.milestoneOrder)

    var body: some View {
        SettingsScaffold(theme: .tiers, title: "Tiers & Medals",
                         titleBadge: AnyView(TierBadge(engine: engine, size: 46, tappable: false))) {
            VStack(alignment: .leading, spacing: 24) {
                // Your standing, in metal.
                VStack(spacing: 10) {
                    if let featured {
                        MedalView3D(medal: featured,
                                    award: engine.medals.earned[featured.id],
                                    cameraDistance: 2.7)
                            .frame(height: 240)
                    } else if let first = MedalCatalog.medal("first") {
                        // Nothing earned yet: the first medal as a blank —
                        // spin it, want it.
                        MedalView3D(medal: first, award: nil, cameraDistance: 2.7, locked: true)
                            .frame(height: 240)
                    }
                    Text(engine.spotterTier.name)
                        .font(Theme.display(24, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    if let next = MedalCatalog.nextTier(forSpots: engine.statFlightsSpotted) {
                        VStack(spacing: 8) {
                            ProgressView(value: Double(engine.statFlightsSpotted),
                                         total: Double(next.threshold))
                                .tint(Theme.accent)
                            Text("\(next.threshold - engine.statFlightsSpotted) flights to \(next.name)")
                                .font(Theme.display(12, .semibold).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                                .contentTransition(.numericText())
                        }
                        .padding(.horizontal, 40)
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Tiers")
                    VStack(spacing: 0) {
                        ForEach(Array(MedalCatalog.tiers.enumerated()), id: \.element.name) { i, tier in
                            tierRow(tier)
                            if i < MedalCatalog.tiers.count - 1 {
                                Divider().overlay(.white.opacity(0.08)).padding(.leading, 64)
                            }
                        }
                    }
                    .nightCard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Medals")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                              spacing: 18) {
                        ForEach(MedalCatalog.all.filter { !Self.milestoneIDs.contains($0.id) }) { medal in
                            NavigationLink {
                                MedalDetailView(medal: medal, engine: engine)
                            } label: {
                                VStack(spacing: 6) {
                                    MedalThumb(medal: medal,
                                               earnedDate: engine.medals.earned[medal.id]?.date,
                                               progress: engine.medals.progress(for: medal,
                                                                                totalSpots: engine.statFlightsSpotted),
                                               target: medal.target)
                                    Text(medal.name)
                                        .font(Theme.display(11, .medium))
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    /// One rung of the ladder: the tier's medal, its threshold, and where you
    /// stand — reached, in progress, or still ahead.
    private func tierRow(_ tier: SpotterTier) -> some View {
        let id = MedalCatalog.medalID(for: tier)
        let medal = MedalCatalog.medal(id)
        let reached = engine.statFlightsSpotted >= tier.threshold
        let isCurrent = engine.spotterTier.name == tier.name
        return NavigationLink {
            if let medal { MedalDetailView(medal: medal, engine: engine) }
        } label: {
            HStack(spacing: 14) {
                if let medal {
                    MedalThumb(medal: medal,
                               earnedDate: reached ? (engine.medals.earned[id]?.date ?? Date()) : nil,
                               progress: min(engine.statFlightsSpotted, medal.target),
                               target: medal.target,
                               size: 40)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(tier.name)
                        .font(Theme.display(16, isCurrent ? .bold : .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(tier.threshold == 0 ? "Where everyone begins"
                                             : "\(tier.threshold.formatted()) flights spotted")
                        .font(Theme.display(12, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Text("YOU")
                        .font(Theme.display(10, .bold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.nightBottom)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.accent, in: Capsule())
                } else if reached {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text("\(engine.statFlightsSpotted)/\(tier.threshold)")
                        .font(Theme.display(12, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Medal detail

struct MedalDetailView: View {
    let medal: Medal
    @Bindable var engine: SkyEngine
    @Environment(\.requestReview) private var requestReview

    private var award: MedalAward? { engine.medals.earned[medal.id] }
    private var progress: Int { engine.medals.progress(for: medal, totalSpots: engine.statFlightsSpotted) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                MedalView3D(medal: medal, award: award, cameraDistance: 2.8,
                            locked: award == nil)
                    .frame(height: 380)
                    .padding(.top, 8)
                Text(award != nil ? "Drag to turn it over" : "Not yet earned — drag to spin")
                    .font(Theme.display(11, .medium))
                    .foregroundStyle(Theme.textTertiary)

                VStack(spacing: 8) {
                    Text(medal.name)
                        .font(Theme.display(26, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(medal.requirement)
                        .font(Theme.display(14, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                if let award {
                    VStack(spacing: 3) {
                        Text("Earned \(award.date.formatted(date: .long, time: .omitted))")
                            .font(Theme.display(13, .medium))
                            .foregroundStyle(Theme.textSecondary)
                        if let detail = award.detail {
                            Text(detail)
                                .font(Theme.display(12, .regular).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
                } else {
                    VStack(spacing: 8) {
                        ProgressView(value: Double(progress), total: Double(medal.target))
                            .tint(Theme.accent)
                        Text("\(progress) of \(medal.target)")
                            .font(Theme.display(12, .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 60)
                    .padding(.top, 6)
                }
                Spacer(minLength: 30)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.skyGradient.ignoresSafeArea())
        .preferredColorScheme(.dark)
        // The rating moment: the user is admiring a medal they JUST earned —
        // browsing the shelf months later must never trigger the ask. Gated
        // hard (invested users, ~once per four months) and delayed so the
        // reveal spin finishes before the sheet appears.
        .task {
            guard let award, award.date.timeIntervalSinceNow > -15 * 60,
                  ReviewGate.shouldAsk(spots: engine.statFlightsSpotted,
                                       nights: engine.statDaysUsed) else { return }
            try? await Task.sleep(for: .seconds(2.5))
            // A dismissed view cancels the sleep early — don't burn the ask
            // budget on a prompt nobody will see.
            guard !Task.isCancelled else { return }
            ReviewGate.recordAsk()
            requestReview()
        }
    }
}

#Preview("Medal detail") {
    NavigationStack {
        MedalDetailView(medal: MedalCatalog.all[6], engine: SkyEngine())
    }
}
