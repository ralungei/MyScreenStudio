import Foundation

struct VideoClip: Identifiable, Equatable, Codable {
    var id = UUID()
    var sourceStart: TimeInterval
    var sourceEnd: TimeInterval
    var label: String = ""

    var duration: TimeInterval { sourceEnd - sourceStart }

    static func == (lhs: VideoClip, rhs: VideoClip) -> Bool {
        lhs.id == rhs.id && lhs.sourceStart == rhs.sourceStart && lhs.sourceEnd == rhs.sourceEnd
    }
}
