import Foundation
import AVFoundation
import CoreImage
import SwiftUI
import QuartzCore

enum ExportError: LocalizedError {
   case noVideoTrack
   case failedToCreateExportSession
   case exportFailed
   case exportCancelled
   
   var errorDescription: String? {
       switch self {
       case .noVideoTrack:
           return "No video track found in the source file"
       case .failedToCreateExportSession:
           return "Failed to create export session"
       case .exportFailed:
           return "Export failed"
       case .exportCancelled:
           return "Export was cancelled"
       }
   }
}

@MainActor
class CALayerVideoExporter2: ObservableObject {
   @Published var isExporting = false
   @Published var exportProgress: Double = 0.0
   
   struct ExportProgress {
       let progress: Float
       let currentFrame: Int
       let totalFrames: Int
       let estimatedTimeRemaining: TimeInterval
   }
   
   @Published var exportProgressData: ExportProgress?
   private var currentExportSession: AVAssetExportSession?
   
   func exportVideoWithEffects(
       sourceVideoURL: URL,
       outputURL: URL,
       backgroundSettings: BackgroundSettings,
       aspectRatio: CGFloat,
       quality: VideoQuality,
       completion: @escaping (Result<URL, Error>) -> Void
   ) {
       isExporting = true
       exportProgress = 0.0
       
       Task {
           do {
               let asset = AVAsset(url: sourceVideoURL)
               let duration = try await asset.load(.duration)
               
               guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                   throw ExportError.noVideoTrack
               }
               
               let naturalSize = try await videoTrack.load(.naturalSize)
               let preferredTransform = try await videoTrack.load(.preferredTransform)
               
               // 🟢 USA el tamaño "visible" después del transform, no el natural
               let displaySize = displayedSize(natural: naturalSize, transform: preferredTransform)
               
               let canvasSize = calculateCanvasSize(
                   videoSize: displaySize,
                   padding: backgroundSettings.padding,
                   aspectRatio: aspectRatio
               )
               
               let composition = AVMutableComposition()
               
               let compositionVideoTrack = composition.addMutableTrack(
                   withMediaType: .video,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               )
               
               try compositionVideoTrack?.insertTimeRange(
                   CMTimeRange(start: .zero, duration: duration),
                   of: videoTrack,
                   at: .zero
               )
               
               if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
                   let compositionAudioTrack = composition.addMutableTrack(
                       withMediaType: .audio,
                       preferredTrackID: kCMPersistentTrackID_Invalid
                   )
                   try compositionAudioTrack?.insertTimeRange(
                       CMTimeRange(start: .zero, duration: duration),
                       of: audioTrack,
                       at: .zero
                   )
               }
               
               let videoComposition = createVideoComposition(
                   canvasSize: canvasSize,
                   videoSize: displaySize,
                   videoTrack: compositionVideoTrack!,
                   backgroundSettings: backgroundSettings,
                   preferredTransform: preferredTransform
               )
               
               guard let exportSession = AVAssetExportSession(
                   asset: composition,
                   presetName: AVAssetExportPresetHighestQuality
               ) else {
                   throw ExportError.failedToCreateExportSession
               }
               
               try? FileManager.default.removeItem(at: outputURL)
               
               exportSession.outputURL = outputURL
               exportSession.outputFileType = .mp4
               exportSession.videoComposition = videoComposition
               exportSession.shouldOptimizeForNetworkUse = true
               
               self.currentExportSession = exportSession
               
               let startTime = Date()
               let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                   Task { @MainActor in
                       let progress = exportSession.progress
                       self.exportProgress = Double(progress)
                       
                       let elapsed = Date().timeIntervalSince(startTime)
                       let estimatedTotal = elapsed / Double(max(progress, 0.001))
                       let estimatedRemaining = max(0, estimatedTotal - elapsed)
                       
                       self.exportProgressData = ExportProgress(
                           progress: progress,
                           currentFrame: Int(progress * 1000),
                           totalFrames: 1000,
                           estimatedTimeRemaining: estimatedRemaining
                       )
                   }
               }
               
               await withCheckedContinuation { continuation in
                   exportSession.exportAsynchronously {
                       progressTimer.invalidate()
                       continuation.resume()
                   }
               }
               
