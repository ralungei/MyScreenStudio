import Foundation
import CoreImage
import CoreVideo
import AVFoundation
import Vision
import AppKit
import Observation

@Observable
class VideoEffectsProcessor {
    var zoomLevel: CGFloat = 1.0
    var cursorSmoothness: CGFloat = 0.5
    var showCursor: Bool = true
    var enableMotionBlur: Bool = false
    var enableBackgroundBlur: Bool = false
    
    private var context = CIContext()
    private var cursorTracker = CursorTracker()
    
    func processFrame(_ sampleBuffer: CMSampleBuffer) -> CIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }
        
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        if enableBackgroundBlur {
            ciImage = applyBackgroundBlur(to: ciImage)
        }
        
        if zoomLevel > 1.0 {
            ciImage = applyZoom(to: ciImage, level: zoomLevel)
        }
        
        if enableMotionBlur {
            ciImage = applyMotionBlur(to: ciImage)
        }
        
        if showCursor {
            ciImage = drawCursor(on: ciImage)
        }
        
        return ciImage
    }
    
    private func applyBackgroundBlur(to image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(10.0, forKey: kCIInputRadiusKey)
        return filter.outputImage ?? image
    }
    
    private func applyZoom(to image: CIImage, level: CGFloat) -> CIImage {
        let cursorPosition = cursorTracker.smoothedPosition
        let zoomTransform = CGAffineTransform(scaleX: level, y: level)
        
        let translationX = (1 - level) * cursorPosition.x
        let translationY = (1 - level) * cursorPosition.y
        let translateTransform = CGAffineTransform(translationX: translationX, y: translationY)
        
        let combinedTransform = zoomTransform.concatenating(translateTransform)
        
        return image.transformed(by: combinedTransform)
    }
    
    private func applyMotionBlur(to image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIMotionBlur") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(20.0, forKey: kCIInputRadiusKey)
        filter.setValue(0, forKey: kCIInputAngleKey)
        return filter.outputImage ?? image
    }
    
    private func drawCursor(on image: CIImage) -> CIImage {
        let cursorPosition = cursorTracker.smoothedPosition
        
        guard let cursorFilter = CIFilter(name: "CIRadialGradient") else { return image }
        cursorFilter.setValue(CIVector(x: cursorPosition.x, y: cursorPosition.y), forKey: "inputCenter")
        cursorFilter.setValue(5, forKey: "inputRadius0")
        cursorFilter.setValue(15, forKey: "inputRadius1")
        cursorFilter.setValue(CIColor.white, forKey: "inputColor0")
        cursorFilter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 0.3), forKey: "inputColor1")
        
        guard let cursorImage = cursorFilter.outputImage else { return image }
        
        return cursorImage.composited(over: image)
    }
}

class CursorTracker {
    private var currentPosition = CGPoint.zero
    private var targetPosition = CGPoint.zero
    private let smoothingFactor: CGFloat = 0.2
    
    var smoothedPosition: CGPoint {
        return currentPosition
    }
    
    func updatePosition(_ newPosition: CGPoint) {
        targetPosition = newPosition
        
        let deltaX = (targetPosition.x - currentPosition.x) * smoothingFactor
        let deltaY = (targetPosition.y - currentPosition.y) * smoothingFactor
        
        currentPosition.x += deltaX
        currentPosition.y += deltaY
    }
    
    func getCursorPosition() -> CGPoint {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            return CGPoint(
                x: mouseLocation.x,
                y: screenFrame.height - mouseLocation.y
            )
        }
        return mouseLocation
    }
    
    func startTracking() {
        Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            self.updatePosition(self.getCursorPosition())
        }
    }
}