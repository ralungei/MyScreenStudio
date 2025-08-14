import SwiftUI
import AVKit
import AVFoundation

struct VideoEditorView: View {
    let project: RecordingProject
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = "background"
    @State private var effectSegments: [String: [EffectSegment]] = [
        "ZOOM": [EffectSegment(startOffset: 100, width: 80), EffectSegment(startOffset: 220, width: 60)]
    ]
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var videoSize: CGSize = .zero
    @State private var timelineZoom: CGFloat = 1.0
    @State private var timelineOffset: CGFloat = 0
    @State private var hoverTime: Double? = nil
    @State private var isScrubbing = false
    @StateObject private var exportManager = CALayerVideoExporter2()
    @State private var showingExportSheet = false
    @State private var showingExportProgress = false
    
    // Shared managers for real-time effects
    @StateObject private var sharedCursorManager = CursorManager()
    @StateObject private var sharedBackgroundManager = BackgroundManager()
    @State private var selectedAspectRatio: AspectRatio = .auto
    
    private var autoAspectRatio: CGFloat {
        let paddedWidth = videoSize.width + sharedBackgroundManager.settings.padding * 2
        let paddedHeight = videoSize.height + sharedBackgroundManager.settings.padding * 2
        return paddedWidth / paddedHeight
    }
    
    enum AspectRatio: String, CaseIterable {
        case auto = "Auto"
        case ratio16_9 = "16:9"
        case ratio4_3 = "4:3" 
        case ratio1_1 = "1:1"
        
        var value: CGFloat {
            switch self {
            case .auto: return 0 // 0 significa auto-ajuste
            case .ratio16_9: return 16.0 / 9.0
            case .ratio4_3: return 4.0 / 3.0
            case .ratio1_1: return 1.0
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Toolbar - Natural height based on content
            HStack {
                // Close button a la izquierda
                Button(action: {
                    NSApplication.shared.keyWindow?.close()
                }) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .background(.gray.opacity(0.1))
                .cornerRadius(14)
                
                Spacer()
                    .frame(width: 20)
                
                // Título en dos filas
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROJECT")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Text(project.name)
                        .font(.headline)
                        .fontWeight(.semibold)
                }
                
                Spacer()
                
                // Export button
                ModernButton("Export", icon: "square.and.arrow.up", style: .primary) {
                    showingExportSheet = true
                }
            }
            .padding()
            .background(Color.gray.opacity(0.02))
            
            Divider()
            
            // Main Content Area
            HStack(spacing: 0) {
                // Left Side - Video Preview and Timeline
                VStack(spacing: 0) {
                    // Aspect Ratio Controls - Independent row
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            // Auto Button
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selectedAspectRatio == .auto ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2))
                                .frame(width: 40, height: 20)
                                .overlay(
                                    Text("Auto")
                                        .font(.caption2)
                                        .foregroundColor(selectedAspectRatio == .auto ? .white : .secondary)
                                        .allowsHitTesting(false)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedAspectRatio = .auto
                                    print("🔄 Aspect ratio changed to: Auto")
                                }
                            
                            // 16:9 Button
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selectedAspectRatio == .ratio16_9 ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2))
                                .frame(width: 40, height: 20)
                                .overlay(
                                    Text("16:9")
                                        .font(.caption2)
                                        .foregroundColor(selectedAspectRatio == .ratio16_9 ? .white : .secondary)
                                        .allowsHitTesting(false)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedAspectRatio = .ratio16_9
                                    print("🔄 Aspect ratio changed to: 16:9")
                                }
                            
