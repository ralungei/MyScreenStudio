import SwiftUI
import AVFoundation
import AppKit

struct CropEditorView: View {
    let videoURL: URL
    let videoSize: CGSize
    @Binding var cropRect: CropRect
    @Environment(\.dismiss) private var dismiss

    @State private var editingRect: CropRect
    @State private var thumbnailImage: NSImage?

    init(videoURL: URL, videoSize: CGSize, cropRect: Binding<CropRect>) {
        self.videoURL = videoURL
        self.videoSize = videoSize
        self._cropRect = cropRect
        self._editingRect = State(initialValue: cropRect.wrappedValue)
    }

    private var pixelWidth: Int {
        Int(editingRect.width * videoSize.width)
    }

    private var pixelHeight: Int {
        Int(editingRect.height * videoSize.height)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Crop Video")
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(pixelWidth) x \(pixelHeight)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
            }
            .padding()

            Divider()

            // Crop canvas
            GeometryReader { geo in
                let container = geo.size
                let fitted = fitSize(videoSize, in: CGSize(width: container.width - 40, height: container.height - 40))
                let origin = CGPoint(
                    x: (container.width - fitted.width) / 2,
                    y: (container.height - fitted.height) / 2
                )

                ZStack {
                    // Video thumbnail
                    if let image = thumbnailImage {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: origin.x + fitted.width / 2, y: origin.y + fitted.height / 2)
                    } else {
                        Rectangle()
                            .fill(Color.black)
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: origin.x + fitted.width / 2, y: origin.y + fitted.height / 2)
                            .overlay(ProgressView().position(x: origin.x + fitted.width / 2, y: origin.y + fitted.height / 2))
                    }

                    // Dimmed overlay with crop cutout
                    CropOverlay(
                        cropRect: $editingRect,
                        imageOrigin: origin,
                        imageSize: fitted
                    )
                }
            }

            Divider()

            // Footer
            HStack {
                Button("Reset") {
                    editingRect = .full
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .foregroundColor(.secondary)

                Spacer()

                HStack(spacing: 12) {
                    ModernButton("Cancel", style: .secondary) {
                        dismiss()
                    }

                    ModernButton("Save") {
                        cropRect = editingRect
                        dismiss()
                    }
                }
            }
            .padding()
        }
        .frame(width: 720, height: 560)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            generateThumbnail()
        }
    }

    private func fitSize(_ size: CGSize, in container: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 320, height: 180) }
        let ratio = size.width / size.height
        let containerRatio = container.width / container.height
        if containerRatio > ratio {
            let h = container.height
            return CGSize(width: h * ratio, height: h)
        } else {
            let w = container.width
            return CGSize(width: w, height: w / ratio)
        }
    }

    private func generateThumbnail() {
        Task {
            let asset = AVAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1920, height: 1080)

            do {
                let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                await MainActor.run {
                    self.thumbnailImage = nsImage
                }
            } catch {
                print("Failed to generate crop thumbnail: \(error)")
            }
        }
    }
}

// MARK: - Crop Overlay with Draggable Handles

private struct CropOverlay: View {
    @Binding var cropRect: CropRect
    let imageOrigin: CGPoint
    let imageSize: CGSize

    private let handleSize: CGFloat = 12
    private let edgeHitArea: CGFloat = 16

    @State private var dragStart: CropRect? = nil

    private var cropFrame: CGRect {
        CGRect(
            x: imageOrigin.x + cropRect.x * imageSize.width,
            y: imageOrigin.y + cropRect.y * imageSize.height,
            width: cropRect.width * imageSize.width,
            height: cropRect.height * imageSize.height
        )
    }

