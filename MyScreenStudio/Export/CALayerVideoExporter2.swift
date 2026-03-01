import Foundation
import AVFoundation
import CoreImage
import SwiftUI
import QuartzCore
import Observation

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

// MARK: - Cursor + Zoom Export Settings
struct CursorExportSettings {
    var cursorImage: CGImage?
    var cursorHotSpot: CGPoint = .zero
    var cursorScale: CGFloat = 1.0
    var mouseMetadata: CursorMetadata?
    var recordedArea: CGRect?
    var smoothingFactor: CGFloat = 0.12  // Lower = smoother, higher = more responsive
    var showClickEffects: Bool = true
    var clickEffectStyle: ClickEffectStyle = .ripple
    var clickEffectColor: CGColor = NSColor.white.withAlphaComponent(0.6).cgColor
    var clickEffectSize: CGFloat = 1.0
}

struct ZoomExportSettings {
    var segments: [ZoomSegment] = []
    var autoFollowCursor: Bool = true
    var autoFollowScale: CGFloat = 1.15  // Subtle base zoom
    var followSmoothingFactor: CGFloat = 0.04  // Very smooth following
}

@MainActor
@Observable
class CALayerVideoExporter2 {
   var isExporting = false
   var exportProgress: Double = 0.0

   struct ExportProgress {
       let progress: Float
       let currentFrame: Int
       let totalFrames: Int
       let estimatedTimeRemaining: TimeInterval
   }

   var exportProgressData: ExportProgress?
   private var currentExportSession: AVAssetExportSession?

   // MARK: - Main Export Method