                            // 4:3 Button
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selectedAspectRatio == .ratio4_3 ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2))
                                .frame(width: 40, height: 20)
                                .overlay(
                                    Text("4:3")
                                        .font(.caption2)
                                        .foregroundColor(selectedAspectRatio == .ratio4_3 ? .white : .secondary)
                                        .allowsHitTesting(false)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedAspectRatio = .ratio4_3
                                    print("🔄 Aspect ratio changed to: 4:3")
                                }
                            
                            // 1:1 Button
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selectedAspectRatio == .ratio1_1 ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2))
                                .frame(width: 40, height: 20)
                                .overlay(
                                    Text("1:1")
                                        .font(.caption2)
                                        .foregroundColor(selectedAspectRatio == .ratio1_1 ? .white : .secondary)
                                        .allowsHitTesting(false)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedAspectRatio = .ratio1_1
                                    print("🔄 Aspect ratio changed to: 1:1")
                                }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .zIndex(100)
                    
                    // Video Preview - Independent section
                    Group {
                        if selectedAspectRatio == .auto {
                            // Auto mode: Show exact video proportions + padding
                            Rectangle()
                                .fill(Color.clear)
                                .background(
                                    // Show the actual selected background
                                    Group {
                                        if let background = sharedBackgroundManager.settings.selectedBackground,
                                           let backgroundImage = background.nsImage {
                                            Image(nsImage: backgroundImage)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        } else {
                                            Color.black.opacity(0.8)
                                        }
                                    }
                                )
                                .clipped()
                                .aspectRatio(autoAspectRatio, contentMode: .fit)
                        } else {
                            // Fixed aspect ratio modes
                            Rectangle()
                                .fill(Color.clear)
                                .background(
                                    // Show the actual selected background
                                    Group {
                                        if let background = sharedBackgroundManager.settings.selectedBackground,
                                           let backgroundImage = background.nsImage {
                                            Image(nsImage: backgroundImage)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        } else {
                                            Color.black.opacity(0.8)
                                        }
                                    }
                                )
                                .clipped()
                                .aspectRatio(selectedAspectRatio.value, contentMode: .fit)
                        }
                    }
                    .layoutPriority(1)
                        .overlay(
                            // Video layer with custom AVPlayerLayer
                            Group {
                                if let player = player {
                                    CustomVideoView(player: player)
                                        .aspectRatio(videoSize.width / videoSize.height, contentMode: .fit) // Maintain real proportions but fit in container
                                        .clipShape(RoundedRectangle(cornerRadius: sharedBackgroundManager.settings.cornerRadius, style: .continuous))
                                        .compositingGroup() // la máscara se aplica antes de sombrear
                                        .background(
                                            RoundedRectangle(cornerRadius: sharedBackgroundManager.settings.cornerRadius, style: .continuous)
                                                .fill(Color.black.opacity(0.001)) // invisible pero genera sombra
                                                .shadow(color: sharedBackgroundManager.settings.shadowEnabled ? .black.opacity(0.10) : .clear,
                                                        radius: 14, x: 0, y: 2)   // ambient
                                                .shadow(color: sharedBackgroundManager.settings.shadowEnabled ? .black.opacity(0.18) : .clear,
                                                        radius: 32, x: 0, y: 10)  // key
                                        )
                                        .padding(sharedBackgroundManager.settings.padding / 2)
                                } else {
                                    Rectangle()
                                        .fill(Color.white)
                                        .aspectRatio(16.0/9.0, contentMode: .fill)
                                        .cornerRadius(sharedBackgroundManager.settings.cornerRadius)
                                        // Ambient shadow
                                        .shadow(color: .black.opacity(0.10), radius: 24, x: 0, y: 2)
                                        // Key shadow
                                        .shadow(color: .black.opacity(0.18), radius: 48, x: 0, y: 16)
                                        .padding(sharedBackgroundManager.settings.padding)
                                        .overlay(
                                            VStack(spacing: 8) {
                                                ProgressView()
                                                    .scaleEffect(0.8)
                                                Text("LOADING VIDEO...")
                                                    .font(.caption)
                                                    .foregroundColor(.gray)
                                            }
                                        )
                                }
                            }
                        )
                    
                    // Playback Controls - Independent row
                    VStack(spacing: 8) {
                        HStack(spacing: 16) {
                            Button(action: {
                                seekBy(-10)
                            }) {
                                Circle()
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Image(systemName: "gobackward.10")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                    )
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: {
                                togglePlayPause()
                            }) {
                                Circle()
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 40, height: 40)
                                    .overlay(
                                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                            .foregroundColor(.primary)
                                            .font(.caption)
                                    )
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: {
                                seekBy(10)
                            }) {
                                Circle()
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Image(systemName: "goforward.10")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        
                        HStack(spacing: 8) {
                            Text(formatTime(hoverTime ?? currentTime))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(hoverTime != nil ? .blue : .primary) // Blue when scrubbing
                            
                            Text("/")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            Text(formatTime(duration))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.vertical)
                    .background(Color(NSColor.windowBackgroundColor))
                    
                    Divider()
                    
                    // Timeline Section - Fixed height with scroll
                    VStack(spacing: 0) {
                        // Timeline Header
                        HStack {
                            Text("TIMELINE")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.green.opacity(0.2))
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Text("+")
                                            .font(.caption2)
                                            .foregroundColor(.green)
                                    )
                                
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.red.opacity(0.2))
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        Text("✂")
                                            .font(.caption2)
                                            .foregroundColor(.red)
                                    )
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.05))
                        
                        // Professional Timeline
                        ProfessionalTimelineView(
                            currentTime: $currentTime,
                            duration: duration,
                            zoom: $timelineZoom,
                            offset: $timelineOffset,
                            onSeek: { time in
                                player?.seek(to: CMTime(seconds: time, preferredTimescale: 1))
                            },
                            onHover: { time in
                                hoverTime = time
                                if let time = time {
                                    // Live scrubbing - seek video while hovering
                                    player?.seek(to: CMTime(seconds: time, preferredTimescale: 1))
                                    isScrubbing = true
                                } else {
                                    isScrubbing = false
                                }
                            }
                        )
                    }
                    .background(Color.gray.opacity(0.02))
                }
                .layoutPriority(1)
                
                Divider()
                
                // Right Sidebar - Compact Tabs
                VStack(spacing: 0) {
                    // Tab Bar with icons
                    Picker("Settings", selection: $selectedTab) {
                        Label("BG", systemImage: "photo").tag("background")
                        Label("Cursor", systemImage: "cursorarrow").tag("cursor")
                        Label("Audio", systemImage: "speaker.wave.2").tag("audio")
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    
                    Divider()
                    
                    // Tab Content
                    ScrollView {
                        switch selectedTab {
                        case "background":
                            BackgroundConfigTab(backgroundManager: sharedBackgroundManager)
                        case "cursor":
                            CursorConfigTab(cursorManager: sharedCursorManager)
                        case "audio":
                            AudioConfigTab()
                        default:
                            BackgroundConfigTab(backgroundManager: sharedBackgroundManager)
                        }
                    }
                }
                .frame(minWidth: 400)
                .background(Color.gray.opacity(0.05))
            }
        }
        .navigationTitle("Video Editor - \(project.name)")
        .background(Color(NSColor.windowBackgroundColor))
        .edgesIgnoringSafeArea(.top)
        .onAppear {
            // Maximizar la ventana al abrir
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApplication.shared.keyWindow?.zoom(nil)
            }
            
            // Always enable background and cursor for VideoEditorView
            sharedBackgroundManager.isEnabled = true
            sharedCursorManager.isEnabled = true
            
            // Select first background by default if none selected
            if sharedBackgroundManager.settings.selectedBackground == nil,
               let firstBackground = sharedBackgroundManager.availableBackgrounds.first {
                sharedBackgroundManager.selectBackground(firstBackground)
            }
            
            // Setup video player
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportConfigurationView(
                project: project,
                backgroundSettings: sharedBackgroundManager.settings,
                videoSize: videoSize,
                aspectRatio: selectedAspectRatio.value,
                exportManager: exportManager,
                showingExportProgress: $showingExportProgress
            )
        }
        .sheet(isPresented: $showingExportProgress) {
            ExportProgressView(exportManager: exportManager)
        }
    }
    
    // MARK: - Helper Methods
    
    private func setupPlayer() {
        let videoURL = URL(fileURLWithPath: project.videoPath)
        guard FileManager.default.fileExists(atPath: project.videoPath) else {
            print("❌ Video file not found at path: \(project.videoPath)")
            return
        }
        
        player = AVPlayer(url: videoURL)
        print("✅ Video player initialized for: \(videoURL.lastPathComponent)")
        
        // Get duration and analyze video dimensions
        Task {
            do {
                let asset = AVAsset(url: videoURL)
                let loadedDuration = try await asset.load(.duration)
                
                // Get video track to check dimensions
                let videoTracks = try await asset.load(.tracks).filter { $0.mediaType == .video }
                if let videoTrack = videoTracks.first {
                    let naturalSize = try await videoTrack.load(.naturalSize)
                    let preferredTransform = try await videoTrack.load(.preferredTransform)
                    
                    print("🎥 VIDEO ANALYSIS:")
                    print("📐 Natural size: \(naturalSize.width) x \(naturalSize.height)")
                    print("🔄 Transform: \(preferredTransform)")
                    
                    // Calculate actual display size after transform
                    let transformedSize = naturalSize.applying(preferredTransform)
                    let finalSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
                    print("📱 Transformed size: \(finalSize.width) x \(finalSize.height)")
                    
                    await MainActor.run {
                        self.videoSize = finalSize
                    }
                }
                
                await MainActor.run {
                    self.duration = loadedDuration.seconds
                }
            } catch {
                print("Failed to load duration: \(error)")
            }
        }
        
        // Observe playback time
        player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 1000), queue: .main) { time in
            currentTime = time.seconds
            
            // Check if ended
            if let duration = player?.currentItem?.duration.seconds,
               time.seconds >= duration {
                isPlaying = false
            }
        }
    }
    
    private func togglePlayPause() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
    
    private func seekBy(_ seconds: Double) {
        let currentTime = player?.currentTime().seconds ?? 0
        let targetTime = max(0, min(duration, currentTime + seconds))
        player?.seek(to: CMTime(seconds: targetTime, preferredTimescale: 1))
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1.0)) * 1000)
        return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
    }
    
}

