import SwiftUI
import AVKit
import AVFoundation
import AppKit

struct VideoEditorView: View {
    let project: RecordingProject
    var projectManager: ProjectManager
    @Environment(\.dismiss) private var dismiss

    // Player state
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var sourceDuration: Double = 0  // original video file duration (never changes)
    @State private var videoSize: CGSize = .zero
    @State private var hoverTime: Double? = nil
    @State private var isManualSeeking = false
    @State private var isHovering = false

    // Effects state
    @State private var zoomSegments: [ZoomSegment] = []
    @State private var sortedZoomSegments: [ZoomSegment] = []  // cached sorted copy, invalidated on change
    @State private var typingSegments: [TypingSegment] = []
    @State private var videoClips: [VideoClip] = []
    @State private var currentZoomLevel: CGFloat = 1.0
    @State private var selectedAspectRatio: AspectRatio = .auto
    @State private var cropRect: CropRect = .full
    @State private var mouseMetadata: CursorMetadata?

    // Composition-based preview: maps source time ↔ composition time
    @State private var clipTimeMap: [ClipTimeEntry] = []
    @State private var compositionMetadata: CursorMetadata?  // mouse metadata remapped to composition time

    // Cursor tracking (unified — shared between zoom anchor + cursor overlay)
    @State private var zoomAnchor: UnitPoint = .center
    @State private var cursorScreenPos: CGPoint? = nil
    @State private var smoothedCurX: CGFloat = 0.5
    @State private var smoothedCurY: CGFloat = 0.5
    @State private var cursorNeedsSnap = true  // true → next position skips smoothing
    @State private var cursorClickScale: CGFloat = 1.0
    @State private var activeClickEffects: [PreviewClickEffect] = []
    @State private var capturedClickPositions: [Double: CGPoint] = [:]  // click timestamp → smoothed cursor pos
    @State private var lastPlayedClickTime: Double = -1  // avoid replaying same click

    // Audio state
    @State private var recordAudio = true
    @State private var audioSource = "both"
    @State private var systemVolume: CGFloat = 0.85
    @State private var micVolume: CGFloat = 0.65

    // Managers
    @State private var sharedCursorManager = CursorManager()
    @State private var sharedBackgroundManager = BackgroundManager()
    @State private var clickSoundPlayer = ClickSoundPlayer()
    @State private var zoomSoundPlayer = ZoomSoundPlayer()
    @State private var exportManager = CALayerVideoExporter2()

    // UI state
    @State private var selectedTab = 0
    @State private var showingExportSheet = false
    @State private var showingExportProgress = false
    @State private var showingCropEditor = false
    @State private var inspectorCollapsed = false
    @State private var keyMonitor: Any? = nil
    @State private var selectedZoomSegment: ZoomSegment? = nil
    @State private var zoomThumbnail: NSImage? = nil
    @State private var autoSaveTask: Task<Void, Never>? = nil
    @State private var videoLoadTask: Task<Void, Never>? = nil
    @State private var timeObserverToken: Any? = nil
    @State private var timeObserverPlayer: AVPlayer? = nil

    private let inspectorWidth: CGFloat = 280

    // MARK: - Computed

    private var effectiveVideoSize: CGSize {
        cropRect.isFull ? videoSize : cropRect.croppedSize(for: videoSize)
    }

    private var bgSettings: BackgroundSettings {
        sharedBackgroundManager.settings
    }

    private var previewRatio: CGFloat {
        if selectedAspectRatio != .auto { return selectedAspectRatio.value }
        let vs = effectiveVideoSize
        let pw = vs.width + bgSettings.padding * 2
        let ph = vs.height + bgSettings.padding * 2
        guard ph > 0, pw > 0 else { return 16.0 / 9.0 }
        return pw / ph
    }

    // MARK: - Body

    var body: some View {
        editorContent
            .ignoresSafeArea()
            .onAppear(perform: onAppear)
            .onDisappear(perform: onDisappear)
            .onChange(of: zoomSegments) { _, newSegments in
                sortedZoomSegments = newSegments.sorted { $0.start < $1.start }
                if !isPlaying {
                    let t = player?.currentTime().seconds ?? currentTime
                    let target = checkActiveZoomSegment(at: t) ?? 1.0
                    withAnimation(.easeInOut(duration: 0.2)) { currentZoomLevel = target }
                    // Update anchor for manual segments while paused
                    if let seg = newSegments.first(where: { t >= $0.start && t <= $0.start + $0.duration && $0.mode == .manual }) {
                        zoomAnchor = UnitPoint(x: seg.focus.x, y: seg.focus.y)
                    }
                }
            }
            .onChange(of: selectedZoomSegment) { _, seg in
                if seg?.mode == .manual { generateZoomThumbnail() }
            }
            .onChange(of: videoClips) { _, _ in
                rebuildComposition()
            }
            .sheet(isPresented: $showingCropEditor) {
            CropEditorView(
                videoURL: URL(fileURLWithPath: project.videoPath),
                videoSize: videoSize,
                cropRect: $cropRect
            )
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportConfigurationView(
                project: project,
                backgroundSettings: bgSettings,
                videoSize: videoSize,
                aspectRatio: selectedAspectRatio.value,
                exportManager: exportManager,
                showingExportProgress: $showingExportProgress,
                cursorManager: sharedCursorManager,
                mouseMetadata: mouseMetadata,
                zoomSegments: zoomSegments,
                videoClips: videoClips,
                typingSegments: typingSegments,
                cropRect: cropRect
            )
        }
        .sheet(isPresented: $showingExportProgress) {
            ExportProgressView(exportManager: exportManager)
        }
        .onChange(of: selectedZoomSegment) { _, seg in
            if seg != nil {
                selectedTab = 3
            } else if selectedTab == 3 {
                selectedTab = 0
            }
        }
        // Debounced auto-save on key state changes
        .onChange(of: duration) { _, newDur in
            // Auto-detect typing segments once duration is known
            if newDur > 0, typingSegments.isEmpty,
               let keys = mouseMetadata?.keyTimestamps, !keys.isEmpty {
                typingSegments = TypingSegment.deriveSegments(
                    from: keys,
                    totalDuration: newDur
                )
            }
        }
        .modifier(AutoSaveOnChange(
            zoomSegments: zoomSegments,
            typingSegments: typingSegments,
            videoClips: videoClips,
            cropRect: cropRect,
            selectedAspectRatio: selectedAspectRatio,
            selectedTab: selectedTab,
            inspectorCollapsed: inspectorCollapsed,
            bgSettings: sharedBackgroundManager.settings,
            cursorScale: sharedCursorManager.cursorScale,
            cursorSmoothing: sharedCursorManager.smoothing,
            cursorEnabled: sharedCursorManager.isEnabled,
            cursorOpacity: sharedCursorManager.cursorOpacity,
            cursorShadow: sharedCursorManager.cursorShadow,
            showClickEffects: sharedCursorManager.showClickEffects,
            clickEffectSize: sharedCursorManager.clickEffectSize,
            recordAudio: recordAudio,
            audioSource: audioSource,
            systemVolume: systemVolume,
            micVolume: micVolume,
            clickSoundEnabled: clickSoundPlayer.isEnabled,
            clickSoundStyle: clickSoundPlayer.style.rawValue,
            clickSoundVolume: clickSoundPlayer.volume,
            zoomSoundEnabled: zoomSoundPlayer.isEnabled,
            zoomSoundVolume: zoomSoundPlayer.volume,
            onSave: scheduleSave
        ))
    }

