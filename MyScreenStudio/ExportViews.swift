import SwiftUI
import AVFoundation

// MARK: - Export Configuration View
struct ExportConfigurationView: View {
    let project: RecordingProject
    let backgroundSettings: BackgroundSettings
    let videoSize: CGSize
    let aspectRatio: CGFloat
    @ObservedObject var exportManager: CALayerVideoExporter2
    @Binding var showingExportProgress: Bool
    
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
            // Dynamic Island inspired background
            RoundedRectangle(cornerRadius: 28)
                .fill(.ultraThinMaterial)
                .background(
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.black.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                )
            
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
                            .background(.gray.opacity(0.08))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.gray.opacity(0.2), lineWidth: 1)
                            )
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
        let paddedWidth = videoSize.width + (backgroundSettings.padding * 2)
        let paddedHeight = videoSize.height + (backgroundSettings.padding * 2)
        
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
    
    private var aspectRatioText: String {
        if aspectRatio == 16.0/9.0 {
            return "16:9"
        } else if aspectRatio == 4.0/3.0 {
            return "4:3"
        } else if aspectRatio == 1.0 {
            return "1:1"
        } else {
            return String(format: "%.2f:1", aspectRatio)
        }
    }
    
    private func startExport() {
        // Create output URL
        let fileName = outputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileExtension = selectedFormat.fileExtension
        let outputURL = getExportURL(fileName: "\(fileName).\(fileExtension)")
        
        // Use NEW CALayer-based exporter (CORRECT APPROACH)
        let layerExporter = CALayerVideoExporter2()
        let sourceVideoURL = URL(fileURLWithPath: project.videoPath)
        
        layerExporter.exportVideoWithEffects(
            sourceVideoURL: sourceVideoURL,
            outputURL: outputURL,
            backgroundSettings: backgroundSettings,
            aspectRatio: aspectRatio,
            quality: selectedQuality
        ) { result in
            switch result {
            case .success(let outputURL):
                print("✅ CALayer Export completed: \(outputURL.path)")
                // Show in Finder
                NSWorkspace.shared.selectFile(outputURL.path, inFileViewerRootedAtPath: outputURL.deletingLastPathComponent().path)
                showingExportProgress = false
                dismiss()
            case .failure(let error):
                print("❌ CALayer Export failed: \(error.localizedDescription)")
                showingExportProgress = false
                dismiss()
            }
        }
        
        // Show progress
        dismiss()
        showingExportProgress = true
    }
    
    private func getExportURL(fileName: String) -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let exportsFolder = documentsPath.appendingPathComponent("MyScreenStudio/Exports")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: exportsFolder, withIntermediateDirectories: true)
        
        return exportsFolder.appendingPathComponent(fileName)
    }
}

// MARK: - Export Progress View (Dynamic Island Style)
struct ExportProgressView: View {
    @ObservedObject var exportManager: CALayerVideoExporter2
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            // Dynamic Island background
            RoundedRectangle(cornerRadius: 32)
                .fill(.ultraThinMaterial)
                .background(
                    RoundedRectangle(cornerRadius: 32)
                        .fill(.black.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                )
            
            VStack(spacing: 24) {
                // Modern Progress Ring
                VStack(spacing: 16) {
                    ZStack {
                        // Background ring
                        Circle()
                            .stroke(.gray.opacity(0.15), lineWidth: 6)
                            .frame(width: 100, height: 100)
                        
                        // Progress ring
                        Circle()
                            .trim(from: 0, to: CGFloat(exportManager.exportProgress))
                            .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .frame(width: 100, height: 100)
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(duration: 0.5), value: exportManager.exportProgress)
                        
                        // Center content
                        VStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.blue)
                            
                            Text(String(format: "%.0f%%", exportManager.exportProgress * 100))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                    }
                    
                    VStack(spacing: 4) {
                        Text("Exporting Video")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Text("Processing your video with effects...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                
                // Progress Stats - Compact Pills
                if let progressData = exportManager.exportProgressData {
                    HStack(spacing: 12) {
                        StatPill(
                            icon: "film",
                            label: "Frame",
                            value: "\(progressData.currentFrame)/\(progressData.totalFrames)"
                        )
                        
                        StatPill(
                            icon: "clock",
                            label: "Time Left",
                            value: formatTime(progressData.estimatedTimeRemaining)
                        )
                    }
                }
                
                // Cancel Button - Subtle style
                ModernButton("Cancel Export", style: .destructive) {
                    exportManager.cancelExport()
                    dismiss()
                }
            }
            .padding(28)
        }
        .frame(width: 320, height: 360)
        .onReceive(exportManager.$isExporting) { isExporting in
            if !isExporting {
                dismiss()
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
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

// MARK: - Stat Pill Component
struct StatPill: View {
    let icon: String
    let label: String
    let value: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.blue.opacity(0.8))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                Text(value)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.08))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.blue.opacity(0.2), lineWidth: 0.5)
        )
    }
}


// MARK: - Modern Slider Component
struct ModernSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat
    let unit: String
    
    init(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat = 1, unit: String = "px") {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Text("\(Int(value))\(unit)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.gray.opacity(0.1))
                    .cornerRadius(6)
            }
            
            // Modern track with pills for common values
            VStack(spacing: 6) {
                // Custom slider track
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Track background
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.gray.opacity(0.2))
                            .frame(height: 6)
                        
                        // Progress
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.blue)
                            .frame(width: progressWidth(geometry.size.width), height: 6)
                        
                        // Thumb
                        Circle()
                            .fill(.white)
                            .frame(width: 16, height: 16)
                            .shadow(color: .black.opacity(0.2), radius: 2)
                            .offset(x: thumbOffset(geometry.size.width))
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { gesture in
                                let newValue = range.lowerBound + (range.upperBound - range.lowerBound) * (gesture.location.x / geometry.size.width)
                                value = max(range.lowerBound, min(range.upperBound, newValue))
                                value = round(value / step) * step
                            }
                    )
                }
                .frame(height: 20)
                
                // Quick value pills
                HStack(spacing: 8) {
                    ForEach(quickValues, id: \.self) { quickValue in
                        Button("\(Int(quickValue))") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                value = quickValue
                            }
                        }
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(abs(value - quickValue) < 1 ? .blue : .gray.opacity(0.1))
                        .foregroundStyle(abs(value - quickValue) < 1 ? .white : .secondary)
                        .cornerRadius(12)
                        .animation(.easeInOut(duration: 0.15), value: value)
                    }
                    
                    Spacer()
                }
            }
        }
    }
    
    private var quickValues: [CGFloat] {
        if title.lowercased().contains("padding") {
            return [0, 80, 120, 160, 200]
        } else if title.lowercased().contains("corner") {
            return [0, 5, 10, 15, 25]
        } else {
            return []
        }
    }
    
    private func progressWidth(_ totalWidth: CGFloat) -> CGFloat {
        let progress = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return max(0, min(totalWidth, totalWidth * progress))
    }
    
    private func thumbOffset(_ totalWidth: CGFloat) -> CGFloat {
        let progress = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return max(0, min(totalWidth - 16, (totalWidth - 16) * progress))
    }
}

// MARK: - Info Row Helper (Legacy)
struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }
}