   func exportVideoWithEffects(
       sourceVideoURL: URL,
       outputURL: URL,
       backgroundSettings: BackgroundSettings,
       aspectRatio: CGFloat,
       quality: VideoQuality,
       cursorSettings: CursorExportSettings = CursorExportSettings(),
       zoomSettings: ZoomExportSettings = ZoomExportSettings(),
       clips: [VideoClip] = [],
       typingSegments: [TypingSegment] = [],
       cropRect: CropRect = .full,
       completion: @escaping (Result<URL, Error>) -> Void
   ) {
       isExporting = true
       exportProgress = 0.0

       Task {
           do {
               let asset = AVAsset(url: sourceVideoURL)
               let fullDuration = try await asset.load(.duration)

               guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                   throw ExportError.noVideoTrack
               }

               let naturalSize = try await videoTrack.load(.naturalSize)
               let preferredTransform = try await videoTrack.load(.preferredTransform)
               let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)

               let fullDisplaySize = displayedSize(natural: naturalSize, transform: preferredTransform)
               let displaySize = cropRect.isFull ? fullDisplaySize : cropRect.croppedSize(for: fullDisplaySize)

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

               let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
               print("Export: audio track \(audioTrack != nil ? "found" : "NOT found") in source video")
               var compositionAudioTrack: AVMutableCompositionTrack? = nil
               if audioTrack != nil {
                   compositionAudioTrack = composition.addMutableTrack(
                       withMediaType: .audio,
                       preferredTrackID: kCMPersistentTrackID_Invalid
                   )
               }

               // Build composition from clips or full video
               let activeClips = clips.filter { $0.duration > 0 }
               let useClips = !activeClips.isEmpty

               var compositionDuration: CMTime
               // Maps from composition time to source time for cursor/zoom remapping
               var clipTimeMap: [ClipTimeEntry] = []

               if useClips {
                   var insertionTime = CMTime.zero
                   for clip in activeClips {
                       let clipStart = CMTime(seconds: clip.sourceStart, preferredTimescale: 600)
                       let clipDuration = CMTime(seconds: clip.duration, preferredTimescale: 600)
                       let range = CMTimeRange(start: clipStart, duration: clipDuration)

                       try compositionVideoTrack?.insertTimeRange(range, of: videoTrack, at: insertionTime)

                       if let srcAudio = audioTrack {
                           try compositionAudioTrack?.insertTimeRange(range, of: srcAudio, at: insertionTime)
                       }

                       clipTimeMap.append((
                           compositionStart: insertionTime.seconds,
                           sourceStart: clip.sourceStart,
                           duration: clip.duration
                       ))

                       insertionTime = CMTimeAdd(insertionTime, clipDuration)
                   }
                   compositionDuration = insertionTime
               } else {
                   try compositionVideoTrack?.insertTimeRange(
                       CMTimeRange(start: .zero, duration: fullDuration),
                       of: videoTrack,
                       at: .zero
                   )
                   if let srcAudio = audioTrack {
                       try compositionAudioTrack?.insertTimeRange(
                           CMTimeRange(start: .zero, duration: fullDuration),
                           of: srcAudio,
                           at: .zero
                       )
                   }
                   compositionDuration = fullDuration
                   clipTimeMap = [(compositionStart: 0, sourceStart: 0, duration: fullDuration.seconds)]
               }

               // --- Typing Speed Scaling ---
               // Remap typing segments from source time to composition time, then
               // apply scaleTimeRange so typing sections play faster.
               let activeTyping = typingSegments.filter { $0.speed > 1.01 }
               var typingScaleMap: [(compStart: Double, originalDur: Double, scaledDur: Double)] = []

               if !activeTyping.isEmpty {
                   // Map typing segments to composition time
                   var compTyping: [(start: Double, duration: Double, speed: CGFloat)] = []
                   for seg in activeTyping {
                       if useClips {
                           // A typing segment may span multiple clips
                           for entry in clipTimeMap {
                               let clipSourceEnd = entry.sourceStart + entry.duration
                               let segEnd = seg.start + seg.duration
                               let overlapStart = max(seg.start, entry.sourceStart)
                               let overlapEnd = min(segEnd, clipSourceEnd)
                               guard overlapEnd > overlapStart else { continue }
                               let cStart = entry.compositionStart + (overlapStart - entry.sourceStart)
                               let cDur = overlapEnd - overlapStart
                               compTyping.append((start: cStart, duration: cDur, speed: seg.speed))
                           }
                       } else {
                           compTyping.append((start: seg.start, duration: seg.duration, speed: seg.speed))
                       }
                   }

                   // Sort by start time descending so scaleTimeRange doesn't shift later segments
                   compTyping.sort { $0.start > $1.start }

                   for ct in compTyping {
                       let range = CMTimeRange(
                           start: CMTime(seconds: ct.start, preferredTimescale: 600),
                           duration: CMTime(seconds: ct.duration, preferredTimescale: 600)
                       )
                       let scaledDuration = CMTime(seconds: ct.duration / Double(ct.speed), preferredTimescale: 600)
                       composition.scaleTimeRange(range, toDuration: scaledDuration)

                       typingScaleMap.append((
                           compStart: ct.start,
                           originalDur: ct.duration,
                           scaledDur: ct.duration / Double(ct.speed)
                       ))
                   }

                   // Sort ascending for remapping lookups
                   typingScaleMap.sort { $0.compStart < $1.compStart }

                   // Update composition duration after scaling
                   compositionDuration = composition.duration
               }

               // Remap zoom segments from source time to composition time
               var remappedZoomSettings = zoomSettings
               if useClips {
                   remappedZoomSettings.segments = remapZoomSegments(
                       segments: zoomSettings.segments,
                       clipTimeMap: clipTimeMap
                   )
               }
               // Apply typing scale to zoom segments
               if !typingScaleMap.isEmpty {
                   remappedZoomSettings.segments = remappedZoomSettings.segments.map { seg in
                       var s = seg
                       s.start = remapTimeForTypingScale(s.start, scaleMap: typingScaleMap)
                       let end = remapTimeForTypingScale(seg.start + seg.duration, scaleMap: typingScaleMap)
                       s.duration = max(0.01, end - s.start)
                       return s
                   }
               }

               // Remap cursor settings - adjust event timestamps
               var remappedCursorSettings = cursorSettings
               if useClips, let metadata = cursorSettings.mouseMetadata {
                   remappedCursorSettings.mouseMetadata = remapCursorMetadata(
                       metadata: metadata,
                       clipTimeMap: clipTimeMap
                   )
               }
               // Apply typing scale to cursor event timestamps
               if !typingScaleMap.isEmpty, let metadata = remappedCursorSettings.mouseMetadata {
                   var scaled = metadata
                   scaled.events = metadata.events.map { event in
                       MouseEvent(
                           timestamp: remapTimeForTypingScale(event.timestamp, scaleMap: typingScaleMap),
                           position: event.position,
                           type: event.type,
                           windowFrame: event.windowFrame
                       )
                   }
                   remappedCursorSettings.mouseMetadata = scaled
               }

               // Use source fps, clamped to reasonable range
               let fps = max(24, min(60, Int32(round(nominalFrameRate > 0 ? nominalFrameRate : 30))))

               let videoComposition = createVideoComposition(
                   canvasSize: canvasSize,
                   videoSize: displaySize,
                   fullVideoSize: fullDisplaySize,
                   cropRect: cropRect,
                   videoTrack: compositionVideoTrack!,
                   backgroundSettings: backgroundSettings,
                   preferredTransform: preferredTransform,
                   duration: compositionDuration.seconds,
                   fps: fps,
                   cursorSettings: remappedCursorSettings,
                   zoomSettings: remappedZoomSettings
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
               let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                   Task { @MainActor in
                       guard let self = self, let currentSession = self.currentExportSession else { return }

                       let progress = currentSession.progress
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
                       continuation.resume()
                   }
               }

               await MainActor.run {
                   progressTimer.invalidate()
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

   // MARK: - Canvas Size

   private func calculateCanvasSize(videoSize: CGSize, padding: CGFloat, aspectRatio: CGFloat) -> CGSize {
       if aspectRatio == 0 {
           return CGSize(
               width: ceil((videoSize.width + padding * 2) / 2) * 2,
               height: ceil((videoSize.height + padding * 2) / 2) * 2
           )
       } else {
           let paddedWidth = videoSize.width + padding * 2
           let paddedHeight = videoSize.height + padding * 2

           let widthBasedHeight = paddedWidth / aspectRatio
           let heightBasedWidth = paddedHeight * aspectRatio

           let canvasWidth: CGFloat
           let canvasHeight: CGFloat

           if widthBasedHeight >= paddedHeight {
               canvasWidth = paddedWidth
               canvasHeight = widthBasedHeight
           } else {
               canvasWidth = heightBasedWidth
               canvasHeight = paddedHeight
           }

           return CGSize(
               width: ceil(canvasWidth / 2) * 2,
               height: ceil(canvasHeight / 2) * 2
           )
       }
   }

   // MARK: - Video Composition with Cursor + Zoom

   private func createVideoComposition(
       canvasSize: CGSize,
       videoSize: CGSize,
       fullVideoSize: CGSize,
       cropRect: CropRect,
       videoTrack: AVMutableCompositionTrack,
       backgroundSettings: BackgroundSettings,
       preferredTransform: CGAffineTransform,
       duration: Double,
       fps: Int32,
       cursorSettings: CursorExportSettings,
       zoomSettings: ZoomExportSettings
   ) -> AVVideoComposition {

       // Layer instruction (transform for positioning video on canvas)
       var layerConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
       var t = preferredTransform

       if cropRect.isFull {
           // No crop - center full video on canvas
           let tx = round((canvasSize.width  - videoSize.width)  / 2.0)
           let ty = round((canvasSize.height - videoSize.height) / 2.0)
           t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
       } else {
           // Crop: translate so the crop region's top-left maps to the centered video area
           let cropOriginX = cropRect.x * fullVideoSize.width
           let cropOriginY = cropRect.y * fullVideoSize.height
           let tx = round((canvasSize.width  - videoSize.width) / 2.0) - cropOriginX
           let ty = round((canvasSize.height - videoSize.height) / 2.0) - cropOriginY
           t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
       }

       layerConfig.setTransform(t, at: .zero)
       let layerInstruction = AVVideoCompositionLayerInstruction(configuration: layerConfig)

       let instructionConfig = AVVideoCompositionInstruction.Configuration(
           layerInstructions: [layerInstruction],
           timeRange: CMTimeRange(start: .zero, duration: videoTrack.timeRange.duration)
       )
       let instruction = AVVideoCompositionInstruction(configuration: instructionConfig)

       // --- Core Animation Layer Tree ---
       // Structure: parentLayer (clips overflow) → contentGroup (zoom anim)
       //   → backgroundLayer + shadows + clipLayer (rounded corners)
       //     → videoLayer + cursorLayer + clickEffects
       // This ensures background zooms together with the video, matching preview.

       let parentLayer = CALayer()
       parentLayer.frame = CGRect(origin: .zero, size: canvasSize)
       parentLayer.isGeometryFlipped = true
       parentLayer.masksToBounds = true  // Clip zoom overflow

       // Content group - receives zoom transform (background + video zoom together)
       let contentGroup = CALayer()
       contentGroup.frame = parentLayer.bounds

       // Background (inside contentGroup so it zooms)
       let backgroundLayer = CALayer()
       backgroundLayer.frame = contentGroup.bounds
       if let backgroundImage = backgroundSettings.selectedBackground?.nsImage,
          let cgImage = backgroundImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
           backgroundLayer.contents = cgImage
           backgroundLayer.contentsGravity = .resizeAspectFill
           backgroundLayer.masksToBounds = true
       } else {
           backgroundLayer.backgroundColor = NSColor.black.cgColor
       }
       contentGroup.addSublayer(backgroundLayer)

       // Video rect (centered with padding)
       let videoRect = CGRect(
           x: round((canvasSize.width  - videoSize.width)  / 2.0),
           y: round((canvasSize.height - videoSize.height) / 2.0),
           width: round(videoSize.width),
           height: round(videoSize.height)
       )

       // Shadows (below video, inside contentGroup so they zoom too)
       if backgroundSettings.shadowEnabled {
           let path = CGPath(
               roundedRect: videoRect,
               cornerWidth: backgroundSettings.cornerRadius,
               cornerHeight: backgroundSettings.cornerRadius,
               transform: nil
           )
           let ambient = makeShadowLayer(bounds: contentGroup.bounds, path: path, opacity: 0.10, radius: 14, offsetY: -2)
           let key = makeShadowLayer(bounds: contentGroup.bounds, path: path, opacity: 0.18, radius: 32, offsetY: -10)
           contentGroup.addSublayer(ambient)
           contentGroup.addSublayer(key)
       }

       // Clip layer with rounded corners - contains video and cursor
       let clipLayer = CALayer()
       clipLayer.frame = contentGroup.bounds

       let clipMask = CALayer()
       clipMask.frame = videoRect
       clipMask.cornerRadius = backgroundSettings.cornerRadius
       clipMask.cornerCurve = .continuous
       clipMask.backgroundColor = NSColor.black.cgColor
       clipLayer.mask = clipMask

       // Video layer (AVFoundation renders into this)
       let videoLayer = CALayer()
       videoLayer.frame = contentGroup.bounds
       clipLayer.addSublayer(videoLayer)

       // --- Smooth Cursor Positions ---
       let hasMouseData = cursorSettings.mouseMetadata != nil
           && !(cursorSettings.mouseMetadata?.events.isEmpty ?? true)

       var smoothedPositions: [(time: Double, point: CGPoint)] = []

       if hasMouseData, let metadata = cursorSettings.mouseMetadata {
           let fullRecordedArea = cursorSettings.recordedArea
               ?? metadata.recordedArea
               ?? metadata.windowFrame
               ?? CGRect(origin: .zero, size: fullVideoSize)

           // When crop is active, adjust recorded area to match the cropped region
           let recordedArea: CGRect
           if cropRect.isFull {
               recordedArea = fullRecordedArea
           } else {
               recordedArea = CGRect(
                   x: fullRecordedArea.minX + cropRect.x * fullRecordedArea.width,
                   y: fullRecordedArea.minY + cropRect.y * fullRecordedArea.height,
                   width: cropRect.width * fullRecordedArea.width,
                   height: cropRect.height * fullRecordedArea.height
               )
           }

           // Build smoothed cursor positions sampled at fps
           smoothedPositions = buildSmoothedCursorPath(
               events: metadata.events,
               duration: duration,
               fps: Double(fps),
               recordedArea: recordedArea,
               videoRect: videoRect,
               smoothingFactor: cursorSettings.smoothingFactor
           )

           // Cursor and click effects are added to contentGroup (not clipLayer)
           // so they can extend onto the background, matching the preview.
       }

       // clipLayer goes inside contentGroup (video gets rounded corners)
       contentGroup.addSublayer(clipLayer)

       // Cursor layer — outside clipLayer so it extends beyond video edges
       if hasMouseData, let metadata = cursorSettings.mouseMetadata {
           if let cursorCG = cursorSettings.cursorImage {
               let cursorLayer = createCursorLayer(
                   cursorImage: cursorCG,
                   hotSpot: cursorSettings.cursorHotSpot,
                   scale: cursorSettings.cursorScale,
                   videoSize: videoSize,
                   canvasSize: canvasSize,
                   positions: smoothedPositions,
                   duration: duration
               )

               // Click scale animation — cursor shrinks on press, bounces back on release
               if cursorSettings.showClickEffects {
                   addClickScaleAnimation(to: cursorLayer, metadata: metadata, duration: duration)
               }

               contentGroup.addSublayer(cursorLayer)
           }

           // Click effects — also outside clipLayer so they can overflow
           if cursorSettings.showClickEffects {
               addClickEffects(
                   to: contentGroup,
                   metadata: metadata,
                   positions: smoothedPositions,
                   duration: duration,
                   style: cursorSettings.clickEffectStyle,
                   color: cursorSettings.clickEffectColor,
                   sizeMult: cursorSettings.clickEffectSize
               )
           }
       }

       // --- Zoom Animation ---
       let hasZoomSegments = !zoomSettings.segments.isEmpty
       let hasAutoFollow = zoomSettings.autoFollowCursor && !smoothedPositions.isEmpty && zoomSettings.autoFollowScale > 1.01

       if hasZoomSegments || hasAutoFollow {
           let zoomAnimation = createZoomFollowAnimation(
               positions: smoothedPositions,
               videoRect: videoRect,
               canvasSize: canvasSize,
               duration: duration,
               fps: Double(fps),
               zoomSettings: zoomSettings
           )
           contentGroup.add(zoomAnimation, forKey: "zoomFollow")
       }

       // contentGroup (with zoom) goes into parentLayer
       parentLayer.addSublayer(contentGroup)

       // Wire up AVFoundation → videoLayer
       let animToolConfig = AVVideoCompositionCoreAnimationTool.Configuration(
           postProcessingAsVideoLayer: videoLayer,
           containingLayer: parentLayer
       )
       let animationTool = AVVideoCompositionCoreAnimationTool(configuration: animToolConfig)

       // Build final composition using Configuration
       let compositionConfig = AVVideoComposition.Configuration(
           animationTool: animationTool,
           frameDuration: CMTime(value: 1, timescale: fps),
           instructions: [instruction],
           renderSize: canvasSize
       )
       return AVVideoComposition(configuration: compositionConfig)
   }

   // MARK: - Shadow Helper

   private func makeShadowLayer(bounds: CGRect, path: CGPath, opacity: Float, radius: CGFloat, offsetY: CGFloat) -> CAShapeLayer {
       let s = CAShapeLayer()
       s.frame = bounds
       s.fillColor = NSColor.clear.cgColor
       s.shadowColor = NSColor.black.cgColor
       s.shadowOpacity = opacity
       s.shadowRadius = radius
       s.shadowOffset = CGSize(width: 0, height: offsetY)
       s.shadowPath = path
       s.shouldRasterize = true
       s.rasterizationScale = 2.0
       return s
   }

   // MARK: - Smooth Cursor Path

   /// Builds a smoothed array of (time, videoCoord) pairs sampled at the given fps.
   private func buildSmoothedCursorPath(
       events: [MouseEvent],
       duration: Double,
       fps: Double,
       recordedArea: CGRect,
       videoRect: CGRect,
       smoothingFactor: CGFloat
   ) -> [(time: Double, point: CGPoint)] {

       guard !events.isEmpty else { return [] }

       let sampleCount = Int(ceil(duration * fps)) + 1
       var result: [(time: Double, point: CGPoint)] = []
       result.reserveCapacity(sampleCount)

       // Filter to position-relevant events (moves, clicks, drags)
       let posEvents = events.filter { e in
           switch e.type {
           case .scroll: return false
           default: return true
           }
       }

       guard !posEvents.isEmpty else { return [] }

       // Exponential smoothing state — adjusted for frame rate.
       // Preview runs at 30fps; export may run at 60fps. Same coefficient at different
       // rates gives different smoothing speed, so we convert to be frame-rate independent.
       var smoothX: CGFloat = posEvents[0].position.x
       var smoothY: CGFloat = posEvents[0].position.y
       let previewFps: Double = 30.0
       let alpha: CGFloat = 1.0 - pow(1.0 - smoothingFactor, previewFps / fps)

       var eventIndex = 0

       for i in 0..<sampleCount {
           let time = Double(i) / fps

           // Advance event index to latest event at or before this time
           while eventIndex + 1 < posEvents.count && posEvents[eventIndex + 1].timestamp <= time {
               eventIndex += 1
           }

           // Interpolate between current and next event
           let rawPos: CGPoint
           if eventIndex + 1 < posEvents.count {
               let e0 = posEvents[eventIndex]
               let e1 = posEvents[eventIndex + 1]
               let dt = e1.timestamp - e0.timestamp
               if dt > 0.001 {
                   let frac = CGFloat((time - e0.timestamp) / dt)
                   let clampedFrac = max(0, min(1, frac))
                   rawPos = CGPoint(
                       x: e0.position.x + (e1.position.x - e0.position.x) * clampedFrac,
                       y: e0.position.y + (e1.position.y - e0.position.y) * clampedFrac
                   )
               } else {
                   rawPos = posEvents[eventIndex].position
               }
           } else {
               rawPos = posEvents[eventIndex].position
           }

           // Apply exponential smoothing
           smoothX = smoothX + alpha * (rawPos.x - smoothX)
           smoothY = smoothY + alpha * (rawPos.y - smoothY)

           // Convert screen coords to video layer coords (no clamping — cursor can exit frame)
           let normalizedX = (smoothX - recordedArea.minX) / max(recordedArea.width, 1)
           let normalizedY = (smoothY - recordedArea.minY) / max(recordedArea.height, 1)

           let videoX = videoRect.minX + normalizedX * videoRect.width
           let videoY = videoRect.minY + normalizedY * videoRect.height

           result.append((time: time, point: CGPoint(x: videoX, y: videoY)))
       }

       return result
   }

   // MARK: - Cursor Layer

   private func createCursorLayer(
       cursorImage: CGImage,
       hotSpot: CGPoint,
       scale: CGFloat,
       videoSize: CGSize,
       canvasSize: CGSize,
       positions: [(time: Double, point: CGPoint)],
       duration: Double
   ) -> CALayer {

       // Scale cursor relative to video size (aim for ~32pt equivalent on a 1920-wide video)
       let baseSize = max(videoSize.width, videoSize.height) / 60.0
       let cursorW = baseSize * scale
       let cursorH = baseSize * scale * (CGFloat(cursorImage.height) / max(CGFloat(cursorImage.width), 1))

       let cursorLayer = CALayer()
       cursorLayer.contents = cursorImage
       cursorLayer.bounds = CGRect(x: 0, y: 0, width: cursorW, height: cursorH)
       cursorLayer.contentsGravity = .resizeAspect
       cursorLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

       // Offset positions so the hot spot (not the center) is at the tracked position.
       // Same logic as preview: shift by +half_size - hotSpot_offset
       let hotFracX = hotSpot.x / max(CGFloat(cursorImage.width), 1)
       let hotFracY = hotSpot.y / max(CGFloat(cursorImage.height), 1)
       let offsetX = cursorW * (0.5 - hotFracX)
       let offsetY = cursorH * (0.5 - hotFracY)

       let adjustedPositions = positions.map { p in
           (time: p.time, point: CGPoint(x: p.point.x + offsetX, y: p.point.y + offsetY))
       }

       // Set initial position
       if let first = adjustedPositions.first {
           cursorLayer.position = first.point
       }

       // Create position keyframe animation
       if adjustedPositions.count > 1 {
           let posAnim = CAKeyframeAnimation(keyPath: "position")
           posAnim.values = adjustedPositions.map { NSValue(point: NSPoint(x: $0.point.x, y: $0.point.y)) }
           posAnim.keyTimes = adjustedPositions.map { NSNumber(value: $0.time / max(duration, 0.001)) }
           posAnim.duration = duration
           posAnim.beginTime = AVCoreAnimationBeginTimeAtZero
           posAnim.isRemovedOnCompletion = false
           posAnim.fillMode = .both
           posAnim.calculationMode = .linear
           cursorLayer.add(posAnim, forKey: "cursorPosition")
       }

       // Opacity animation — hide cursor when it exits the canvas bounds.
       // Preview clips via .clipShape(); export needs an explicit opacity fade.
       let canvasBounds = CGRect(origin: .zero, size: canvasSize)
       // Small inset margin: once cursor center is past the canvas edge, fade out
       let margin: CGFloat = cursorW * 0.5
       let visibleBounds = canvasBounds.insetBy(dx: -margin, dy: -margin)

       var hasOffscreen = false
       var opacityValues: [NSNumber] = []
       var opacityKeyTimes: [NSNumber] = []
       opacityValues.reserveCapacity(positions.count)
       opacityKeyTimes.reserveCapacity(positions.count)

       for p in positions {
           let keyTime = NSNumber(value: p.time / max(duration, 0.001))
           let isVisible = visibleBounds.contains(p.point)
           opacityValues.append(NSNumber(value: isVisible ? 1.0 : 0.0))
           opacityKeyTimes.append(keyTime)
           if !isVisible { hasOffscreen = true }
       }

       if hasOffscreen {
           let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
           opacityAnim.values = opacityValues
           opacityAnim.keyTimes = opacityKeyTimes
           opacityAnim.duration = duration
           opacityAnim.beginTime = AVCoreAnimationBeginTimeAtZero
           opacityAnim.isRemovedOnCompletion = false
           opacityAnim.fillMode = .both
           opacityAnim.calculationMode = .linear
           cursorLayer.add(opacityAnim, forKey: "cursorVisibility")
       }

       return cursorLayer
   }

   // MARK: - Cursor Click Scale Animation

   /// Adds a scale keyframe animation to the cursor layer so it shrinks on mouseDown and bounces back on mouseUp.
   private func addClickScaleAnimation(to layer: CALayer, metadata: CursorMetadata, duration: Double) {
       guard duration > 0 else { return }

       // Collect press/release transitions
       struct ScaleTransition {
           let time: Double
           let target: CGFloat  // scale value to transition TO
       }

       var transitions: [ScaleTransition] = []

       for event in metadata.events {
           guard event.timestamp >= 0 && event.timestamp <= duration else { continue }
           switch event.type {
           case .leftClick, .rightClick:
               transitions.append(ScaleTransition(time: event.timestamp, target: 0.75))
           case .leftClickUp, .rightClickUp:
               transitions.append(ScaleTransition(time: event.timestamp, target: 1.0))
           default:
               break
           }
       }

       guard !transitions.isEmpty else { return }
       transitions.sort { $0.time < $1.time }

       // Build keyframes: for each transition, hold previous value then animate to new value
       var keyTimes: [NSNumber] = [0]
       var values: [NSNumber] = [1.0]
       var currentScale: CGFloat = 1.0

       let pressDuration: Double = 0.05   // 50ms snap down
       let releaseDuration: Double = 0.10  // 100ms bounce back

       for t in transitions {
           let transTime = t.target < 1.0 ? pressDuration : releaseDuration
           let tNorm = t.time / duration
           let tEndNorm = min(t.time + transTime, duration) / duration

           // Hold current value until just before this transition
           let tBefore = max(tNorm - 0.0001, (keyTimes.last?.doubleValue ?? 0) + 0.0001)
           if tBefore > (keyTimes.last?.doubleValue ?? 0) {
               keyTimes.append(NSNumber(value: tBefore))
               values.append(NSNumber(value: currentScale))
           }

           // Animate to new scale
           if tEndNorm > (keyTimes.last?.doubleValue ?? 0) {
               keyTimes.append(NSNumber(value: tEndNorm))
               values.append(NSNumber(value: t.target))
           }

           currentScale = t.target
       }

       // Hold final value to end
       if (keyTimes.last?.doubleValue ?? 0) < 1.0 {
           keyTimes.append(1.0)
           values.append(NSNumber(value: currentScale))
       }

       let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
       scaleAnim.values = values
       scaleAnim.keyTimes = keyTimes
       scaleAnim.duration = duration
       scaleAnim.beginTime = AVCoreAnimationBeginTimeAtZero
       scaleAnim.isRemovedOnCompletion = false
       scaleAnim.fillMode = .both
       scaleAnim.calculationMode = .linear

       layer.add(scaleAnim, forKey: "clickScale")
   }

   // MARK: - Click Effects

   private func addClickEffects(
       to parentLayer: CALayer,
       metadata: CursorMetadata,
       positions: [(time: Double, point: CGPoint)],
       duration: Double,
       style: ClickEffectStyle,
       color: CGColor,
       sizeMult: CGFloat
   ) {
       let clicks = metadata.events.filter { e in
           switch e.type {
           case .leftClick, .rightClick: return true
           default: return false
           }
       }

       guard !clicks.isEmpty, !positions.isEmpty else { return }

       for click in clicks {
           let clickTime = click.timestamp
           guard clickTime >= 0 && clickTime <= duration else { continue }
           let pos = interpolatePosition(at: clickTime, from: positions)

           switch style {
           case .ring:
               addRingEffect(to: parentLayer, at: pos, time: clickTime, color: color, sizeMult: sizeMult)
           case .ripple:
               addRippleEffect(to: parentLayer, at: pos, time: clickTime, color: color, sizeMult: sizeMult)
           }
       }
   }

   // MARK: Ring Effect — single stroke ring
   private func addRingEffect(to parent: CALayer, at pos: CGPoint, time: Double, color: CGColor, sizeMult: CGFloat) {
       let ringSize: CGFloat = 40 * sizeMult
       let layer = CAShapeLayer()
       layer.bounds = CGRect(x: 0, y: 0, width: ringSize, height: ringSize)
       layer.position = pos
       layer.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: ringSize, height: ringSize), transform: nil)
       layer.fillColor = nil
       layer.strokeColor = color
       layer.lineWidth = 2.5
       layer.opacity = 0

