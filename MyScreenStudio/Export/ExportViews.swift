import SwiftUI
import AVFoundation

// MARK: - Export Configuration View
struct ExportConfigurationView: View {
    let project: RecordingProject
    let backgroundSettings: BackgroundSettings
    let videoSize: CGSize
    let aspectRatio: CGFloat
    var exportManager: CALayerVideoExporter2
    @Binding var showingExportProgress: Bool
    var cursorManager: CursorManager?
    var mouseMetadata: CursorMetadata?
    var zoomSegments: [ZoomSegment] = []
    var videoClips: [VideoClip] = []
    var typingSegments: [TypingSegment] = []
    var cropRect: CropRect = .full

    @State private var selectedQuality: VideoQuality = .ultra
    @State private var selectedFormat: ExportFormat = .mp4
    @State private var outputFileName: String = ""
    @Environment(\.dismiss) private var dismiss
    
    enum ExportFormat: String, CaseIterable {
        case mp4 = "MP4"
        case mov = "MOV"
        
        var fileExtension: String {
            switch self {
            case .mp4: return "mp4"
            case .mov: return "mov"
            }
        }
    }
    
    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Compact Header with icon
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(.blue.opacity(0.1))
                                .frame(width: 40, height: 40)
                            
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.blue)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Export Video")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            Text("\(Int(calculateOutputSize().width))×\(Int(calculateOutputSize().height)) • \(selectedQuality.rawValue)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(.top, 4)
                    
                    // File Name - Compact Style
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "textformat.abc")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 16))
                            
                            Text("File Name")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            Spacer()
                        }
                        
                        TextField("Enter file name", text: $outputFileName)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                    }
                    
                    // Quality & Format - Pill Style
                    HStack(spacing: 16) {
                        // Quality
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "4k.tv")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 14))
                                
                                Text("Quality")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                
                                Spacer()
                            }
                            
                            Picker("Quality", selection: $selectedQuality) {
                                ForEach(VideoQuality.allCases, id: \.self) { quality in
                                    Text(quality.rawValue).tag(quality)
                                }
                            }
                            .pickerStyle(.menu)
                            .background(.gray.opacity(0.08))
                            .cornerRadius(8)
                        }
                        
                        // Format
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "doc.circle")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 14))
                                
                                Text("Format")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                
                                Spacer()
                            }
                            
                            Picker("Format", selection: $selectedFormat) {
                                ForEach(ExportFormat.allCases, id: \.self) { format in
                                    Text(format.rawValue).tag(format)
                                }
                            }
                            .pickerStyle(.menu)
                            .background(.gray.opacity(0.08))
                            .cornerRadius(8)
                        }
                    }
                    
                    // Export Summary - Compact Pills
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 16))
                            
                            Text("Export Summary")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            Spacer()
                        }
                        
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 8) {
                            SummaryPill(icon: "photo", label: "Background", value: backgroundSettings.selectedBackground?.name ?? "None")
                            SummaryPill(icon: "square.resize", label: "Padding", value: "\(Int(backgroundSettings.padding))px")
                            SummaryPill(icon: "roundedrectangle", label: "Corners", value: "\(Int(backgroundSettings.cornerRadius))px")
                            SummaryPill(icon: "shadow", label: "Shadow", value: backgroundSettings.shadowEnabled ? "On" : "Off")
                        }
                    }
                    
                    // Action Buttons - Modern Style
                    HStack(spacing: 12) {
                        ModernButton("Cancel", style: .secondary) {
                            dismiss()
                        }
                        
                        ModernButton("Export Video", 
                                   disabled: outputFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            startExport()
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(24)
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
        .frame(width: 420, height: 520)
        .onAppear {
            // Auto-generate filename
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            outputFileName = "\(project.name)_\(formatter.string(from: Date()))"
        }
    }
    
    // MARK: - Helper Methods
    private func calculateOutputSize() -> CGSize {
        let vs = cropRect.isFull ? videoSize : cropRect.croppedSize(for: videoSize)
        let paddedWidth = vs.width + (backgroundSettings.padding * 2)
        let paddedHeight = vs.height + (backgroundSettings.padding * 2)

        if aspectRatio == 0 { // Auto mode
            return CGSize(
                width: ceil(paddedWidth / 2) * 2,
                height: ceil(paddedHeight / 2) * 2
            )
        } else {
            // Fixed aspect ratio modes
            let containerHeight = paddedHeight
            let containerWidth = containerHeight * aspectRatio

            let finalWidth = max(ceil(containerWidth / 2) * 2, 1920)
            let finalHeight = ceil(finalWidth / aspectRatio / 2) * 2

            return CGSize(width: finalWidth, height: finalHeight)
        }
    }
    
    private func startExport() {
        let fileName = outputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileExtension = selectedFormat.fileExtension
        let outputURL = getExportURL(fileName: "\(fileName).\(fileExtension)")

        let sourceVideoURL = URL(fileURLWithPath: project.videoPath)

        // Build cursor export settings
        var cursorSettings = CursorExportSettings()
        if let cm = cursorManager, cm.isEnabled, let selected = cm.selectedCursor, !selected.imagePath.isEmpty {
            if let nsImg = NSImage(contentsOfFile: selected.imagePath),
               let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cursorSettings.cursorImage = cgImg
                // Convert hotspot from NSImage points to CGImage pixels
                // (export divides by CGImage pixel dimensions)
                let scaleX = CGFloat(cgImg.width) / max(nsImg.size.width, 1)
                let scaleY = CGFloat(cgImg.height) / max(nsImg.size.height, 1)
                cursorSettings.cursorHotSpot = CGPoint(
                    x: selected.hotSpot.x * scaleX,
                    y: selected.hotSpot.y * scaleY
                )
                cursorSettings.cursorScale = cm.cursorScale
                cursorSettings.smoothingFactor = cm.smoothing
            }
        }
        // Click effect settings work independently of cursor image
        if let cm = cursorManager {
            cursorSettings.showClickEffects = cm.showClickEffects
            cursorSettings.clickEffectStyle = cm.clickEffectStyle
            cursorSettings.clickEffectColor = NSColor(cm.clickEffectColor).cgColor
            cursorSettings.clickEffectSize = cm.clickEffectSize
        }
        cursorSettings.mouseMetadata = mouseMetadata
        cursorSettings.recordedArea = mouseMetadata?.recordedArea ?? mouseMetadata?.windowFrame

        // Build zoom export settings
        var zoomExportSettings = ZoomExportSettings()
        zoomExportSettings.segments = zoomSegments
        zoomExportSettings.autoFollowCursor = false  // Preview has no auto-follow — only manual segments
        zoomExportSettings.autoFollowScale = 1.15

        // Use the shared exportManager so progress updates reach ExportProgressView
        exportManager.exportVideoWithEffects(
            sourceVideoURL: sourceVideoURL,
            outputURL: outputURL,
            backgroundSettings: backgroundSettings,
            aspectRatio: aspectRatio,
            quality: selectedQuality,
            cursorSettings: cursorSettings,
            zoomSettings: zoomExportSettings,
            clips: videoClips,
            typingSegments: typingSegments,
            cropRect: cropRect
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    print("✅ Export completed: \(url.path)")
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                case .failure(let error):
                    print("❌ Export failed: \(error.localizedDescription)")
                }
                showingExportProgress = false
            }
        }

        // Dismiss config sheet first, then show progress
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            showingExportProgress = true
        }
    }
    
    private func getExportURL(fileName: String) -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let exportsFolder = documentsPath.appendingPathComponent("MyScreenStudio/Exports")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: exportsFolder, withIntermediateDirectories: true)
        
        return exportsFolder.appendingPathComponent(fileName)
    }
}