    // MARK: - Editor Content (extracted to help the type-checker)

    private var editorContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    aspectRatioBar
                    previewArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
                .layoutPriority(1)
                if !inspectorCollapsed {
                    Divider()
                    inspector
                        .frame(width: inspectorWidth)
                }
            }
            Divider()
            VStack(spacing: 0) {
                transportBar
                Divider()
                timeline
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        EditorHeaderView(
            projectName: project.name,
            inspectorCollapsed: $inspectorCollapsed,
            onCrop: { showingCropEditor = true },
            onExport: { showingExportSheet = true }
        )
    }

    // MARK: - Aspect Ratio Bar

    private var aspectRatioBar: some View {
        HStack {
            GlassEffectContainer {
                HStack(spacing: 0) {
                    ForEach(AspectRatio.allCases, id: \.self) { ratio in
                        Button {
                            selectedAspectRatio = ratio
                        } label: {
                            Text(ratio.rawValue)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            selectedAspectRatio == ratio
                                ? .regular.tint(.accentColor)
                                : .regular,
                            in: .capsule
                        )
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Preview Area

    private var previewArea: some View {
        GeometryReader { geo in
            let container = geo.size
            let fitted = aspectFit(ratio: previewRatio, in: container)

            // Video keeps its proportional size — padding is the leftover space
            let vs = effectiveVideoSize
            let totalW = vs.width + bgSettings.padding * 2
            let totalH = vs.height + bgSettings.padding * 2
            let scale = min(fitted.width / max(1, totalW), fitted.height / max(1, totalH))
            let vidFrame = CGSize(
                width: max(1, vs.width * scale),
                height: max(1, vs.height * scale)
            )

            ZStack {
                // Composition (background + video + cursor) — clipped to fitted frame
                ZStack {
                    // Background fill
                    Group {
                        if let bg = bgSettings.selectedBackground, let img = bg.nsImage {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color.black.opacity(0.85)
                        }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .clipped()

                    // Video + cursor
                    if let player = player, videoSize.width > 0 {
                        CustomVideoView(player: player, cropRect: cropRect)
                            .frame(width: vidFrame.width, height: vidFrame.height)
                            .clipShape(RoundedRectangle(cornerRadius: bgSettings.cornerRadius, style: .continuous))
                            .compositingGroup()
                            .shadow(
                                color: bgSettings.shadowEnabled ? .black.opacity(bgSettings.shadowOpacity) : .clear,
                                radius: bgSettings.shadowBlur / 2,
                                x: bgSettings.shadowOffset.width,
                                y: bgSettings.shadowOffset.height
                            )

                        // Cursor (can extend beyond video onto background)
                        ZStack {
                            if let cursorPos = cursorScreenPos,
                               sharedCursorManager.isEnabled,
                               let selected = sharedCursorManager.selectedCursor,
                               !selected.imagePath.isEmpty,
                               let cursorImg = selected.nsImage {
                                let baseH = vidFrame.width / 40
                                let userScale = sharedCursorManager.cursorScale
                                let cursorH = baseH * userScale
                                let imgScale = cursorH / cursorImg.size.height
                                let cursorW = cursorImg.size.width * imgScale
                                let hotAnchorX = (selected.hotSpot.x * imgScale) / max(cursorW, 1)
                                let hotAnchorY = (selected.hotSpot.y * imgScale) / max(cursorH, 1)

                                Image(nsImage: cursorImg)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: cursorW, height: cursorH)
                                    .scaleEffect(cursorClickScale, anchor: UnitPoint(x: hotAnchorX, y: hotAnchorY))
                                    .opacity(sharedCursorManager.cursorOpacity)
                                    .shadow(
                                        color: sharedCursorManager.cursorShadow ? .black.opacity(0.3) : .clear,
                                        radius: 2, x: 0, y: 1
                                    )
                                    .offset(
                                        x: (cursorPos.x - 0.5) * vidFrame.width + cursorW / 2 - selected.hotSpot.x * imgScale,
                                        y: (cursorPos.y - 0.5) * vidFrame.height + cursorH / 2 - selected.hotSpot.y * imgScale
                                    )
                            }
                        }
                        .frame(width: vidFrame.width, height: vidFrame.height)
                        .allowsHitTesting(false)

                        // Click effects — same ZStack as cursor for identical coordinates
                        if sharedCursorManager.showClickEffects, !activeClickEffects.isEmpty {
                            ClickEffectOverlay(
                                effects: activeClickEffects,
                                style: sharedCursorManager.clickEffectStyle,
                                color: sharedCursorManager.clickEffectColor,
                                sizeMult: sharedCursorManager.clickEffectSize,
                                vidFrame: vidFrame
                            )
                            .frame(width: vidFrame.width, height: vidFrame.height)
                            .allowsHitTesting(false)
                        }

                    } else {
                        RoundedRectangle(cornerRadius: bgSettings.cornerRadius)
                            .fill(.white)
                            .frame(width: vidFrame.width, height: vidFrame.height)
                            .shadow(color: .black.opacity(0.1), radius: 20, x: 0, y: 8)
                            .overlay {
                                VStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Loading...").font(.caption2).foregroundColor(.gray)
                                }
                            }
                    }
                }
                .scaleEffect(currentZoomLevel, anchor: zoomAnchor)
                .frame(width: fitted.width, height: fitted.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            }
            .position(x: container.width / 2, y: container.height / 2)
        }
        .padding(12)
    }

    // MARK: - Transport Bar

    private var transportBar: some View {
        HStack(spacing: 0) {
            Spacer()

            // Center: time + controls + time
            HStack(spacing: 22) {
                // Current time (next to back button)
                Text(TimeFormatting.precise(hoverTime ?? currentTime))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(hoverTime != nil ? .accentColor : .primary)
                    .frame(width: 70, alignment: .trailing)

                transportButton("gobackward.10") { seekBy(-10) }

                Button { togglePlayPause() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .circle)

                transportButton("goforward.10") { seekBy(10) }

                // Total duration (next to forward button)
                Text(TimeFormatting.precise(duration))
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .leading)
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func transportButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
    }

    // MARK: - Timeline

    private var timeline: some View {
        ModernTimelineView(
            currentTime: $currentTime,
            zoomSegments: $zoomSegments,
            videoClips: $videoClips,
            selectedZoomSegment: $selectedZoomSegment,
            duration: duration,
            sourceDuration: sourceDuration,
            player: player,
            clickTimes: extractClickTimes(),
            typingSegments: $typingSegments,
            onSeek: { time in
                isManualSeeking = true
                cursorNeedsSnap = true  // Skip smoothing on seek
                capturedClickPositions.removeAll()
                lastPlayedClickTime = time  // Reset click sound tracking
                currentTime = time
                let cmTime = CMTime(seconds: time, preferredTimescale: 600)
                player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    DispatchQueue.main.async { isManualSeeking = false }
                }
            },
            onHover: { time in
                guard !isPlaying else { return }
                hoverTime = time
                cursorNeedsSnap = true  // Skip smoothing on hover seek
                if let t = time {
                    isHovering = true
                    player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                } else {
                    isHovering = false
                    player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        )
        .background(Color.gray.opacity(0.02))
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            // Tab bar — GlassEffectContainer so tabs blend together
            GlassEffectContainer {
                HStack(spacing: 0) {
                    inspectorTabButton(0, icon: "photo", label: "BG")
                    inspectorTabButton(1, icon: "cursorarrow", label: "Cursor")
                    inspectorTabButton(2, icon: "speaker.wave.2", label: "Audio")
                    if selectedZoomSegment != nil {
                        inspectorTabButton(3, icon: "arrow.up.left.and.arrow.down.right", label: "Zoom")
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            // Tab content
            ScrollView {
                Group {
                    switch selectedTab {
                    case 0: BackgroundConfigTab(backgroundManager: sharedBackgroundManager)
                    case 1: CursorConfigTab(cursorManager: sharedCursorManager)
                    case 2: AudioConfigTab(
                        recordAudio: $recordAudio,
                        audioSource: $audioSource,
                        systemVolume: $systemVolume,
                        micVolume: $micVolume,
                        clickSoundPlayer: clickSoundPlayer,
                        zoomSoundPlayer: zoomSoundPlayer
                    )
                    case 3: zoomEditorTab
                    default: EmptyView()
                    }
                }
                .padding(12)
            }
        }
        .background(Color.gray.opacity(0.03))
    }

    // MARK: - Inspector Tab Button

    private func inspectorTabButton(_ tag: Int, icon: String, label: String) -> some View {
        Button {
            selectedTab = tag
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(selectedTab == tag ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            selectedTab == tag
                ? .regular.tint(.accentColor).interactive()
                : .regular.interactive(),
            in: .capsule
        )
    }

    // MARK: - Zoom Editor Tab

    private var zoomEditorTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Zoom Segment")
                    .font(.headline)
                Spacer()
                Button {
                    if let seg = selectedZoomSegment {
                        zoomSegments.removeAll { $0.id == seg.id }
                        selectedZoomSegment = nil
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }

            if let seg = selectedZoomSegment,
               let idx = zoomSegments.firstIndex(where: { $0.id == seg.id }) {
                VStack(alignment: .leading, spacing: 12) {
                    // Scale
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Scale")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.1fx", zoomSegments[idx].peakScale))
                                .font(.system(.caption, design: .monospaced))
                        }
                        Slider(value: $zoomSegments[idx].peakScale, in: 1.2...5.0)
                    }

                    Divider()

                    // Mode
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mode")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $zoomSegments[idx].mode) {
                            Label("Auto", systemImage: "cursorarrow.motionlines")
                                .tag(ZoomMode.auto)
                            Label("Manual", systemImage: "mappin.and.ellipse")
                                .tag(ZoomMode.manual)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: zoomSegments[idx].mode) { _, newMode in
                            selectedZoomSegment = zoomSegments[idx]
                            if newMode == .manual { generateZoomThumbnail() }
                        }

                        if zoomSegments[idx].mode == .manual {
                            ZoomFocusEditor(
                                focus: $zoomSegments[idx].focus,
                                videoAspect: effectiveVideoSize,
                                thumbnail: zoomThumbnail,
                                zoomScale: zoomSegments[idx].peakScale
                            )
                            .onChange(of: zoomSegments[idx].focus) { _, newFocus in
                                selectedZoomSegment = zoomSegments[idx]
                                // Live-update preview anchor while dragging
                                if currentZoomLevel > 1.01 {
                                    zoomAnchor = UnitPoint(x: newFocus.x, y: newFocus.y)
                                }
                            }
                        }
                    }

                    Divider()

                    // Timing info
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Timing")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("Start")
                                .font(.caption2)
                                .frame(width: 40, alignment: .leading)
                            Text(TimeFormatting.precise(seg.start))
                                .font(.system(.caption2, design: .monospaced))
                            Spacer()
                        }
                        HStack {
                            Text("Duration")
                                .font(.caption2)
                                .frame(width: 40, alignment: .leading)
                            Text(TimeFormatting.precise(seg.duration))
                                .font(.system(.caption2, design: .monospaced))
                            Spacer()
                        }
                    }

                    Divider()

                    // Quick scale presets
                    Text("Presets")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 6) {
                        ForEach([1.5, 2.0, 3.0, 4.0], id: \.self) { scale in
                            let isActive = abs(zoomSegments[idx].peakScale - CGFloat(scale)) < 0.05
                            Button {
                                zoomSegments[idx].peakScale = CGFloat(scale)
                                selectedZoomSegment = zoomSegments[idx]
                            } label: {
                                Text(String(format: "%.1fx", scale))
                                    .font(.caption2)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(isActive ? Color.green.opacity(0.2) : Color.gray.opacity(0.1))
                                    .foregroundColor(isActive ? .green : .secondary)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text("No zoom segment selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func aspectFit(ratio: CGFloat, in container: CGSize) -> CGSize {
        guard ratio > 0, container.width > 0, container.height > 0 else {
            return CGSize(width: 320, height: 180)
        }
        if container.width / container.height > ratio {
            return CGSize(width: container.height * ratio, height: container.height)
        } else {
            return CGSize(width: container.width, height: container.width / ratio)
        }
    }

    private func extractClickTimes() -> [Double] {
        // Use composition-remapped metadata so click markers align with the reordered timeline
        guard let meta = compositionMetadata ?? mouseMetadata else { return [] }
        return meta.events.compactMap { e in
            switch e.type {
            case .leftClick, .rightClick: return e.timestamp
            default: return nil
            }
        }
    }

    private func togglePlayPause() {
        if isPlaying {
            player?.pause()
        } else {
            // Clear stale seek/hover locks so the time observer can update
            isManualSeeking = false
            isHovering = false
            hoverTime = nil
            player?.play()
        }
        isPlaying.toggle()
    }

    private func seekBy(_ seconds: Double) {
        cursorNeedsSnap = true
        capturedClickPositions.removeAll()
        lastPlayedClickTime = max(0, (player?.currentTime().seconds ?? 0) + seconds)
        let t = player?.currentTime().seconds ?? 0
        let target = max(0, min(duration, t + seconds))
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Max gap (seconds) between two segments to treat them as consecutive.
    private static let bridgeThreshold: Double = 0.3
    private static let easeZone: CGFloat = 0.25

    /// Smootherstep — steeper ease with zero velocity AND acceleration at endpoints.
    /// Creates a more dramatic, professional "breathing" feel.
    private static func smoothstep(_ t: CGFloat) -> CGFloat {
        t * t * t * (t * (6.0 * t - 15.0) + 10.0)
    }

    /// Binary search: returns the index of the first event with timestamp >= t.
    /// If all events are before t, returns events.count.
    private func eventInsertionIndex(for t: Double, in events: [MouseEvent]) -> Int {
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].timestamp < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func checkActiveZoomSegment(at time: Double) -> CGFloat? {
        let sorted = sortedZoomSegments

        // 1. Inside a segment — crossfade scale with neighbors
        for (i, segment) in sorted.enumerated() {
            let segEnd = segment.start + segment.duration
            guard time >= segment.start, time <= segEnd else { continue }

            let prevSeg: ZoomSegment? = (i > 0 && (segment.start - (sorted[i - 1].start + sorted[i - 1].duration)) < Self.bridgeThreshold) ? sorted[i - 1] : nil
            let nextSeg: ZoomSegment? = (i < sorted.count - 1 && (sorted[i + 1].start - segEnd) < Self.bridgeThreshold) ? sorted[i + 1] : nil

            let progress = CGFloat((time - segment.start) / segment.duration)

            if progress < Self.easeZone && prevSeg == nil {
                // Standard ease-in from 1.0 (no predecessor)
                let t = Self.smoothstep(progress / Self.easeZone)
                return 1.0 + (segment.peakScale - 1.0) * t
            } else if progress < Self.easeZone, let prev = prevSeg {
                // Crossfade from previous peak to this peak
                let t = Self.smoothstep(progress / Self.easeZone)
                return prev.peakScale + (segment.peakScale - prev.peakScale) * t
            } else if progress > (1.0 - Self.easeZone) && nextSeg == nil {
                // Standard ease-out to 1.0 (no successor)
                let t = Self.smoothstep((progress - (1.0 - Self.easeZone)) / Self.easeZone)
                return segment.peakScale + (1.0 - segment.peakScale) * t
            } else {
                // Hold peak (middle, or has next neighbor so no ease-out)
                return segment.peakScale
            }
        }

        // 2. In a gap between consecutive segments — interpolate scale
        for i in 0..<max(0, sorted.count - 1) {
            let seg1 = sorted[i]
            let seg2 = sorted[i + 1]
            let seg1End = seg1.start + seg1.duration
            let gap = seg2.start - seg1End
            if gap > 0 && gap < Self.bridgeThreshold && time > seg1End && time < seg2.start {
                let t = Self.smoothstep(CGFloat((time - seg1End) / gap))
                return seg1.peakScale + (seg2.peakScale - seg1.peakScale) * t
            }
        }

        return nil
    }

    /// Returns the manual focus anchor at the given time, interpolating
    /// smoothly between consecutive segments (crossfade zones + bridge gaps).
    /// Returns nil when the anchor should follow the cursor (auto mode / no segment).
    private func manualZoomFocus(at time: Double) -> CGPoint? {
        let sorted = sortedZoomSegments

        // Inside a segment
        for (i, segment) in sorted.enumerated() {
            let segEnd = segment.start + segment.duration
            guard time >= segment.start, time <= segEnd else { continue }

            let prevSeg: ZoomSegment? = (i > 0 && (segment.start - (sorted[i - 1].start + sorted[i - 1].duration)) < Self.bridgeThreshold) ? sorted[i - 1] : nil
            let nextSeg: ZoomSegment? = (i < sorted.count - 1 && (sorted[i + 1].start - segEnd) < Self.bridgeThreshold) ? sorted[i + 1] : nil

            let progress = CGFloat((time - segment.start) / segment.duration)

            // Ease-in zone: crossfade focus from predecessor
            if progress < Self.easeZone, let prev = prevSeg {
                let t = Self.smoothstep(progress / Self.easeZone)
                if prev.mode == .manual && segment.mode == .manual {
                    return CGPoint(
                        x: prev.focus.x + (segment.focus.x - prev.focus.x) * t,
                        y: prev.focus.y + (segment.focus.y - prev.focus.y) * t
                    )
                }
                return segment.mode == .manual ? segment.focus : (prev.mode == .manual ? prev.focus : nil)
            }

            // Has next neighbor → hold this segment's focus (no ease-out, next seg handles transition)
            // No next neighbor → standard behavior (return focus or nil)
            return segment.mode == .manual ? segment.focus : nil
        }

        // Bridge gap
        for i in 0..<max(0, sorted.count - 1) {
            let seg1 = sorted[i]
            let seg2 = sorted[i + 1]
            let seg1End = seg1.start + seg1.duration
            let gap = seg2.start - seg1End
            if gap > 0 && gap < Self.bridgeThreshold && time > seg1End && time < seg2.start {
                let t = Self.smoothstep(CGFloat((time - seg1End) / gap))
                if seg1.mode == .manual && seg2.mode == .manual {
                    return CGPoint(
                        x: seg1.focus.x + (seg2.focus.x - seg1.focus.x) * t,
                        y: seg1.focus.y + (seg2.focus.y - seg1.focus.y) * t
                    )
                }
                if seg1.mode == .manual { return seg1.focus }
                if seg2.mode == .manual { return seg2.focus }
                return nil
            }
        }

        return nil
    }

    private func generateZoomThumbnail() {
        let time = player?.currentTime() ?? CMTime(seconds: currentTime, preferredTimescale: 600)
        let url = URL(fileURLWithPath: project.videoPath)
        Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                await MainActor.run { zoomThumbnail = nsImage }
            } catch {
                // Silently fail — editor shows fallback gray rect
            }
        }
    }

    // MARK: - Lifecycle

    private func onAppear() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49 { togglePlayPause(); return nil }          // Space
            if event.keyCode == 51 || event.keyCode == 117 {                  // Backspace / Forward Delete
                if let id = selectedZoomSegment?.id {
                    zoomSegments.removeAll { $0.id == id }
                    selectedZoomSegment = nil
                    return nil
                }
            }
            return event
        }

        sharedBackgroundManager.isEnabled = true
        sharedCursorManager.isEnabled = true

        if bgSettings.selectedBackground == nil,
           let first = sharedBackgroundManager.availableBackgrounds.first {
            sharedBackgroundManager.selectBackground(first)
        }

        project.loadMouseMetadata()
        mouseMetadata = project.mouseMetadata
        setupPlayer()

        // Restore persisted editor state
        restoreEditorState()

    }

    private func onDisappear() {
        if let token = timeObserverToken, let p = timeObserverPlayer {
            p.removeTimeObserver(token)
            timeObserverToken = nil
            timeObserverPlayer = nil
        }
        player?.pause()
        videoLoadTask?.cancel()
        autoSaveTask?.cancel()
        saveEditorState()
        zoomSoundPlayer.tearDown()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Editor State Persistence

    private func buildEditorState() -> EditorState {
        EditorState(
            videoClips: videoClips,
            zoomSegments: zoomSegments,
            typingSegments: typingSegments,
            cropRect: cropRect,
            selectedAspectRatio: selectedAspectRatio.rawValue,
            backgroundSettings: sharedBackgroundManager.settings,
            cursorScale: sharedCursorManager.cursorScale,
            cursorSmoothing: sharedCursorManager.smoothing,
            cursorOpacity: sharedCursorManager.cursorOpacity,
            cursorShadow: sharedCursorManager.cursorShadow,
            cursorEnabled: sharedCursorManager.isEnabled,
            showClickEffects: sharedCursorManager.showClickEffects,
            clickEffectStyle: sharedCursorManager.clickEffectStyle.rawValue,
            clickEffectColorHex: sharedCursorManager.clickEffectColor.toHex(),
            clickEffectSize: sharedCursorManager.clickEffectSize,
            selectedCursorName: sharedCursorManager.selectedCursor?.name,
            recordAudio: recordAudio,
            audioSource: audioSource,
            systemVolume: systemVolume,
            micVolume: micVolume,
            clickSoundEnabled: clickSoundPlayer.isEnabled,
            clickSoundStyle: clickSoundPlayer.style.rawValue,
            clickSoundVolume: clickSoundPlayer.volume,
            zoomSoundEnabled: zoomSoundPlayer.isEnabled,
            zoomSoundVolume: zoomSoundPlayer.volume,
            selectedTab: selectedTab,
            inspectorCollapsed: inspectorCollapsed
        )
    }

    private func saveEditorState() {
        project.saveEditorState(buildEditorState())
    }

    private func restoreEditorState() {
        guard let state = project.loadEditorState() else { return }

        videoClips = state.videoClips
        zoomSegments = state.zoomSegments
        sortedZoomSegments = state.zoomSegments.sorted { $0.start < $1.start }
        typingSegments = state.typingSegments ?? []
        cropRect = state.cropRect

        if let ratio = AspectRatio(rawValue: state.selectedAspectRatio) {
            selectedAspectRatio = ratio
        }

        // Background
        sharedBackgroundManager.settings = state.backgroundSettings
        // Re-match the selected background by name against available backgrounds
        if let savedBG = state.backgroundSettings.selectedBackground {
            if let match = sharedBackgroundManager.availableBackgrounds.first(where: { $0.name == savedBG.name }) {
                sharedBackgroundManager.settings.selectedBackground = match
            }
        }

        // Cursor
        sharedCursorManager.cursorScale = state.cursorScale
        sharedCursorManager.smoothing = state.cursorSmoothing
        sharedCursorManager.cursorOpacity = state.cursorOpacity
        sharedCursorManager.cursorShadow = state.cursorShadow
        sharedCursorManager.isEnabled = state.cursorEnabled
        sharedCursorManager.showClickEffects = state.showClickEffects
        if let styleRaw = state.clickEffectStyle, let style = ClickEffectStyle(rawValue: styleRaw) {
            sharedCursorManager.clickEffectStyle = style
        }
        if let hex = state.clickEffectColorHex {
            sharedCursorManager.clickEffectColor = Color(hex: hex)
        }
        if let size = state.clickEffectSize {
            sharedCursorManager.clickEffectSize = size
        }
        if let name = state.selectedCursorName,
           let match = sharedCursorManager.availableCursors.first(where: { $0.name == name }) {
            sharedCursorManager.selectCursor(match)
        }

        // Audio
        if let ra = state.recordAudio { recordAudio = ra }
        if let src = state.audioSource { audioSource = src }
        if let sv = state.systemVolume { systemVolume = sv }
        if let mv = state.micVolume { micVolume = mv }

        // Click sounds
        if let enabled = state.clickSoundEnabled { clickSoundPlayer.isEnabled = enabled }
        if let styleRaw = state.clickSoundStyle, let style = ClickSoundStyle(rawValue: styleRaw) {
            clickSoundPlayer.style = style
        }
        if let vol = state.clickSoundVolume { clickSoundPlayer.volume = vol }

        // Zoom sounds
        if let enabled = state.zoomSoundEnabled { zoomSoundPlayer.isEnabled = enabled }
        if let vol = state.zoomSoundVolume { zoomSoundPlayer.volume = vol }

        // UI
        selectedTab = state.selectedTab
        inspectorCollapsed = state.inspectorCollapsed
    }

    private func scheduleSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveEditorState()
        }
    }

    private func setupPlayer() {
        let url = URL(fileURLWithPath: project.videoPath)
        guard FileManager.default.fileExists(atPath: project.videoPath) else { return }

        // Start with a simple player; loadVideoMetadata will rebuild as composition
        player = AVPlayer(url: url)
        setupTimeObserver()

        videoLoadTask?.cancel()
        videoLoadTask = Task {
            await loadVideoMetadata(url: url, retries: 5)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                rebuildComposition()
            }
        }
    }

    /// Loads video metadata with retries — handles race condition when file is still being finalized.
    private func loadVideoMetadata(url: URL, retries: Int) async {
        for attempt in 0..<retries {
            guard !Task.isCancelled else { return }
            do {
                let asset = AVURLAsset(url: url)
                let loadedDuration = try await asset.load(.duration)
                let tracks = try await asset.load(.tracks).filter { $0.mediaType == .video }
                if let track = tracks.first {
                    let natural = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    let transformed = natural.applying(transform)
                    let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                    guard size.width > 0, size.height > 0 else { throw NSError(domain: "VideoEditor", code: -1) }
                    await MainActor.run {
                        videoSize = size
                        duration = loadedDuration.seconds
                        sourceDuration = loadedDuration.seconds
                    }
                    return
                }
                throw NSError(domain: "VideoEditor", code: -2)
            } catch {
                print("Video load attempt \(attempt + 1)/\(retries) failed: \(error)")
                if attempt < retries - 1 {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        print("Failed to load video after \(retries) attempts")
    }

    /// Builds an AVComposition from the current videoClips order and replaces the player item.
    /// Also updates clipTimeMap, compositionMetadata, compositionZoomSegments, and duration.
    private func rebuildComposition() {
        let url = URL(fileURLWithPath: project.videoPath)
        guard FileManager.default.fileExists(atPath: project.videoPath) else { return }
        guard videoSize.width > 0 else { return }  // metadata not loaded yet

        let activeClips = videoClips.filter { $0.duration > 0 }

        // If no clips defined yet, use a simple identity map for the full duration
        if activeClips.isEmpty {
            clipTimeMap = [(compositionStart: 0, sourceStart: 0, duration: duration)]
            compositionMetadata = mouseMetadata
            // Play the source directly — no composition needed
            let currentSec = currentTime
            player = AVPlayer(url: url)
            setupTimeObserver()
            player?.seek(to: CMTime(seconds: currentSec, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }

        // Build the clip time map
        clipTimeMap = ClipTimeMapping.buildTimeMap(from: activeClips)

        // Build AVComposition
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return }

        // Attempt to add audio track
        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        Task {
            do {
                let videoTracks = try await asset.load(.tracks).filter { $0.mediaType == .video }
                let audioTracks = try await asset.load(.tracks).filter { $0.mediaType == .audio }
                guard let srcVideo = videoTracks.first else { return }
                let srcAudio = audioTracks.first

                var insertionTime = CMTime.zero
                for clip in activeClips {
                    let clipStart = CMTime(seconds: clip.sourceStart, preferredTimescale: 600)
                    let clipDuration = CMTime(seconds: clip.duration, preferredTimescale: 600)
                    let range = CMTimeRange(start: clipStart, duration: clipDuration)

                    try compositionVideoTrack.insertTimeRange(range, of: srcVideo, at: insertionTime)
                    if let srcAudio = srcAudio, let audioTrack = compositionAudioTrack {
                        try audioTrack.insertTimeRange(range, of: srcAudio, at: insertionTime)
                    }
                    insertionTime = CMTimeAdd(insertionTime, clipDuration)
                }

                let compositionDuration = insertionTime.seconds
                let currentSec = min(currentTime, compositionDuration)

                await MainActor.run {
                    duration = compositionDuration

                    // Remap mouse metadata and zoom segments to composition time
                    if let meta = mouseMetadata {
                        compositionMetadata = ClipTimeMapping.remapCursorMetadata(meta, clipTimeMap: clipTimeMap)
                    }
                    // Replace player with composition-based playback
                    let wasPlaying = isPlaying
                    let item = AVPlayerItem(asset: composition)
                    player = AVPlayer(playerItem: item)
                    setupTimeObserver()
                    player?.seek(to: CMTime(seconds: currentSec, preferredTimescale: 600),
                                 toleranceBefore: .zero, toleranceAfter: .zero)
                    if wasPlaying { player?.play() }
                    cursorNeedsSnap = true
                }
            } catch {
                print("Failed to build composition: \(error)")
            }
        }
    }

    private func setupTimeObserver() {
        // Remove previous observer from the player that owns it
        if let token = timeObserverToken, let oldPlayer = timeObserverPlayer {
            oldPlayer.removeTimeObserver(token)
            timeObserverToken = nil
            timeObserverPlayer = nil
        }
        timeObserverPlayer = player
        // Capture main-actor properties before entering the closure
        let capturedSmoothing = sharedCursorManager.smoothing
        let capturedShowClickEffects = sharedCursorManager.showClickEffects
        timeObserverToken = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main
        ) { time in
            if !isManualSeeking && !isHovering {
                currentTime = time.seconds
            }
            // checkActiveZoomSegment already uses smoothstep easing —
            // no extra exponential smoothing (it causes lag/bounce).
            currentZoomLevel = checkActiveZoomSegment(at: time.seconds) ?? 1.0

            // Zoom sound — look ahead so the whoosh starts just before the visual transition
            let futureZoom = checkActiveZoomSegment(at: time.seconds + ZoomSoundPlayer.anticipation) ?? 1.0
            zoomSoundPlayer.updateZoomLevel(futureZoom)

            // Cursor position tracking (unified: zoom anchor + cursor overlay)
            // Use composition-remapped metadata so cursor aligns with reordered clips
            let effectiveMeta = compositionMetadata ?? mouseMetadata
            if let meta = effectiveMeta,
               let pos = meta.getCursorPosition(at: time.seconds) {
                let area = meta.recordedArea ?? meta.windowFrame ?? CGRect(origin: .zero, size: videoSize)
                guard area.width > 0 && area.height > 0 else {
                    zoomAnchor = .center
                    cursorScreenPos = nil
                    return
                }

                // Normalize position to [0,1] within recorded area
                var nx = (pos.x - area.minX) / area.width
                var ny = (pos.y - area.minY) / area.height

                // Apply crop adjustment
                if !cropRect.isFull {
                    nx = (nx - CGFloat(cropRect.x)) / CGFloat(cropRect.width)
                    ny = (ny - CGFloat(cropRect.y)) / CGFloat(cropRect.height)
                }

                // Snap or smooth (no clamping — cursor can exit the frame)
                let smoothing = capturedSmoothing
                if cursorNeedsSnap {
                    smoothedCurX = nx
                    smoothedCurY = ny
                    cursorNeedsSnap = false
                } else {
                    smoothedCurX += smoothing * (nx - smoothedCurX)
                    smoothedCurY += smoothing * (ny - smoothedCurY)
                }

                cursorScreenPos = CGPoint(x: smoothedCurX, y: smoothedCurY)

                // Click scale effect — check if mouse is pressed at current time
                if capturedShowClickEffects {
                    let t = time.seconds
                    let events = meta.events
                    // Binary search: index of first event at or after t
                    let atIndex = eventInsertionIndex(for: t, in: events)

                    // Find the last click-related event before current time (scan backward from atIndex)
                    var pressed = false
                    for i in stride(from: atIndex - 1, through: max(0, atIndex - 500), by: -1) {
                        let event = events[i]
                        switch event.type {
                        case .leftClick, .rightClick:
                            pressed = true
                        case .leftClickUp, .rightClickUp:
                            pressed = false
                        default:
                            continue  // skip non-click events
                        }
                        break  // found the most recent click event
                    }
                    let target: CGFloat = pressed ? 0.75 : 1.0
                    cursorClickScale += (target - cursorClickScale) * 0.35

                    // Click visual effects (ring/ripple) — only scan the time window [t-maxWindow, t]
                    let maxWindow: Double = 0.56 // max delay (0.16) + max duration (0.4)
                    let windowStart = eventInsertionIndex(for: t - maxWindow, in: events)
                    var effects: [PreviewClickEffect] = []
                    for i in windowStart..<min(events.count, atIndex + 1) {
                        let event = events[i]
                        switch event.type {
                        case .leftClick, .rightClick:
                            let elapsed = t - event.timestamp
                            guard elapsed >= 0 && elapsed <= maxWindow else { continue }
                            // Capture smoothed position the first time we see this click
                            let clickPos: CGPoint
                            if let cached = capturedClickPositions[event.timestamp] {
                                clickPos = cached
                            } else {
                                clickPos = CGPoint(x: smoothedCurX, y: smoothedCurY)
                                capturedClickPositions[event.timestamp] = clickPos
                            }
                            let ex = clickPos.x
                            let ey = clickPos.y
                            // Skip clicks outside the visible frame
                            guard ex >= 0 && ex <= 1 && ey >= 0 && ey <= 1 else { continue }
                            effects.append(PreviewClickEffect(
                                id: event.timestamp,
                                normalizedX: ex,
                                normalizedY: ey,
                                elapsed: elapsed
                            ))
                        default: break
                        }
                    }
                    activeClickEffects = effects

                    // Click sound — only scan the narrow [t-0.05, t] window
                    if clickSoundPlayer.isEnabled {
                        let soundStart = eventInsertionIndex(for: t - 0.05, in: events)
                        for i in soundStart..<min(events.count, atIndex + 1) {
                            let event = events[i]
                            switch event.type {
                            case .leftClick, .rightClick:
                                let elapsed = t - event.timestamp
                                if elapsed >= 0 && elapsed < 0.05 && event.timestamp > lastPlayedClickTime {
                                    lastPlayedClickTime = event.timestamp
                                    clickSoundPlayer.play()
                                }
                            default: break
                            }
                        }
                    }
                } else {
                    cursorClickScale = 1.0
                    activeClickEffects = []
                    capturedClickPositions.removeAll()
                }

                // Zoom anchor — smooth pan between focus points
                let targetX: CGFloat
                let targetY: CGFloat
                if let focus = manualZoomFocus(at: time.seconds) {
                    targetX = focus.x
                    targetY = focus.y
                } else {
                    targetX = smoothedCurX
                    targetY = smoothedCurY
                }
                // When zoomed, smooth the anchor to create a fluid pan between focus areas.
                // At scale ~1.0, snap to target (anchor doesn't matter).
                let panSmoothing: CGFloat = currentZoomLevel > ZoomSegment.activeThreshold ? 0.12 : 1.0
                zoomAnchor = UnitPoint(
                    x: zoomAnchor.x + (targetX - zoomAnchor.x) * panSmoothing,
                    y: zoomAnchor.y + (targetY - zoomAnchor.y) * panSmoothing
                )
            } else {
                zoomAnchor = .center
                cursorScreenPos = nil
            }

            if let dur = player?.currentItem?.duration.seconds, time.seconds >= dur {
                isPlaying = false
            }
        }
    }
}

// MARK: - Preview Click Effect

struct PreviewClickEffect: Identifiable {
    let id: Double          // click timestamp (stable ID)
    let normalizedX: CGFloat // 0..1 in video frame
    let normalizedY: CGFloat
    let elapsed: Double      // seconds since click
}

struct ClickEffectOverlay: View {
    let effects: [PreviewClickEffect]
    let style: ClickEffectStyle
    let color: Color
    let sizeMult: CGFloat
    let vidFrame: CGSize

    var body: some View {
        ZStack {
            ForEach(effects) { effect in
                let ox = (effect.normalizedX - 0.5) * vidFrame.width
                let oy = (effect.normalizedY - 0.5) * vidFrame.height

                switch style {
                case .ring:
                    ringView(elapsed: effect.elapsed, sizeMult: sizeMult)
                        .offset(x: ox, y: oy)
                case .ripple:
                    rippleView(elapsed: effect.elapsed, sizeMult: sizeMult)
                        .offset(x: ox, y: oy)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func ringView(elapsed: Double, sizeMult: CGFloat) -> some View {
        let duration = 0.35
        let progress = min(1, max(0, elapsed / duration))
        let ringSize: CGFloat = 40 * sizeMult
        let scale = 0.5 + progress * 1.0
        let opacity = 0.6 * (1 - progress)

        if elapsed >= 0 && elapsed <= duration {
            Circle()
                .stroke(color, lineWidth: 2.5)
                .frame(width: ringSize, height: ringSize)
                .scaleEffect(scale)
                .opacity(opacity)
        }
    }

    @ViewBuilder
    private func rippleView(elapsed: Double, sizeMult: CGFloat) -> some View {
        let baseSize: CGFloat = 40 * sizeMult
        let delays: [Double] = [0, 0.08, 0.16]
        let ringDuration = 0.4

        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let ringElapsed = elapsed - delays[i]
                let progress = min(1, max(0, ringElapsed / ringDuration))
                let scale = 0.3 + progress * 1.5
                let opacity = 0.5 * (1 - progress)

                if ringElapsed >= 0 && ringElapsed <= ringDuration {
                    Circle()
                        .stroke(color, lineWidth: 2.0)
                        .frame(width: baseSize, height: baseSize)
                        .scaleEffect(scale)
                        .opacity(opacity)
                }
            }
        }
    }
}

// MARK: - Zoom Focus Editor

struct ZoomFocusEditor: View {
    @Binding var focus: CGPoint
    let videoAspect: CGSize
    var thumbnail: NSImage?
    let zoomScale: CGFloat

    private let maxWidth: CGFloat = 240

    private var aspectRatio: CGFloat {
        guard videoAspect.height > 0 else { return 16.0 / 9.0 }
        return videoAspect.width / videoAspect.height
    }

    private var boxSize: CGSize {
        if aspectRatio >= 1 {
            return CGSize(width: maxWidth, height: maxWidth / aspectRatio)
        } else {
            return CGSize(width: maxWidth * aspectRatio, height: maxWidth)
        }
    }

    /// The visible viewport rect at the current zoom, normalized 0..1
    private var viewportRect: CGRect {
        guard zoomScale > 1.01 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let w = 1.0 / zoomScale
        let h = 1.0 / zoomScale
        let x = max(0, min(1 - w, focus.x - w / 2))
        let y = max(0, min(1 - h, focus.y - h / 2))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Video frame thumbnail
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                }

                // Dim area outside viewport
                let vp = viewportRect
                let vpPixel = CGRect(
                    x: vp.origin.x * boxSize.width,
                    y: vp.origin.y * boxSize.height,
                    width: vp.width * boxSize.width,
                    height: vp.height * boxSize.height
                )
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: boxSize))
                    path.addRoundedRect(in: vpPixel, cornerRadii: .init(topLeading: 2, bottomLeading: 2, bottomTrailing: 2, topTrailing: 2))
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))

                // Viewport border
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
                    .frame(width: vpPixel.width, height: vpPixel.height)
                    .position(x: vpPixel.midX, y: vpPixel.midY)

                // Crosshair at focus point
                let handleX = focus.x * boxSize.width
                let handleY = focus.y * boxSize.height
                Path { path in
                    path.move(to: CGPoint(x: handleX, y: 0))
                    path.addLine(to: CGPoint(x: handleX, y: boxSize.height))
                    path.move(to: CGPoint(x: 0, y: handleY))
                    path.addLine(to: CGPoint(x: boxSize.width, y: handleY))
                }
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)

                // Draggable handle
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .position(x: handleX, y: handleY)
            }
            .frame(width: boxSize.width, height: boxSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = max(0, min(1, value.location.x / boxSize.width))
                        let y = max(0, min(1, value.location.y / boxSize.height))
                        focus = CGPoint(x: x, y: y)
                    }
            )

            HStack(spacing: 12) {
                Text("X: \(Int(focus.x * 100))%")
                Text("Y: \(Int(focus.y * 100))%")
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Aspect Ratio

enum AspectRatio: String, CaseIterable {
    case auto = "Auto"
    case ratio16_9 = "16:9"
    case ratio4_3 = "4:3"
    case ratio1_1 = "1:1"

    var value: CGFloat {
        switch self {
        case .auto: return 0
        case .ratio16_9: return 16.0 / 9.0
        case .ratio4_3: return 4.0 / 3.0
        case .ratio1_1: return 1.0
        }
    }
}

// MARK: - Auto-Save ViewModifier

/// Extracts the many `.onChange` handlers into a single modifier to keep
/// the main body type-checkable.
private struct AutoSaveOnChange: ViewModifier {
    let zoomSegments: [ZoomSegment]
    let typingSegments: [TypingSegment]
    let videoClips: [VideoClip]
    let cropRect: CropRect
    let selectedAspectRatio: AspectRatio
    let selectedTab: Int
    let inspectorCollapsed: Bool
    let bgSettings: BackgroundSettings
    let cursorScale: CGFloat
    let cursorSmoothing: CGFloat
    let cursorEnabled: Bool
    let cursorOpacity: CGFloat
    let cursorShadow: Bool
    let showClickEffects: Bool
    let clickEffectSize: CGFloat
    let recordAudio: Bool
    let audioSource: String
    let systemVolume: CGFloat
    let micVolume: CGFloat
    let clickSoundEnabled: Bool
    let clickSoundStyle: String
    let clickSoundVolume: CGFloat
    let zoomSoundEnabled: Bool
    let zoomSoundVolume: CGFloat
    let onSave: () -> Void

    func body(content: Content) -> some View {
        content
            .modifier(EditingChanges(
                zoomSegments: zoomSegments,
                typingSegments: typingSegments,
                videoClips: videoClips,
                cropRect: cropRect,
                selectedAspectRatio: selectedAspectRatio,
                selectedTab: selectedTab,
                inspectorCollapsed: inspectorCollapsed,
                bgSettings: bgSettings,
                onSave: onSave
            ))
            .modifier(CursorChanges(
                cursorScale: cursorScale,
                cursorSmoothing: cursorSmoothing,
                cursorEnabled: cursorEnabled,
                cursorOpacity: cursorOpacity,
                cursorShadow: cursorShadow,
                showClickEffects: showClickEffects,
                clickEffectSize: clickEffectSize,
                onSave: onSave
            ))
            .modifier(AudioChanges(
                recordAudio: recordAudio,
                audioSource: audioSource,
                systemVolume: systemVolume,
                micVolume: micVolume,
                clickSoundEnabled: clickSoundEnabled,
                clickSoundStyle: clickSoundStyle,
                clickSoundVolume: clickSoundVolume,
                zoomSoundEnabled: zoomSoundEnabled,
                zoomSoundVolume: zoomSoundVolume,
                onSave: onSave
            ))
    }
}

private struct EditingChanges: ViewModifier {
    let zoomSegments: [ZoomSegment]
    let typingSegments: [TypingSegment]
    let videoClips: [VideoClip]
    let cropRect: CropRect
    let selectedAspectRatio: AspectRatio
    let selectedTab: Int
    let inspectorCollapsed: Bool
    let bgSettings: BackgroundSettings
    let onSave: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: zoomSegments) { _, _ in onSave() }
            .onChange(of: typingSegments) { _, _ in onSave() }
            .onChange(of: videoClips) { _, _ in onSave() }
            .onChange(of: cropRect) { _, _ in onSave() }
            .onChange(of: selectedAspectRatio) { _, _ in onSave() }
            .onChange(of: selectedTab) { _, _ in onSave() }
            .onChange(of: inspectorCollapsed) { _, _ in onSave() }
            .onChange(of: bgSettings) { _, _ in onSave() }
    }
}