       let scale = CAKeyframeAnimation(keyPath: "transform.scale")
       scale.values = [0.5, 1.5]
       scale.keyTimes = [0, 1]
       scale.duration = 0.35

       let opacity = CAKeyframeAnimation(keyPath: "opacity")
       opacity.values = [0.6, 0.0]
       opacity.keyTimes = [0, 1]
       opacity.duration = 0.35

       let group = CAAnimationGroup()
       group.animations = [scale, opacity]
       group.duration = 0.35
       group.beginTime = AVCoreAnimationBeginTimeAtZero + time
       group.isRemovedOnCompletion = false
       group.fillMode = .forwards

       layer.add(group, forKey: "ring_\(time)")
       parent.addSublayer(layer)
   }

   // MARK: Ripple Effect — 3 concentric rings staggered
   private func addRippleEffect(to parent: CALayer, at pos: CGPoint, time: Double, color: CGColor, sizeMult: CGFloat) {
       let baseSize: CGFloat = 40 * sizeMult
       let delays: [Double] = [0, 0.08, 0.16]

       for (i, delay) in delays.enumerated() {
           let layer = CAShapeLayer()
           layer.bounds = CGRect(x: 0, y: 0, width: baseSize, height: baseSize)
           layer.position = pos
           layer.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: baseSize, height: baseSize), transform: nil)
           layer.fillColor = nil
           layer.strokeColor = color
           layer.lineWidth = 2.0
           layer.opacity = 0

           let scale = CAKeyframeAnimation(keyPath: "transform.scale")
           scale.values = [0.3, 1.8]
           scale.keyTimes = [0, 1]
           scale.duration = 0.4

           let opacity = CAKeyframeAnimation(keyPath: "opacity")
           opacity.values = [0.5, 0.0]
           opacity.keyTimes = [0, 1]
           opacity.duration = 0.4

           let group = CAAnimationGroup()
           group.animations = [scale, opacity]
           group.duration = 0.4
           group.beginTime = AVCoreAnimationBeginTimeAtZero + time + delay
           group.isRemovedOnCompletion = false
           group.fillMode = .forwards

           layer.add(group, forKey: "ripple_\(i)_\(time)")
           parent.addSublayer(layer)
       }
   }

   // MARK: Pulse Effect — filled circle, no stroke
   private func addPulseEffect(to parent: CALayer, at pos: CGPoint, time: Double, color: CGColor, sizeMult: CGFloat) {
       let baseSize: CGFloat = 36 * sizeMult
       let layer = CAShapeLayer()
       layer.bounds = CGRect(x: 0, y: 0, width: baseSize, height: baseSize)
       layer.position = pos
       layer.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: baseSize, height: baseSize), transform: nil)
       layer.fillColor = color
       layer.strokeColor = nil
       layer.opacity = 0

       let scale = CAKeyframeAnimation(keyPath: "transform.scale")
       scale.values = [0.2, 1.2]
       scale.keyTimes = [0, 1]
       scale.duration = 0.3

       let opacity = CAKeyframeAnimation(keyPath: "opacity")
       opacity.values = [0.4, 0.0]
       opacity.keyTimes = [0, 1]
       opacity.duration = 0.3

       let group = CAAnimationGroup()
       group.animations = [scale, opacity]
       group.duration = 0.3
       group.beginTime = AVCoreAnimationBeginTimeAtZero + time
       group.isRemovedOnCompletion = false
       group.fillMode = .forwards

       layer.add(group, forKey: "pulse_\(time)")
       parent.addSublayer(layer)
   }

   // MARK: Spotlight Effect — large soft filled circle
   private func addSpotlightEffect(to parent: CALayer, at pos: CGPoint, time: Double, color: CGColor, sizeMult: CGFloat) {
       let baseSize: CGFloat = 60 * sizeMult
       let layer = CAShapeLayer()
       layer.bounds = CGRect(x: 0, y: 0, width: baseSize, height: baseSize)
       layer.position = pos
       layer.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: baseSize, height: baseSize), transform: nil)
       layer.fillColor = color
       layer.strokeColor = nil
       layer.opacity = 0

       let scale = CAKeyframeAnimation(keyPath: "transform.scale")
       scale.values = [0.5, 2.5]
       scale.keyTimes = [0, 1]
       scale.duration = 0.5

       let opacity = CAKeyframeAnimation(keyPath: "opacity")
       opacity.values = [0.25, 0.0]
       opacity.keyTimes = [0, 1]
       opacity.duration = 0.5

       let group = CAAnimationGroup()
       group.animations = [scale, opacity]
       group.duration = 0.5
       group.beginTime = AVCoreAnimationBeginTimeAtZero + time
       group.isRemovedOnCompletion = false
       group.fillMode = .forwards

       layer.add(group, forKey: "spotlight_\(time)")
       parent.addSublayer(layer)
   }

   // MARK: - Zoom Follow Animation

   /// Creates a CAKeyframeAnimation on "transform" that:
   /// 1. Applies manual zoom segments (from timeline)
   /// 2. Applies subtle auto-follow zoom centered on cursor
   private func createZoomFollowAnimation(
       positions: [(time: Double, point: CGPoint)],
       videoRect: CGRect,
       canvasSize: CGSize,
       duration: Double,
       fps: Double,
       zoomSettings: ZoomExportSettings
   ) -> CAKeyframeAnimation {

       let sampleCount = Int(ceil(duration * fps)) + 1
       var transforms: [NSValue] = []
       var keyTimes: [NSNumber] = []
       transforms.reserveCapacity(sampleCount)
       keyTimes.reserveCapacity(sampleCount)

       // Smooth follow position — works in normalized [0,1] space matching preview's UnitPoint.
       // Preview applies .scaleEffect(level, anchor: UnitPoint(x,y)) where x,y are [0,1]
       // over the full canvas (background + padding + video). We match that here.
       var followNormX: CGFloat = 0.5
       var followNormY: CGFloat = 0.5
       let zoomedAlpha: CGFloat = 1.0 - pow(1.0 - 0.12, 30.0 / fps)

       // Pre-sort segments and hoist constants out of the hot loop
       let sorted = zoomSettings.segments.sorted { $0.start < $1.start }
       let bridgeThreshold: Double = 0.3
       let easeZone: CGFloat = 0.25

       /// Smootherstep — matches preview's steeper ease curve
       func ss(_ t: CGFloat) -> CGFloat { t * t * t * (t * (6.0 * t - 15.0) + 10.0) }

       // Initialize to first cursor position (normalized within video content)
       if let first = positions.first {
           followNormX = (first.point.x - videoRect.minX) / videoRect.width
           followNormY = (first.point.y - videoRect.minY) / videoRect.height
       }

       for i in 0..<sampleCount {
           let time = Double(i) / fps
           let normalizedTime = time / max(duration, 0.001)

           // Get cursor position normalized to [0,1] within video content
           let normCurX: CGFloat
           let normCurY: CGFloat
           if !positions.isEmpty {
               let p = interpolatePosition(at: time, from: positions)
               normCurX = (p.x - videoRect.minX) / videoRect.width
               normCurY = (p.y - videoRect.minY) / videoRect.height
           } else {
               normCurX = 0.5
               normCurY = 0.5
           }

           // --- Manual focus (crossfade only in ease-in zone; hold in ease-out when next exists) ---
           var manualFocus: CGPoint? = nil
           for (idx, seg) in sorted.enumerated() {
               let segEnd = seg.start + seg.duration
               guard time >= seg.start && time <= segEnd else { continue }
               let prevSeg: ZoomSegment? = (idx > 0 && (seg.start - (sorted[idx - 1].start + sorted[idx - 1].duration)) < bridgeThreshold) ? sorted[idx - 1] : nil
               let progress = CGFloat((time - seg.start) / seg.duration)
               if progress < easeZone, let prev = prevSeg {
                   let t = ss(progress / easeZone)
                   if prev.mode == .manual && seg.mode == .manual {
                       manualFocus = CGPoint(x: prev.focus.x + (seg.focus.x - prev.focus.x) * t,
                                             y: prev.focus.y + (seg.focus.y - prev.focus.y) * t)
                   } else {
                       manualFocus = seg.mode == .manual ? seg.focus : (prev.mode == .manual ? prev.focus : nil)
                   }
               } else {
                   // Hold this segment's focus (middle or ease-out — next seg's ease-in handles transition)
                   manualFocus = seg.mode == .manual ? seg.focus : nil
               }
               break
           }
           // Bridge gap focus
           if manualFocus == nil {
               for idx in 0..<max(0, sorted.count - 1) {
                   let s1 = sorted[idx]; let s2 = sorted[idx + 1]
                   let s1End = s1.start + s1.duration; let gap = s2.start - s1End
                   if gap > 0 && gap < bridgeThreshold && time > s1End && time < s2.start {
                       let t = ss(CGFloat((time - s1End) / gap))
                       if s1.mode == .manual && s2.mode == .manual {
                           manualFocus = CGPoint(x: s1.focus.x + (s2.focus.x - s1.focus.x) * t,
                                                 y: s1.focus.y + (s2.focus.y - s1.focus.y) * t)
                       } else if s1.mode == .manual { manualFocus = s1.focus }
                       else if s2.mode == .manual { manualFocus = s2.focus }
                       break
                   }
               }
           }

           // --- Zoom scale first (matches preview: zoom computed before anchor) ---
           var scale: CGFloat = 1.0
           var hitSegment = false
           for (idx, seg) in sorted.enumerated() {
               let segEnd = seg.start + seg.duration
               guard time >= seg.start && time <= segEnd else { continue }
               hitSegment = true
               let prevSeg: ZoomSegment? = (idx > 0 && (seg.start - (sorted[idx - 1].start + sorted[idx - 1].duration)) < bridgeThreshold) ? sorted[idx - 1] : nil
               let hasNext = idx < sorted.count - 1 && (sorted[idx + 1].start - segEnd) < bridgeThreshold
               let progress = CGFloat((time - seg.start) / seg.duration)
               if progress < easeZone {
                   let t = ss(progress / easeZone)
                   let fromScale = prevSeg?.peakScale ?? 1.0
                   scale = max(scale, fromScale + (seg.peakScale - fromScale) * t)
               } else if progress > (1.0 - easeZone) && !hasNext {
                   // Standard ease-out to 1.0 (no successor)
                   let t = ss((progress - (1.0 - easeZone)) / easeZone)
                   scale = max(scale, seg.peakScale + (1.0 - seg.peakScale) * t)
               } else {
                   // Hold peak (middle, or has next so skip ease-out)
                   scale = max(scale, seg.peakScale)
               }
           }
           // Bridge gap scale
           if !hitSegment {
               for idx in 0..<max(0, sorted.count - 1) {
                   let s1 = sorted[idx]; let s2 = sorted[idx + 1]
                   let s1End = s1.start + s1.duration; let gap = s2.start - s1End
                   if gap > 0 && gap < bridgeThreshold && time > s1End && time < s2.start {
                       let t = ss(CGFloat((time - s1End) / gap))
                       scale = s1.peakScale + (s2.peakScale - s1.peakScale) * t
                       hitSegment = true
                       break
                   }
               }
           }

           // Auto-follow zoom (additive when no manual segment active)
           if zoomSettings.autoFollowCursor && !positions.isEmpty && scale < 1.01 {
               scale = zoomSettings.autoFollowScale
           }

           // --- Follow position in normalized [0,1] space (matches preview's UnitPoint) ---
           // Preview: zoomAnchor = UnitPoint(x: smoothedCurX, y: smoothedCurY)
           // where smoothedCurX/Y are normalized [0,1] within video content,
           // applied as UnitPoint on the full canvas (including padding).
           let followAlpha: CGFloat = scale > ZoomSegment.activeThreshold ? zoomedAlpha : 1.0
           if let focus = manualFocus {
               // focus.x/y are already normalized [0,1] — use directly (matches preview)
               followNormX += followAlpha * (focus.x - followNormX)
               followNormY += followAlpha * (focus.y - followNormY)
           } else {
               followNormX += followAlpha * (normCurX - followNormX)
               followNormY += followAlpha * (normCurY - followNormY)
           }

           // Convert normalized [0,1] to canvas pixels (matching preview's UnitPoint on full canvas)
           let focusX = followNormX * canvasSize.width
           let focusY = followNormY * canvasSize.height

           // CALayer.transform is applied relative to the anchor point (default 0.5, 0.5),
           // so express the focus offset relative to the canvas center.
           let relX = focusX - canvasSize.width / 2
           let relY = focusY - canvasSize.height / 2
           var transform = CATransform3DIdentity
           transform = CATransform3DTranslate(transform, relX, relY, 0)
           transform = CATransform3DScale(transform, scale, scale, 1)
           transform = CATransform3DTranslate(transform, -relX, -relY, 0)

           transforms.append(NSValue(caTransform3D: transform))
           keyTimes.append(NSNumber(value: normalizedTime))
       }

       let animation = CAKeyframeAnimation(keyPath: "transform")
       animation.values = transforms
       animation.keyTimes = keyTimes
       animation.duration = duration
       animation.beginTime = AVCoreAnimationBeginTimeAtZero
       animation.isRemovedOnCompletion = false
       animation.fillMode = .both
       animation.calculationMode = .linear
       return animation
   }

   // MARK: - Helpers

   private func interpolatePosition(at time: Double, from positions: [(time: Double, point: CGPoint)]) -> CGPoint {
       guard !positions.isEmpty else { return .zero }
       guard positions.count > 1 else { return positions[0].point }

       // Binary search for the right interval
       var lo = 0
       var hi = positions.count - 1

       if time <= positions[lo].time { return positions[lo].point }
       if time >= positions[hi].time { return positions[hi].point }

       while hi - lo > 1 {
           let mid = (lo + hi) / 2
           if positions[mid].time <= time {
               lo = mid
           } else {
               hi = mid
           }
       }

       let p0 = positions[lo]
       let p1 = positions[hi]
       let dt = p1.time - p0.time
       guard dt > 0.0001 else { return p0.point }

       let frac = CGFloat((time - p0.time) / dt)
       return CGPoint(
           x: p0.point.x + (p1.point.x - p0.point.x) * frac,
           y: p0.point.y + (p1.point.y - p0.point.y) * frac
       )
   }

   func cancelExport() {
       currentExportSession?.cancelExport()
       isExporting = false
       exportProgressData = nil
       currentExportSession = nil
   }

   private func displayedSize(natural: CGSize, transform t: CGAffineTransform) -> CGSize {
       let rect = CGRect(origin: .zero, size: natural).applying(t)
       return CGSize(width: abs(rect.width), height: abs(rect.height))
   }

   // MARK: - Clip Time Remapping (delegates to shared ClipTimeMapping)

   private func sourceToCompositionTime(
       _ sourceTime: Double,
       clipTimeMap: [ClipTimeEntry]
   ) -> Double? {
       ClipTimeMapping.sourceToCompositionTime(sourceTime, clipTimeMap: clipTimeMap)
   }

   private func remapZoomSegments(
       segments: [ZoomSegment],
       clipTimeMap: [ClipTimeEntry]
   ) -> [ZoomSegment] {
       ClipTimeMapping.remapZoomSegments(segments, clipTimeMap: clipTimeMap)
   }

   /// Convert a pre-scale composition time to post-scale time accounting for typing speed-ups.
   /// scaleMap entries are sorted ascending by compStart and represent segments that were
   /// compressed (originalDur → scaledDur). Everything after each segment shifts earlier.
   private func remapTimeForTypingScale(
       _ time: Double,
       scaleMap: [(compStart: Double, originalDur: Double, scaledDur: Double)]
   ) -> Double {
       var offset: Double = 0  // cumulative shift from earlier scaled segments
       for entry in scaleMap {
           let segStart = entry.compStart
           let segEnd = entry.compStart + entry.originalDur

           if time <= segStart {
               // Before this segment — just apply accumulated offset
               break
           } else if time >= segEnd {
               // After this segment — full compression delta applies
               offset += entry.scaledDur - entry.originalDur  // negative value (shrink)
           } else {
               // Inside this segment — proportional compression
               let frac = (time - segStart) / entry.originalDur
               let scaledTime = segStart + offset + frac * entry.scaledDur
               return scaledTime
           }
       }
       return time + offset
   }

   private func remapCursorMetadata(
       metadata: CursorMetadata,
       clipTimeMap: [ClipTimeEntry]
   ) -> CursorMetadata {
       ClipTimeMapping.remapCursorMetadata(metadata, clipTimeMap: clipTimeMap)
   }
}