// MARK: - Export Progress View
struct ExportProgressView: View {
    var exportManager: CALayerVideoExporter2
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // Progress ring + percentage
            ZStack {
                Circle()
                    .stroke(.gray.opacity(0.15), lineWidth: 6)
                    .frame(width: 88, height: 88)

                Circle()
                    .trim(from: 0, to: CGFloat(exportManager.exportProgress))
                    .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 88, height: 88)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: exportManager.exportProgress)

                Text(String(format: "%.0f%%", exportManager.exportProgress * 100))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }

            VStack(spacing: 4) {
                Text("Exporting Video")
                    .font(.headline)

                // Stats inline — monospaced to prevent jitter
                if let p = exportManager.exportProgressData {
                    Text("Frame \(p.currentFrame)/\(p.totalFrames)  ·  \(TimeFormatting.mmss(p.estimatedTimeRemaining)) left")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Preparing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ModernButton("Cancel Export", style: .destructive) {
                exportManager.cancelExport()
                dismiss()
            }
        }
        .padding(28)
        .frame(width: 280)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        .onChange(of: exportManager.isExporting) { _, isExporting in
            if !isExporting {
                dismiss()
            }
        }
    }
}

// MARK: - Summary Pill Component
struct SummaryPill: View {
    let icon: String
    let label: String
    let value: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                Text(value)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.gray.opacity(0.06))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.gray.opacity(0.1), lineWidth: 0.5)
        )
    }
}



