//
//  SkyAudio.swift
//  Skylight AR
//
//  Spatial flyover audio: a procedural engine hum, positioned in 3D for the
//  nearest aircraft and rendered binaurally (HRTF). The listener follows the
//  AR camera, so the sky is audible — point the phone at the sound to find
//  the plane. Works eyes-free; the whole sky for low-vision users.
//

import AVFoundation
import SceneKit

@MainActor
final class SkyAudioEngine {

    private var engine = AVAudioEngine()
    private var environment = AVAudioEnvironmentNode()
    private var players: [String: AVAudioPlayerNode] = [:]   // hex → source
    private let humBuffer: AVAudioPCMBuffer?
    private(set) var running = false
    private let maxSources = 8

    private var graphBuilt = false

    init() {
        // Only the buffer (pure math) at init. Touching AVAudioEngine here
        // spins up CoreAudio at app launch — a crash surface (RPC timeouts)
        // paid even by users who never enable sound.
        humBuffer = Self.makeHumBuffer()

        // A phone call or Siri stops the engine behind our back; without these
        // the soundscape stays dead (running == true blocks any restart) until
        // the user toggles sound off and on.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in self?.handleInterruption(type) }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            guard running else { return }
            // Engine is already stopped by the system; drop the sources so a
            // restart rebuilds them cleanly on the next update.
            for (_, player) in players { player.stop(); engine.detach(player) }
            players.removeAll()
            engine.stop()
            running = false
            wantsResume = true
        case .ended:
            if wantsResume { wantsResume = false; start() }
        default:
            break
        }
    }

    private func handleMediaServicesReset() {
        // Per Apple guidance the whole graph is invalid after a daemon reset:
        // recreate the engine and environment from scratch.
        let wasRunning = running || wantsResume
        players.removeAll()
        engine = AVAudioEngine()
        environment = AVAudioEnvironmentNode()
        graphBuilt = false
        running = false
        wantsResume = false
        if wasRunning { start() }
    }

    /// True while an interruption holds the engine and we owe a restart.
    private var wantsResume = false

    func start() {
        guard !running else { return }
        if !graphBuilt {
            engine.attach(environment)
            engine.connect(environment, to: engine.mainMixerNode,
                           format: engine.mainMixerNode.outputFormat(forBus: 0))
            environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
            environment.distanceAttenuationParameters.referenceDistance = 40
            environment.distanceAttenuationParameters.maximumDistance = 400
            environment.outputVolume = 0.7
            graphBuilt = true
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        do { try engine.start(); running = true } catch { running = false }
    }

    func stop() {
        guard running else { return }
        for (_, player) in players { player.stop(); engine.detach(player) }
        players.removeAll()
        engine.stop()
        running = false
    }

    /// Re-position the soundscape. `sources` are nearest-first world positions
    /// (scene meters); the listener sits at the origin facing `forward`/`up`.
    func update(sources: [(hex: String, position: SCNVector3)],
                forward: simd_float3, up: simd_float3) {
        guard running, let humBuffer else { return }
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(
            forward: AVAudio3DVector(x: forward.x, y: forward.y, z: forward.z),
            up: AVAudio3DVector(x: up.x, y: up.y, z: up.z))

        let wanted = sources.prefix(maxSources)
        let keep = Set(wanted.map(\.hex))
        for (hex, player) in players where !keep.contains(hex) {
            player.stop()
            engine.detach(player)
            players[hex] = nil
        }
        for source in wanted {
            let player: AVAudioPlayerNode
            if let existing = players[source.hex] {
                player = existing
            } else {
                player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: environment, format: humBuffer.format)
                player.renderingAlgorithm = .HRTFHQ
                // Slight per-plane rate variation so the chorus doesn't phase.
                player.rate = 1.0
                player.scheduleBuffer(humBuffer, at: nil, options: [.loops])
                player.volume = 0.85
                player.play()
                players[source.hex] = player
            }
            // Scene positions are ~1000 m out; compress into the audio field.
            player.position = AVAudio3DPoint(x: source.position.x / 8,
                                             y: source.position.y / 8,
                                             z: source.position.z / 8)
        }
    }

    /// 3-second seamless brown-noise loop — reads as a distant jet rumble.
    /// Mono, as spatialization requires.
    private static func makeHumBuffer() -> AVAudioPCMBuffer? {
        let sampleRate = 44_100.0
        let frames = AVAudioFrameCount(sampleRate * 3)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        var seed: UInt64 = 0x5DEECE66D
        var brown: Float = 0
        func nextSample() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let white = Float((seed >> 33) & 0xFFFF) / 32768 - 1
            brown = (brown + 0.02 * white) / 1.02
            return brown * 3.0
        }
        for i in 0..<Int(frames) { data[i] = nextSample() }
        // Seamless wrap: blend the head with the *continuation* of the tail,
        // so sample[last] flows into sample[0] with no discontinuity. (Fading
        // the tail toward the head material would still jump at the wrap.)
        let fade = 4096
        for k in 0..<fade {
            let t = Float(k) / Float(fade)
            data[k] = data[k] * t + nextSample() * (1 - t)
        }
        return buffer
    }
}