    var body: some View {
        ZStack {
            // Dimmed regions (4 rects around the crop area)
            dimmedOverlay
                .allowsHitTesting(false)

            // Crop border
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: cropFrame.width, height: cropFrame.height)
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .allowsHitTesting(false)

            // Rule of thirds guides
            ruleOfThirdsGuides
                .allowsHitTesting(false)

            // Corner handles
            cornerHandle(.topLeft)
            cornerHandle(.topRight)
            cornerHandle(.bottomLeft)
            cornerHandle(.bottomRight)

            // Edge handles
            edgeHandle(.top)
            edgeHandle(.bottom)
            edgeHandle(.left)
            edgeHandle(.right)
        }
    }

    // MARK: - Dimmed Overlay

    private var dimmedOverlay: some View {
        Path { p in
            p.addRect(CGRect(origin: imageOrigin, size: imageSize))
            p.addRect(cropFrame)
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
    }

    // MARK: - Rule of Thirds

    @ViewBuilder
    private var ruleOfThirdsGuides: some View {
        let cf = cropFrame
        // Vertical lines
        Path { path in
            path.move(to: CGPoint(x: cf.minX + cf.width / 3, y: cf.minY))
            path.addLine(to: CGPoint(x: cf.minX + cf.width / 3, y: cf.maxY))
            path.move(to: CGPoint(x: cf.minX + cf.width * 2 / 3, y: cf.minY))
            path.addLine(to: CGPoint(x: cf.minX + cf.width * 2 / 3, y: cf.maxY))
        }
        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)

        // Horizontal lines
        Path { path in
            path.move(to: CGPoint(x: cf.minX, y: cf.minY + cf.height / 3))
            path.addLine(to: CGPoint(x: cf.maxX, y: cf.minY + cf.height / 3))
            path.move(to: CGPoint(x: cf.minX, y: cf.minY + cf.height * 2 / 3))
            path.addLine(to: CGPoint(x: cf.maxX, y: cf.minY + cf.height * 2 / 3))
        }
        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
    }

    // MARK: - Corner Handles

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    private enum Edge { case top, bottom, left, right }

    private func cornerHandle(_ corner: Corner) -> some View {
        let pos = cornerPosition(corner)
        return Circle()
            .fill(Color.white)
            .frame(width: handleSize, height: handleSize)
            .shadow(color: .black.opacity(0.3), radius: 2)
            .frame(width: edgeHitArea * 2, height: edgeHitArea * 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = cropRect }
                        guard let start = dragStart else { return }
                        let dx = value.translation.width / imageSize.width
                        let dy = value.translation.height / imageSize.height
                        var r = start
                        switch corner {
                        case .topLeft:
                            r.x = clamp(start.x + dx, min: 0, max: start.x + start.width - 0.05)
                            r.y = clamp(start.y + dy, min: 0, max: start.y + start.height - 0.05)
                            r.width = start.width - (r.x - start.x)
                            r.height = start.height - (r.y - start.y)
                        case .topRight:
                            r.width = clamp(start.width + dx, min: 0.05, max: 1 - start.x)
                            r.y = clamp(start.y + dy, min: 0, max: start.y + start.height - 0.05)
                            r.height = start.height - (r.y - start.y)
                        case .bottomLeft:
                            r.x = clamp(start.x + dx, min: 0, max: start.x + start.width - 0.05)
                            r.width = start.width - (r.x - start.x)
                            r.height = clamp(start.height + dy, min: 0.05, max: 1 - start.y)
                        case .bottomRight:
                            r.width = clamp(start.width + dx, min: 0.05, max: 1 - start.x)
                            r.height = clamp(start.height + dy, min: 0.05, max: 1 - start.y)
                        }
                        cropRect = r
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .position(pos)
    }

    private func cornerPosition(_ corner: Corner) -> CGPoint {
        let cf = cropFrame
        switch corner {
        case .topLeft: return CGPoint(x: cf.minX, y: cf.minY)
        case .topRight: return CGPoint(x: cf.maxX, y: cf.minY)
        case .bottomLeft: return CGPoint(x: cf.minX, y: cf.maxY)
        case .bottomRight: return CGPoint(x: cf.maxX, y: cf.maxY)
        }
    }

    // MARK: - Edge Handles

    private func edgeHandle(_ edge: Edge) -> some View {
        let pos = edgePosition(edge)
        let isHorizontal = (edge == .top || edge == .bottom)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: isHorizontal ? 32 : 6, height: isHorizontal ? 6 : 32)
            .shadow(color: .black.opacity(0.3), radius: 2)
            .frame(width: isHorizontal ? 60 : edgeHitArea * 2, height: isHorizontal ? edgeHitArea * 2 : 60)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = cropRect }
                        guard let start = dragStart else { return }
                        let dx = value.translation.width / imageSize.width
                        let dy = value.translation.height / imageSize.height
                        var r = start
                        switch edge {
                        case .top:
                            r.y = clamp(start.y + dy, min: 0, max: start.y + start.height - 0.05)
                            r.height = start.height - (r.y - start.y)
                        case .bottom:
                            r.height = clamp(start.height + dy, min: 0.05, max: 1 - start.y)
                        case .left:
                            r.x = clamp(start.x + dx, min: 0, max: start.x + start.width - 0.05)
                            r.width = start.width - (r.x - start.x)
                        case .right:
                            r.width = clamp(start.width + dx, min: 0.05, max: 1 - start.x)
                        }
                        cropRect = r
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .position(pos)
    }

    private func edgePosition(_ edge: Edge) -> CGPoint {
        let cf = cropFrame
        switch edge {
        case .top: return CGPoint(x: cf.midX, y: cf.minY)
        case .bottom: return CGPoint(x: cf.midX, y: cf.maxY)
        case .left: return CGPoint(x: cf.minX, y: cf.midY)
        case .right: return CGPoint(x: cf.maxX, y: cf.midY)
        }
    }

    // MARK: - Helpers

    private func clamp(_ value: CGFloat, min minVal: CGFloat, max maxVal: CGFloat) -> CGFloat {
        max(minVal, min(maxVal, value))
    }
}