// MARK: - Custom Video View

struct CustomVideoView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> CustomVideoNSView {
        return CustomVideoNSView(player: player)
    }
    
    func updateNSView(_ nsView: CustomVideoNSView, context: Context) {
        // Updates are handled automatically
    }
}

class CustomVideoNSView: NSView {
    private var playerLayer: AVPlayerLayer?
    
    init(player: AVPlayer) {
        super.init(frame: .zero)
        setupPlayerLayer(with: player)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupPlayerLayer(with player: AVPlayer) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        
        playerLayer = AVPlayerLayer(player: player)
        playerLayer?.videoGravity = .resizeAspect // Maintains aspect ratio
        playerLayer?.frame = bounds
        
        if let playerLayer = playerLayer {
            layer?.addSublayer(playerLayer)
        }
    }
    
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - Tab Views

struct BackgroundConfigTab: View {
    @ObservedObject var backgroundManager: BackgroundManager
    @State private var selectedCategory: VideoBackground.BackgroundCategory = .gradients
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Background Settings")
                .font(.headline)
                .padding(.horizontal)
            
            // Background Selection Section
            VStack(alignment: .leading, spacing: 12) {
                    Text("Select Background")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    // Category selector
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(VideoBackground.BackgroundCategory.allCases, id: \.self) { category in
                            Text(category.displayName).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    
                    // Background grid
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 70))
                        ], spacing: 16) {
                            ForEach(filteredBackgrounds) { background in
                                BackgroundPreviewView(
                                    background: background,
                                    isSelected: backgroundManager.settings.selectedBackground?.id == background.id,
                                    onSelect: {
                                        backgroundManager.selectBackground(background)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(maxHeight: 140)
                    
                }
                
                Divider()
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                
                // Appearance Settings Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Appearance")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        ModernSlider("Padding", value: $backgroundManager.settings.padding, range: 0...200, step: 10)
                        
                        ModernSlider("Corners", value: $backgroundManager.settings.cornerRadius, range: 0...50, step: 5)
                        
                        Toggle("Drop Shadow", isOn: $backgroundManager.settings.shadowEnabled)
                            .font(.caption)
                    }
                    .padding(.horizontal)
                }
            
            Spacer()
        }
        .padding(.top)
    }
    
    private var filteredBackgrounds: [VideoBackground] {
        if selectedCategory == .none {
            return backgroundManager.availableBackgrounds.filter { $0.category == .none }
        }
        return backgroundManager.availableBackgrounds.filter { $0.category == selectedCategory }
    }
}

