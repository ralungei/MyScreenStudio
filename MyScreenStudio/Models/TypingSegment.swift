import Foundation
import CoreGraphics

struct TypingSegment: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: TimeInterval
    var duration: TimeInterval
    var speed: CGFloat = 2.0  // Playback speed multiplier (1x, 2x, 4x, 8x)

    /// Duration in the output video after speed is applied.
    var outputDuration: TimeInterval { duration / Double(speed) }

    static let speedPresets: [CGFloat] = [1, 2, 4, 8]
}

// MARK: - Auto-detection from keystroke timestamps

extension TypingSegment {
    /// Groups consecutive keystroke timestamps into typing segments.
    /// - Parameters:
    ///   - keyTimestamps: sorted array of keystroke times (seconds from recording start)
    ///   - gap: max gap between keystrokes to stay in the same segment (seconds)
    ///   - padding: time added before/after the detected range
    ///   - minKeys: minimum keystrokes to form a segment
    ///   - totalDuration: recording duration to clamp segment bounds
    static func deriveSegments(
        from keyTimestamps: [TimeInterval],
        gap: TimeInterval = 1.5,
        padding: TimeInterval = 0.3,
        minKeys: Int = 4,
        totalDuration: TimeInterval = .infinity
    ) -> [TypingSegment] {
        guard keyTimestamps.count >= minKeys else { return [] }

        var segments: [TypingSegment] = []
        var groupStart = keyTimestamps[0]
        var groupEnd = keyTimestamps[0]
        var groupCount = 1

        for i in 1..<keyTimestamps.count {
            let t = keyTimestamps[i]
            if t - groupEnd <= gap {
                groupEnd = t
                groupCount += 1
            } else {
                // Close current group
                if groupCount >= minKeys {
                    let start = max(0, groupStart - padding)
                    let end = min(totalDuration, groupEnd + padding)
                    segments.append(TypingSegment(start: start, duration: end - start))
                }
                groupStart = t
                groupEnd = t
                groupCount = 1
            }
        }

        // Close last group
        if groupCount >= minKeys {
            let start = max(0, groupStart - padding)
            let end = min(totalDuration, groupEnd + padding)
            segments.append(TypingSegment(start: start, duration: end - start))
        }

        return segments
    }
}
