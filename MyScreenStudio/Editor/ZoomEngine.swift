import QuartzCore
import AVFoundation

enum ZoomEngine {
    static func timing(_ ease: ZoomSegment.Ease) -> CAMediaTimingFunction {
        switch ease {
        case .linear: return .init(name: .linear)
        case .easeIn: return .init(name: .easeIn)
        case .easeOut: return .init(name: .easeOut)
        case .easeInOut: return .init(name: .easeInEaseOut)
        case .cubic: return CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1.0)
        }
    }

    // transform para escalar alrededor de un foco (en coords de layer)
    static func transform(scale s: CGFloat, focus F: CGPoint) -> CATransform3D {
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, F.x, F.y, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -F.x, -F.y, 0)
        return t
    }

    /// Crea animación keyframe 1 -> peak -> 1, sincronizada.
    /// - Parameters:
    ///   - seg: segmento
    ///   - videoRect: rect del video (en capa) donde mapear el foco normalizado
    ///   - flippedY: true si la capa está invertida (export suele usar `isGeometryFlipped = true`)
    ///   - forPreview: si es preview, beginTime usa AVCoreAnimationBeginTimeAtZero
    static func makeAnimation(for seg: ZoomSegment,
                              videoRect: CGRect,
                              flippedY: Bool,
                              forPreview: Bool) -> CAKeyframeAnimation {
        let fx = videoRect.minX + seg.focus.x * videoRect.width
        let fy = videoRect.minY + (flippedY ? (1 - seg.focus.y) : seg.focus.y) * videoRect.height
        let F = CGPoint(x: fx, y: fy)

        let a = CAKeyframeAnimation(keyPath: "transform")
        let t0 = transform(scale: 1.0, focus: F)
        let t1 = transform(scale: seg.peakScale, focus: F)
        a.values = [t0, t1, t0]
        a.keyTimes = [0, 0.5, 1]
        a.timingFunctions = [timing(seg.ease), timing(seg.ease)]
        a.duration = seg.duration
        a.isRemovedOnCompletion = false
        a.fillMode = .forwards
        a.beginTime = (forPreview ? AVCoreAnimationBeginTimeAtZero : 0) + seg.start
        return a
    }
}