               await MainActor.run {
                   self.isExporting = false
                   self.exportProgressData = nil
                   self.currentExportSession = nil
                   
                   switch exportSession.status {
                   case .completed:
                       completion(.success(outputURL))
                   case .failed:
                       completion(.failure(exportSession.error ?? ExportError.exportFailed))
                   case .cancelled:
                       completion(.failure(ExportError.exportCancelled))
                   default:
                       completion(.failure(ExportError.exportFailed))
                   }
               }
               
           } catch {
               await MainActor.run {
                   self.isExporting = false
                   self.exportProgressData = nil
                   self.currentExportSession = nil
                   completion(.failure(error))
               }
           }
       }
   }
   
   private func calculateCanvasSize(videoSize: CGSize, padding: CGFloat, aspectRatio: CGFloat) -> CGSize {
       if aspectRatio == 0 { // Auto mode: Canvas = Video + Padding
           return CGSize(
               width: ceil((videoSize.width + padding * 2) / 2) * 2,
               height: ceil((videoSize.height + padding * 2) / 2) * 2
           )
       } else {
           // Fixed aspect ratio modes (16:9, 4:3, 1:1)
           let paddedWidth = videoSize.width + padding * 2
           let paddedHeight = videoSize.height + padding * 2
           
           // Calculate canvas size to fit the padded video while maintaining aspect ratio
           let widthBasedHeight = paddedWidth / aspectRatio
           let heightBasedWidth = paddedHeight * aspectRatio
           
           let canvasWidth: CGFloat
           let canvasHeight: CGFloat
           
           // Choose the larger canvas that fits the padded video
           if widthBasedHeight >= paddedHeight {
               // Width determines canvas size
               canvasWidth = paddedWidth
               canvasHeight = widthBasedHeight
           } else {
               // Height determines canvas size
               canvasWidth = heightBasedWidth
               canvasHeight = paddedHeight
           }
           
           // Ensure even dimensions for H.264
           return CGSize(
               width: ceil(canvasWidth / 2) * 2,
               height: ceil(canvasHeight / 2) * 2
           )
       }
   }
   
   private func createVideoComposition(
       canvasSize: CGSize,
       videoSize: CGSize,
       videoTrack: AVMutableCompositionTrack,
       backgroundSettings: BackgroundSettings,
       preferredTransform: CGAffineTransform
   ) -> AVMutableVideoComposition {

       let videoComposition = AVMutableVideoComposition()
       videoComposition.renderSize = canvasSize
       videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

       // Instrucción: SOLO orientación, SIN traslados
       let instruction = AVMutableVideoCompositionInstruction()
       instruction.timeRange = CMTimeRange(start: .zero, duration: videoTrack.timeRange.duration)

       let videoInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
       var t = preferredTransform // orientación correcta del track
       let tx = round((canvasSize.width  - videoSize.width)  / 2.0)
       let ty = round((canvasSize.height - videoSize.height) / 2.0)
       t = t.concatenating(CGAffineTransform(translationX: tx, y: ty)) // lo llevamos al centro
       videoInstruction.setTransform(t, at: .zero)
       instruction.layerInstructions = [videoInstruction]
       videoComposition.instructions = [instruction]

       // --- Core Animation tree ---
       let parentLayer = CALayer()
       parentLayer.frame = CGRect(origin: .zero, size: canvasSize)
       parentLayer.isGeometryFlipped = true // importante en macOS

       // Fondo
       let backgroundLayer = CALayer()
       backgroundLayer.frame = parentLayer.bounds
       if let backgroundImage = backgroundSettings.selectedBackground?.nsImage,
          let cgImage = backgroundImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
           backgroundLayer.contents = cgImage
           backgroundLayer.contentsGravity = .resizeAspectFill
           backgroundLayer.masksToBounds = true
       } else {
           backgroundLayer.backgroundColor = NSColor.black.cgColor // fallback
       }
       parentLayer.addSublayer(backgroundLayer)

       // Rect del vídeo con padding (redondeado)
       let videoRect = CGRect(
           x: round((canvasSize.width  - videoSize.width)  / 2.0),
           y: round((canvasSize.height - videoSize.height) / 2.0),
           width: round(videoSize.width),
           height: round(videoSize.height)
       )

       // Video layer a tamaño completo del canvas
       let videoLayer = CALayer()
       videoLayer.frame = parentLayer.bounds

       // Máscara con el rectángulo centrado y esquinas
       let maskLayer = CAShapeLayer()
       maskLayer.frame = parentLayer.bounds
       maskLayer.path = CGPath(roundedRect: videoRect,
                              cornerWidth: backgroundSettings.cornerRadius,
                              cornerHeight: backgroundSettings.cornerRadius,
                              transform: nil)
       videoLayer.mask = maskLayer

       parentLayer.addSublayer(videoLayer)

       // Sombra elegante con shadowPath y coordenadas correctas
       if backgroundSettings.shadowEnabled {
           let path = CGPath(
               roundedRect: videoRect,
               cornerWidth: backgroundSettings.cornerRadius,
               cornerHeight: backgroundSettings.cornerRadius,
               transform: nil
           )

           func makeShadow(opacity: Float, radius: CGFloat, offsetY: CGFloat) -> CAShapeLayer {
               let s = CAShapeLayer()
               s.frame = parentLayer.bounds
               s.fillColor = NSColor.clear.cgColor           // no tapar
               s.shadowColor = NSColor.black.cgColor
               s.shadowOpacity = opacity
               s.shadowRadius = radius
               s.shadowOffset = CGSize(width: 0, height: offsetY) // Y negativa porque isGeometryFlipped = true
               s.shadowPath = path
               s.shouldRasterize = true
               s.rasterizationScale = 2.0
               return s
           }

           // Menos "halo", más definición
           let ambient = makeShadow(opacity: 0.10, radius: 14, offsetY: -2)
           let key     = makeShadow(opacity: 0.18, radius: 32, offsetY: -10)

           parentLayer.insertSublayer(ambient, above: backgroundLayer)
           parentLayer.insertSublayer(key, above: ambient)
       }

       // Clave: usa postProcessingAsVideoLayer:in: pero con videoLayer pequeño
       videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
           postProcessingAsVideoLayer: videoLayer,
           in: parentLayer
       )

       return videoComposition
   }
   
   func cancelExport() {
       currentExportSession?.cancelExport()
       isExporting = false
       exportProgressData = nil
       currentExportSession = nil
   }
   
   private func displayedSize(natural: CGSize, transform t: CGAffineTransform) -> CGSize {
       // Aplica el transform al rect y usa el size absoluto resultante
       let rect = CGRect(origin: .zero, size: natural).applying(t)
       return CGSize(width: abs(rect.width), height: abs(rect.height))
   }
}
