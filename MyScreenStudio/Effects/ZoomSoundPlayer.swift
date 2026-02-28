@preconcurrency import AVFoundation
import Observation

// MARK: - Zoom Sound Player

/// Synthesizes and plays short whoosh sounds on zoom transitions using AVAudioEngine.
@MainActor
@Observable
class ZoomSoundPlayer {
    var isEnabled: Bool = false
    var volume: CGFloat = 0.7  // 0...1

    /// How far ahead (seconds) the sound triggers before the visual transition.
    static let anticipation: Double = 0.12

    // Internal state — excluded from observation to avoid 30fps mutation noise
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var playerNode: AVAudioPlayerNode?
    @ObservationIgnored private var zoomInBuffer: AVAudioPCMBuffer?
    @ObservationIgnored private var zoomOutBuffer: AVAudioPCMBuffer?
    @ObservationIgnored private var isSetUp = false
    @ObservationIgnored private var wasZoomed = false
    @ObservationIgnored private var lastPlayTime: CFTimeInterval = 0
    @ObservationIgnored private let sampleRate: Double = 44100

    private static let cooldown: CFTimeInterval = 0.25

    // MARK: - Zoom Transition Detection

    /// Call from the time observer with the *look-ahead* zoom level.
    func updateZoomLevel(_ level: CGFloat) {
        let isZoomed = level > ZoomSegment.activeThreshold
        if isZoomed && !wasZoomed {
            playZoomIn()
        } else if !isZoomed && wasZoomed {
            playZoomOut()
        }
        wasZoomed = isZoomed
    }

    func resetState() {
        wasZoomed = false
    }

    // MARK: - Playback

    func playZoomIn() {
        guard isEnabled else { return }
        ensureSetUp()
        guard let buffer = zoomInBuffer else { return }
        playBuffer(buffer)
    }

    func playZoomOut() {
        guard isEnabled else { return }
        ensureSetUp()
        guard let buffer = zoomOutBuffer else { return }
        playBuffer(buffer)
    }

    private func playBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let player = playerNode else { return }
        let now = CACurrentMediaTime()
        guard now - lastPlayTime >= Self.cooldown else { return }
        lastPlayTime = now

        ensureEngineRunning()
        player.stop()
        player.volume = Float(volume)
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
    }

    // MARK: - Lazy Setup

    private func ensureSetUp() {
        guard !isSetUp else { return }
        isSetUp = true
        setupEngine()
        generateBuffers()
    }

    // MARK: - Engine

    private func setupEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch {
            print("ZoomSoundPlayer: engine start failed: \(error)")
        }
        audioEngine = engine
        playerNode = player
    }

    private func ensureEngineRunning() {
        guard let engine = audioEngine, !engine.isRunning else { return }
        try? engine.start()
    }

    /// Stops the audio engine and releases resources. Call from .onDisappear.
    func tearDown() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        zoomInBuffer = nil
        zoomOutBuffer = nil
        isSetUp = false
    }

    // MARK: - Sound Synthesis

    private func generateBuffers() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        zoomInBuffer = generateWhoosh(rising: true, format: format)
        zoomOutBuffer = generateWhoosh(rising: false, format: format)
    }

    /// Synthesizes a short swoosh — rising pitch for zoom-in, falling for zoom-out.
    private func generateWhoosh(rising: Bool, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let duration = 0.16
        let count = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: count)

        // Seeded random for deterministic noise
        var rng: UInt64 = rising ? 0xDEAD_BEEF : 0xCAFE_BABE

        for i in 0..<count {
            let t = Double(i) / sampleRate
            let progress = t / duration  // 0…1

            // Frequency sweep (exponential)
            let freq: Double
            if rising {
                freq = 400.0 * pow(4.0, progress)   // 400 → 1600 Hz
            } else {
                freq = 1600.0 * pow(0.25, progress)  // 1600 → 400 Hz
            }

            // Envelope: 3ms attack, hold, fade out last 35%
            let attack = min(t / 0.003, 1.0)
            let fadeStart = 0.65
            let release = progress > fadeStart ? max(1.0 - (progress - fadeStart) / (1.0 - fadeStart), 0.0) : 1.0
            let envelope = attack * release

            // Tone: sine sweep
            let phase = 2.0 * .pi * freq * t
            let tone = sin(phase) * 0.5

            // Noise: deterministic pseudo-random, shaped by envelope
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let noiseVal = Double(Int64(bitPattern: rng >> 33)) / Double(Int64.max)
            let noise = noiseVal * 0.35

            samples[i] = Float((tone + noise) * envelope * 0.75)
        }

        let frameCount = AVAudioFrameCount(count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        if let data = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                data[0].update(from: src.baseAddress!, count: count)
            }
        }
        return buffer
    }
}