private struct CursorChanges: ViewModifier {
    let cursorScale: CGFloat
    let cursorSmoothing: CGFloat
    let cursorEnabled: Bool
    let cursorOpacity: CGFloat
    let cursorShadow: Bool
    let showClickEffects: Bool
    let clickEffectSize: CGFloat
    let onSave: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: cursorScale) { _, _ in onSave() }
            .onChange(of: cursorSmoothing) { _, _ in onSave() }
            .onChange(of: cursorEnabled) { _, _ in onSave() }
            .onChange(of: cursorOpacity) { _, _ in onSave() }
            .onChange(of: cursorShadow) { _, _ in onSave() }
            .onChange(of: showClickEffects) { _, _ in onSave() }
            .onChange(of: clickEffectSize) { _, _ in onSave() }
    }
}

private struct AudioChanges: ViewModifier {
    let recordAudio: Bool
    let audioSource: String
    let systemVolume: CGFloat
    let micVolume: CGFloat
    let clickSoundEnabled: Bool
    let clickSoundStyle: String
    let clickSoundVolume: CGFloat
    let zoomSoundEnabled: Bool
    let zoomSoundVolume: CGFloat
    let onSave: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: recordAudio) { _, _ in onSave() }
            .onChange(of: audioSource) { _, _ in onSave() }
            .onChange(of: systemVolume) { _, _ in onSave() }
            .onChange(of: micVolume) { _, _ in onSave() }
            .onChange(of: clickSoundEnabled) { _, _ in onSave() }
            .onChange(of: clickSoundStyle) { _, _ in onSave() }
            .onChange(of: clickSoundVolume) { _, _ in onSave() }
            .onChange(of: zoomSoundEnabled) { _, _ in onSave() }
            .onChange(of: zoomSoundVolume) { _, _ in onSave() }
    }
}