struct CursorConfigTab: View {
    @ObservedObject var cursorManager: CursorManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cursor Settings")
                .font(.headline)
                .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 12) {
                    Text("Select Cursor")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 50))
                        ], spacing: 16) {
                            ForEach(cursorManager.availableCursors) { cursor in
                                CursorPreviewView(
                                    cursor: cursor,
                                    isSelected: cursorManager.selectedCursor?.id == cursor.id,
                                    onSelect: {
                                        cursorManager.selectCursor(cursor)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(maxHeight: 160)
                    
                }
            
            Spacer()
        }
        .padding(.top)
    }
}

struct AudioConfigTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Settings")
                .font(.headline)
                .padding(.horizontal)
            
            VStack(spacing: 12) {
                // Record audio toggle
                HStack {
                    Text("Record Audio")
                        .font(.caption)
                    Spacer()
                    Toggle("", isOn: .constant(true))
                }
                .padding(.horizontal)
                
                // Audio source
                VStack(alignment: .leading, spacing: 8) {
                    Text("Audio Source")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(spacing: 8) {
                        ForEach(["System Audio", "Microphone", "Both"], id: \.self) { source in
                            HStack {
                                Circle()
                                    .fill(source == "Both" ? Color.blue : Color.gray.opacity(0.3))
                                    .frame(width: 12, height: 12)
                                Text(source)
                                    .font(.caption)
                                Spacer()
                            }
                        }
                    }
                }
                .padding(.horizontal)
                
                // Volume levels
                VStack(alignment: .leading, spacing: 8) {
                    Text("Volume Levels")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(spacing: 8) {
                        HStack {
                            Text("System")
                                .font(.caption2)
                                .frame(width: 60, alignment: .leading)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.green)
                                .frame(height: 6)
                            Text("85%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("Mic")
                                .font(.caption2)
                                .frame(width: 60, alignment: .leading)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.orange)
                                .frame(height: 6)
                            Text("65%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            Spacer()
        }
        .padding(.top)
    }
}

// MARK: - Editable Timeline Components

struct EffectSegment: Identifiable {
    let id = UUID()
    var startOffset: CGFloat
    var width: CGFloat
    
    init(startOffset: CGFloat, width: CGFloat) {
        self.startOffset = startOffset
        self.width = width
    }
}

struct EditableTrack: View {
    let trackName: String
    let trackColor: Color
    @Binding var segments: [EffectSegment]
    @State private var hoveredPosition: CGFloat?
    @State private var draggedSegment: EffectSegment?
    @State private var dragOffset: CGFloat = 0
    @State private var resizeSegment: EffectSegment?
    @State private var resizeEdge: ResizeEdge = .trailing
    
    enum ResizeEdge {
        case leading, trailing
    }
    
    private let trackHeight: CGFloat = 36
    private let minSegmentWidth: CGFloat = 20
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: trackHeight)
                    .onTapGesture { location in
                        addSegmentAt(location.x, trackWidth: geometry.size.width)
                    }
                    .onHover { hovering in
                        if hovering {
                            NSCursor.crosshair.set()
                        } else {
                            NSCursor.arrow.set()
                            hoveredPosition = nil
                        }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .local)
                            .onChanged { value in
                                hoveredPosition = value.location.x
                            }
                    )
                
                // Hover indicator
                if let hoveredPos = hoveredPosition,
                   !segments.contains(where: { isPointInSegment(hoveredPos, segment: $0) }) {
                    Rectangle()
                        .fill(trackColor.opacity(0.3))
                        .frame(width: 2, height: trackHeight)
                        .offset(x: hoveredPos - 1)
                        .animation(.easeInOut(duration: 0.1), value: hoveredPosition)
                }
                
                // Effect segments
                ForEach(segments) { segment in
                    segmentView(segment: segment, geometry: geometry)
                }
            }
        }
        .frame(height: trackHeight)
        .contextMenu {
            Button("Clear All") {
                segments.removeAll()
            }
        }
    }
    
    @ViewBuilder
    private func segmentView(segment: EffectSegment, geometry: GeometryProxy) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(trackColor.opacity(0.6))
            .frame(width: segment.width, height: trackHeight - 6)
            .offset(x: segment.startOffset, y: 3)
            .overlay(
                // Resize handles
                HStack {
                    // Left handle
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 4, height: trackHeight - 6)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .onHover { hovering in
                            if hovering {
                                NSCursor.resizeLeftRight.set()
                            }
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    resizeSegment(segment, edge: .leading, delta: value.translation.width)
                                }
                        )
                    
                    Spacer()
                    
                    // Right handle
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 4, height: trackHeight - 6)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .onHover { hovering in
                            if hovering {
                                NSCursor.resizeLeftRight.set()
                            }
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    resizeSegment(segment, edge: .trailing, delta: value.translation.width)
                                }
                        )
                }
                .offset(x: segment.startOffset, y: 3)
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.openHand.set()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        moveSegment(segment, delta: value.translation.width, trackWidth: geometry.size.width)
                    }
            )
            .contextMenu {
                Button("Delete", role: .destructive) {
                    deleteSegment(segment)
                }
            }
    }
    
    private func addSegmentAt(_ position: CGFloat, trackWidth: CGFloat) {
        let newSegment = EffectSegment(startOffset: max(0, position - 25), width: 50)
        
        // Ensure the segment fits within track bounds
        let maxOffset = trackWidth - newSegment.width
        let clampedSegment = EffectSegment(
            startOffset: min(newSegment.startOffset, maxOffset),
            width: newSegment.width
        )
        
        segments.append(clampedSegment)
    }
    
    private func moveSegment(_ segment: EffectSegment, delta: CGFloat, trackWidth: CGFloat) {
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        
        let newOffset = segment.startOffset + delta
        let maxOffset = trackWidth - segment.width
        let clampedOffset = max(0, min(newOffset, maxOffset))
        
        segments[index].startOffset = clampedOffset
    }
    
    private func resizeSegment(_ segment: EffectSegment, edge: ResizeEdge, delta: CGFloat) {
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        
        switch edge {
        case .leading:
            let newStartOffset = segment.startOffset + delta
            let newWidth = segment.width - delta
            
            if newWidth >= minSegmentWidth && newStartOffset >= 0 {
                segments[index].startOffset = newStartOffset
                segments[index].width = newWidth
            }
        case .trailing:
            let newWidth = max(minSegmentWidth, segment.width + delta)
            segments[index].width = newWidth
        }
    }
    
    private func deleteSegment(_ segment: EffectSegment) {
        segments.removeAll { $0.id == segment.id }
    }
    
    private func isPointInSegment(_ point: CGFloat, segment: EffectSegment) -> Bool {
        return point >= segment.startOffset && point <= segment.startOffset + segment.width
    }
}

