//
//  LaunchVideo.swift
//  Skylight AR
//
//  Optional filmed entrance: if the bundle contains `LaunchSplash.mp4`, it
//  plays full-bleed on every cold launch instead of the procedural intro
//  (RootView checks `LaunchVideoView.bundledURL`). Muted, aspect-filled,
//  tap-to-skip, and it dissolves into the AR sky exactly like the drawn
//  entrance. Reduced motion skips the video entirely.
//
//  IMPORTANT: only ship footage the project owns or has licensed in writing.
//  Third-party clips (however short) cannot be bundled.
//

import SwiftUI
import AVFoundation

struct LaunchVideoView: View {
    /// The bundled splash, if one has been added to the app target.
    static var bundledURL: URL? {
        Bundle.main.url(forResource: "LaunchSplash", withExtension: "mp4")
    }

    let url: URL
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player = AVPlayer()
    @State private var dissolving = false

    var body: some View {
        PlayerSurface(player: player)
            .background(Theme.nightBottom)
            .ignoresSafeArea()
            .opacity(dissolving ? 0 : 1)
            .contentShape(Rectangle())
            .onTapGesture { finish() }
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { finish(); return }
                player.isMuted = true          // a launch must never make sound
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                player.play()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
                if (note.object as? AVPlayerItem) === player.currentItem { finish() }
            }
    }

    /// One dissolve for every exit: end of clip, tap, or reduced motion.
    private func finish() {
        guard !dissolving else { return }
        withAnimation(.easeOut(duration: 0.4)) { dissolving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { onFinished() }
    }
}

/// AVPlayerLayer host — aspect-fill, no controls, no AVKit chrome.
private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: Surface, context: Context) {
        view.playerLayer.player = player
    }
}
