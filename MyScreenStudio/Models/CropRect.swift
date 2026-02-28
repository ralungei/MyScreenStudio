import CoreGraphics
import Foundation

struct CropRect: Codable, Equatable {
    var x: CGFloat       // normalized 0..1 from left
    var y: CGFloat       // normalized 0..1 from top
    var width: CGFloat   // normalized 0..1
    var height: CGFloat  // normalized 0..1

    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    var isFull: Bool { self == .full }

    func pixelRect(for videoSize: CGSize) -> CGRect {
        CGRect(
            x: x * videoSize.width,
            y: y * videoSize.height,
            width: width * videoSize.width,
            height: height * videoSize.height
        )
    }

    /// The cropped video dimensions in pixels (even numbers for H.264)
    func croppedSize(for videoSize: CGSize) -> CGSize {
        let w = ceil(width * videoSize.width / 2) * 2
        let h = ceil(height * videoSize.height / 2) * 2
        return CGSize(width: max(2, w), height: max(2, h))
    }
}
