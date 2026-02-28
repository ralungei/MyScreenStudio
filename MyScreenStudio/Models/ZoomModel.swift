import CoreGraphics
import Foundation

enum ZoomMode: String, Codable, Equatable {
    case auto    // follows cursor
    case manual  // fixed at focus point
}

struct ZoomSegment: Identifiable, Codable, Equatable {
    /// Zoom level above which the zoom is considered "active" (for pan smoothing, sound triggers, etc.)
    static let activeThreshold: CGFloat = 1.05

    var id = UUID()
    var start: TimeInterval           // inicio en segundos
    var duration: TimeInterval        // dur. total (sube + mantiene opcional + baja)
    var peakScale: CGFloat            // p.ej. 1.8
    var focus: CGPoint                // NORMALIZADO [0..1] en coords del video (x,y)
    var ease: Ease = .easeInOut
    var mode: ZoomMode = .auto

    enum Ease: String, Codable {
        case linear, easeIn, easeOut, easeInOut, cubic
    }
}

@MainActor
final class ZoomTimelineStore: ObservableObject {
    @Published var segments: [ZoomSegment] = []
}