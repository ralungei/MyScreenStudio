import AVFoundation
import Observation

// MARK: - Click Sound Style

enum ClickSoundStyle: String, CaseIterable, Codable {
    case pop = "Pop"
    case tick = "Tick"
    case bubble = "Bubble"
    case snap = "Snap"
}

// MARK: - Click Sound Player

/// Synthesizes and plays short click sounds using AVAudioEngine.
@MainActor
@Observable
class ClickSoundPlayer {
    var isEnabled: Bool = false
    var style: ClickSoundStyle = .pop
    var volume: CGFloat = 0.7  // 0...1

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var cachedBuffers: [ClickSoundStyle: AVAudioPCMBuffer] = [:]
    private let sampleRate: Double = 44100

    init() {
        setupEngine()
        generateAllBuffers()
    }

    // MARK: - Playback

    func play() {
        guard isEnabled else { return }
        playStyle(style)
    }

    /// Play a specific style (used for preview in UI)
    func playStyle(_ style: ClickSoundStyle) {
        guard let player = playerNode, let buffer = cachedBuffers[style] else { return }
        ensureEngineRunning()
        player.volume = Float(volume)
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            print("ClickSoundPlayer: failed to start engine: \(error)")
        }
        audioEngine = engine
        playerNode = player
    }

    private func ensureEngineRunning() {
        guard let engine = audioEngine, !engine.isRunning else { return }
        try? engine.start()
    }

    // MARK: - Sound Synthesis

    private func generateAllBuffers() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        for style in ClickSoundStyle.allCases {
            cachedBuffers[style] = generateBuffer(for: style, format: format)
        }
    }

    private func generateBuffer(for style: ClickSoundStyle, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let samples: [Float]

        switch style {
        case .pop:
            // Short crisp pop — descending sine with fast decay
            let count = Int(sampleRate * 0.06)
            samples = (0..<count).map { i in
                let t = Double(i) / sampleRate
                let freq = 900.0 * exp(-t * 35)
                let envelope = exp(-t * 45)
                return Float(sin(2.0 * .pi * freq * t) * envelope * 0.8)
            }

        case .tick:
            // Mechanical tick — high-freq burst with noise
            let count = Int(sampleRate * 0.025)
            samples = (0..<count).map { i in
                let t = Double(i) / sampleRate
                let envelope = exp(-t * 150)
                let tone = sin(2.0 * .pi * 2500.0 * t) * 0.6
                let noise = Double(Float.random(in: -1...1)) * 0.4
                return Float((tone + noise) * envelope)
            }

        case .bubble:
            // Soft bubble — wobbling frequency with gentle decay
            let count = Int(sampleRate * 0.1)
            samples = (0..<count).map { i in
                let t = Double(i) / sampleRate
                let freq = 500.0 + 250.0 * sin(t * 60.0)
                let envelope = exp(-t * 22)
                return Float(sin(2.0 * .pi * freq * t) * envelope * 0.7)
            }

        case .snap:
            // Sharp snap — burst of noise + high tone, ultra-short
            let count = Int(sampleRate * 0.018)
            samples = (0..<count).map { i in
                let t = Double(i) / sampleRate
                let attack: Double = i < 3 ? 1.0 : exp(-t * 250)
                let tone = sin(2.0 * .pi * 3500.0 * t) * 0.7
                let noise = Double(Float.random(in: -1...1)) * 0.3
                return Float((tone + noise) * attack)
            }
        }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        if let channelData = buffer.floatChannelData {
            for (i, sample) in samples.enumerated() {
                channelData[0][i] = sample
            }
        }
        return buffer
    }
}
