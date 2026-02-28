import SwiftUI
import AVFoundation
import CoreGraphics

// MARK: - Scroll Wheel Zoom (Option+scroll or trackpad pinch)

/// ViewModifier that installs an NSEvent local monitor for Option+scroll and trackpad pinch
/// to zoom the timeline. Doesn't interfere with the SwiftUI view hierarchy.
private struct ScrollWheelZoomModifier: ViewModifier {
    @Binding var scale: CGFloat
    @Binding var baseScale: CGFloat

    func body(content: Content) -> some View {
        content
            .onAppear { installMonitor() }
            .onDisappear { removeMonitor() }
    }

    @State private var monitor: Any? = nil

    private func installMonitor() {
        guard monitor == nil else { return }
        let m = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            if event.type == .magnify {
                // Trackpad pinch-to-zoom
                let factor = 1.0 + event.magnification
                Task { @MainActor in
                    scale = max(1.0, min(15.0, scale * factor))
                    baseScale = scale
                }
                return event
            }
            if event.type == .scrollWheel && event.modifierFlags.contains(.option) {
                // Option + scroll wheel → zoom
                let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 3)
                let factor = 1.0 + delta * 0.015
                Task { @MainActor in
                    scale = max(1.0, min(15.0, scale * factor))
                    baseScale = scale
                }
                return nil  // consume, don't scroll
            }
            return event
        }
        Task { @MainActor in
            monitor = m
        }
    }

    private func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
        }
    }
}

private extension View {
    func scrollWheelZoom(scale: Binding<CGFloat>, baseScale: Binding<CGFloat>) -> some View {
        modifier(ScrollWheelZoomModifier(scale: scale, baseScale: baseScale))
    }
}

// MARK: - Scissors Cursor

private let scissorsCursor: NSCursor = {
    let size = NSSize(width: 24, height: 24)
    let image = NSImage(size: size, flipped: false) { rect in
        if let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            configured.draw(in: rect.insetBy(dx: 2, dy: 2))
        }
        return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
}()

// MARK: - Two-Track Timeline

struct ModernTimelineView: View {
    @Binding var currentTime: Double
    @Binding var zoomSegments: [ZoomSegment]
    @Binding var videoClips: [VideoClip]
    @Binding var selectedZoomSegment: ZoomSegment?
    let duration: Double
    let sourceDuration: Double  // original video file duration for trim clamping
    let player: AVPlayer?
    var clickTimes: [Double] = []
    @Binding var typingSegments: [TypingSegment]
    let onSeek: (Double) -> Void
    let onHover: ((Double?) -> Void)?

    @State private var selectedClipId: UUID? = nil
    @State private var selectedZoomId: UUID? = nil
    @State private var selectedTypingId: UUID? = nil
    @State private var rulerHoverTime: Double? = nil

    @State private var isSplitMode = false
    @State private var isDragging = false
    @State private var isChildDragging = false   // set by ZoomChip / VideoClipBar drags
    @State private var zoomDragStart: Double? = nil
    @State private var zoomDragCurrent: Double? = nil
    @State private var zoomHoverTime: Double? = nil  // hover position on zoom track background

    // Clip reorder drag state
    @State private var draggingClipId: UUID? = nil
    @State private var dropTargetIndex: Int? = nil

    /// True when ANY drag is active (ruler, zoom-bg, chip, or clip)
    private var anyDragActive: Bool { isDragging || isChildDragging || draggingClipId != nil }

    // Horizontal zoom/scroll
    @State private var timelineScale: CGFloat = 1.0
    @State private var pinchBaseScale: CGFloat = 1.0  // scale at start of pinch gesture
    @State private var baseViewportWidth: CGFloat = 1 // set by GeometryReader

    private let rulerH: CGFloat = 40
    private let videoTrackH: CGFloat = 56
    private let zoomTrackH: CGFloat = 56
    private let typingTrackH: CGFloat = 36
    private let trackGap: CGFloat = 6

    private var totalHeight: CGFloat {
        rulerH + videoTrackH + trackGap + zoomTrackH + trackGap + typingTrackH + 4
    }

    var body: some View {
        VStack(spacing: 0) {
            mainTimeline
            bottomBar
        }
        .padding(.vertical, 6)
        .onAppear { initClipsIfNeeded() }
        .onChange(of: duration) { _, newDuration in
            if newDuration > 0 && videoClips.isEmpty {
                videoClips = [VideoClip(sourceStart: 0, sourceEnd: newDuration, label: "Clip 1")]
            }
        }
        .onKeyPress(.delete) { deleteSelected(); return .handled }
        .onKeyPress(.escape) { handleEscape() }
    }

    // MARK: - Main Timeline

    private var mainTimeline: some View {
        GeometryReader { geo in
            let viewport = geo.size.width
            let w = viewport * timelineScale
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: timelineScale > 1.05) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            rulerView(width: w)
                            videoTrackView(width: w)
                            Spacer().frame(height: trackGap)
                            zoomTrackView(width: w)
                            Spacer().frame(height: trackGap)
                            typingTrackView(width: w)
                        }

                        // Hover marker (ghost)
                        if let ht = rulerHoverTime {
                            TimelineMarker(
                                x: timeToX(ht, w: w),
                                height: totalHeight,
                                opacity: 0.35
                            )
                        }

                        // Playhead
                        TimelineMarker(
                            x: timeToX(currentTime, w: w),
                            height: totalHeight
                        )

                        // Invisible anchor for auto-scroll
                        Color.clear.frame(width: 1, height: 1)
                            .id("playhead")
                            .offset(x: timeToX(currentTime, w: w))
                    }
                    .frame(width: w, height: totalHeight)
                }
                .scrollDisabled(isChildDragging)
                .onChange(of: currentTime) { _, _ in
                    guard timelineScale > 1.05, !anyDragActive else { return }
                    // Only auto-scroll when player is actually playing — not during manual seek/scrub
                    guard player?.timeControlStatus == .playing else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("playhead", anchor: .center)
                    }
                }
            }
            .onAppear { baseViewportWidth = viewport }
            .onChange(of: geo.size.width) { _, new in baseViewportWidth = new }
            // Trackpad pinch / Option+scroll wheel zoom (via NSEvent monitor, doesn't block child gestures)
            .scrollWheelZoom(scale: $timelineScale, baseScale: $pinchBaseScale)
        }
        .frame(height: totalHeight)
        .padding(.horizontal, 12)
    }

    // MARK: - Ruler

    private func rulerView(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TimeRuler(duration: duration, width: width)

            // Click markers
            if !clickTimes.isEmpty && duration > 0 {
                ForEach(Array(clickTimes.enumerated()), id: \.offset) { _, t in
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .offset(x: CGFloat(t / duration) * width, y: rulerH - 14)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: rulerH)
        .contentShape(Rectangle())
        .gesture(seekGesture(width: width))
        .onContinuousHover { phase in
            guard !anyDragActive else { return }
            switch phase {
            case .active(let loc):
                let t = xToTime(loc.x, w: width)
                rulerHoverTime = t
                onHover?(t)
            case .ended:
                rulerHoverTime = nil
                onHover?(nil)
            }
        }
    }

    // MARK: - Video Track

    private func videoTrackView(width: CGFloat) -> some View {
        return ZStack(alignment: .leading) {
            // Background (transparent, hit-testing only)
            Color.clear

            // Clip bars — positioned by array order (cumulative duration)
            ForEach(Array(videoClips.enumerated()), id: \.element.id) { idx, clip in
                let preceding = videoClips[0..<idx].reduce(0.0) { $0 + $1.duration }
                let isDragged = clip.id == draggingClipId
                VideoClipBar(
                    clip: clip,
                    index: idx,
                    totalClips: videoClips.count,
                    duration: duration,
                    trackWidth: width,
                    trackHeight: videoTrackH,
                    isSplitMode: isSplitMode,
                    isSelected: selectedClipId == clip.id,
                    precedingDuration: preceding,
                    player: player,
                    onSeek: onSeek,
                    onSelect: { selectedClipId = clip.id },
                    onTrimLeft: { newStart in trimClipLeft(index: idx, newStart: newStart) },
                    onTrimRight: { newEnd in trimClipRight(index: idx, newEnd: newEnd) },
                    onDelete: { deleteClip(index: idx) },
                    onSplit: { time in splitClipAt(time: time) },
                    onSwapLeft: idx > 0 ? { swapClips(idx, idx - 1) } : nil,
                    onSwapRight: idx < videoClips.count - 1 ? { swapClips(idx, idx + 1) } : nil,
                    onDragUpdate: { offset in updateDropTarget(fromIndex: idx, offset: offset, trackWidth: width) },
                    onMoveEnd: { offset in
                        reorderClip(fromIndex: idx, byOffset: offset, trackWidth: width)
                        draggingClipId = nil
                        dropTargetIndex = nil
                    },
                    onDragActive: { active in isChildDragging = active },
                    onTrimStarted: { _ in },   // handles don't trigger preview
                    onTrimEnded: { }
                )
                // Non-dragged clips slide to make room at the drop target
                .offset(x: isDragged ? 0 : reorderShift(forClipAt: idx, trackWidth: width))
            }
        }
        .frame(height: videoTrackH)
        .coordinateSpace(name: "videoTrack")
        .contentShape(Rectangle())
        .gesture(seekGesture(width: width))
        .onContinuousHover { phase in
            guard !anyDragActive else { return }
            switch phase {
            case .active(let loc):
                onHover?(xToTime(loc.x, w: width))
                if isSplitMode { scissorsCursor.set() }
            case .ended:
                onHover?(nil)
                if isSplitMode { scissorsCursor.set() }
            }
        }
    }

    // MARK: - Zoom Track

    private func zoomTrackView(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Background (transparent, hit-testing only)
            Color.clear
                .contentShape(Rectangle())
                .gesture(zoomTrackGesture(width: width))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        zoomHoverTime = xToTime(loc.x, w: width)
                    case .ended:
                        zoomHoverTime = nil
                    }
                }

            // Hover ghost chip — preview shows exact size/position of zoom that would be created
            if let hoverT = zoomHoverTime, zoomDragStart == nil, !isDragging, !isChildDragging {
                let ghostStart = max(0, hoverT - 0.5)
                let ghostEnd = min(duration, ghostStart + 1.0)
                if let (fStart, fDur) = fitZoomInGap(start: ghostStart, end: ghostEnd) {
                    let gx = CGFloat(fStart / max(duration, 0.001)) * width
                    let gw = CGFloat(fDur / max(duration, 0.001)) * width
                    RoundedRectangle(cornerRadius: (zoomTrackH - 4) / 2)
                        .fill(Color(hex: "A4EB3F").opacity(0.2))
                        .frame(width: max(20, gw), height: zoomTrackH - 4)
                        .offset(x: gx)
                        .allowsHitTesting(false)
                }
            }

            // Drag preview (no hit testing)
            if let start = zoomDragStart, let current = zoomDragCurrent {
                let minT = min(start, current)
                let maxT = max(start, current)
                let x = CGFloat(minT / max(duration, 0.001)) * width
                let barW = CGFloat((maxT - minT) / max(duration, 0.001)) * width
                RoundedRectangle(cornerRadius: (zoomTrackH - 4) / 2)
                    .fill(Color(hex: "A4EB3F").opacity(0.3))
                    .frame(width: max(20, barW), height: zoomTrackH - 4)
                    .offset(x: x)
                    .allowsHitTesting(false)
            }

            // Zoom chips — disabled in split mode so scissors cursor stays
            ForEach(zoomSegments) { segment in
                ZoomChip(
                    segment: segment,
                    siblings: zoomSegments.filter { $0.id != segment.id },
                    duration: duration,
                    trackWidth: width,
                    trackHeight: zoomTrackH,
                    isSelected: selectedZoomId == segment.id,
                    onSelect: { selectZoom(segment) },
                    onUpdate: { updated in updateZoom(updated) },
                    onDelete: { deleteZoom(segment.id) },
                    onDragActive: { active in isChildDragging = active }
                )
            }
        }
        .frame(height: zoomTrackH)
        .coordinateSpace(name: "zoomTrack")
        .allowsHitTesting(!isSplitMode)  // disable all zoom interaction in split mode
    }

    // MARK: - Typing Track

    private func typingTrackView(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.orange.opacity(0.12), lineWidth: 0.5)
                )

            ForEach(typingSegments) { segment in
                TypingChip(
                    segment: segment,
                    duration: duration,
                    trackWidth: width,
                    trackHeight: typingTrackH,
                    isSelected: selectedTypingId == segment.id,
                    onSelect: {
                        selectedTypingId = segment.id
                    },
                    onUpdateSpeed: { newSpeed in
                        if let i = typingSegments.firstIndex(where: { $0.id == segment.id }) {
                            typingSegments[i].speed = newSpeed
                        }
                    },
                    onDelete: {
                        if selectedTypingId == segment.id { selectedTypingId = nil }
                        typingSegments.removeAll { $0.id == segment.id }
                    }
                )
            }
        }
        .frame(height: typingTrackH)
        .allowsHitTesting(!isSplitMode)  // disable all typing interaction in split mode
    }

    // MARK: - Gestures

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                // Skip if a clip drag is active — prevents gesture conflict
                guard !isChildDragging, draggingClipId == nil else { return }
                isDragging = true
                let time = xToTime(v.location.x, w: width)
                if isSplitMode {
                    onHover?(time)
                } else {
                    onSeek(time)
                }
            }
            .onEnded { v in
                guard isDragging else { return }
                isDragging = false
                let time = xToTime(v.location.x, w: width)
                if isSplitMode {
                    splitClipAt(time: time)
                }
                onHover?(nil)
            }
    }

    private func zoomTrackGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                isDragging = true
                zoomHoverTime = nil
                zoomDragStart = xToTime(v.startLocation.x, w: width)
                zoomDragCurrent = xToTime(v.location.x, w: width)
            }
            .onEnded { v in
                isDragging = false
                let startTime = xToTime(v.startLocation.x, w: width)
                let endTime = xToTime(v.location.x, w: width)
                let minT = min(startTime, endTime)
                let maxT = max(startTime, endTime)
                let dur = maxT - minT

                if dur >= 0.5 {
                    addZoomSegment(start: minT, duration: dur)
                } else {
                    // Click or short drag → create 1s zoom centered on click
                    let zStart = max(0, startTime - 0.5)
                    let zEnd = min(duration, zStart + 1.0)
                    let fitDur = fitZoomInGap(start: zStart, end: zEnd)
                    if let (fStart, fDur) = fitDur {
                        addZoomSegment(start: fStart, duration: fDur)
                    }
                }
                zoomDragStart = nil
                zoomDragCurrent = nil
            }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            // Pointer tool (normal mode)
            Button {
                if isSplitMode {
                    isSplitMode = false
                    NSCursor.pop()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 14))
                    Text("Select")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(!isSplitMode ? .accentColor : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(!isSplitMode ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.06)))
            }
            .buttonStyle(.plain)

            // Split tool
            Button {
                isSplitMode.toggle()
                if isSplitMode { scissorsCursor.push() }
                else { NSCursor.pop() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scissors")
                        .font(.system(size: 14))
                    Text("Split")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(isSplitMode ? .white : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(isSplitMode ? Color.orange : Color.gray.opacity(0.06)))
            }
            .buttonStyle(.plain)

            if !zoomSegments.isEmpty {
                Text("\(zoomSegments.count) zoom")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            if !typingSegments.isEmpty {
                Text("\(typingSegments.count) typing")
                    .font(.system(size: 10)).foregroundColor(.orange.opacity(0.7))
            }
            if videoClips.count > 1 {
                Text("\(videoClips.count) clips")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()

            // Timeline zoom controls
            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        timelineScale = max(1.0, timelineScale / 1.5)
                        pinchBaseScale = timelineScale
                    }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(timelineScale > 1.05 ? .primary : .secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(timelineScale <= 1.05)

                Text(timelineScale > 1.05 ? String(format: "%.0f%%", timelineScale * 100) : "Fit")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 38)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        timelineScale = min(15.0, timelineScale * 1.5)
                        pinchBaseScale = timelineScale
                    }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(timelineScale < 14.9 ? .primary : .secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(timelineScale >= 14.9)

                if timelineScale > 1.05 {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            timelineScale = 1.0
                            pinchBaseScale = 1.0
                        }
                    } label: {
                        Text("Fit")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func timeToX(_ t: Double, w: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(t / duration) * w
    }

    private func xToTime(_ x: CGFloat, w: CGFloat) -> Double {
        guard w > 0, duration > 0 else { return 0 }
        return max(0, min(duration, Double(x / w) * duration))
    }

    private func initClipsIfNeeded() {
        if duration > 0 && videoClips.isEmpty {
            videoClips = [VideoClip(sourceStart: 0, sourceEnd: duration, label: "Clip 1")]
        }
    }

    // MARK: - Clip Operations

    /// Whether clips are still in ascending source-time order (no reordering has happened)
    private var clipsInSourceOrder: Bool {
        for i in 1..<videoClips.count {
            if videoClips[i].sourceStart < videoClips[i - 1].sourceStart { return false }
        }
        return true
    }

    /// Trim left edge of clip to new start position.
    /// Magnetic when clips are in source order; independent otherwise.
    private func trimClipLeft(index: Int, newStart: Double) {
        guard index >= 0 && index < videoClips.count else { return }
        let clip = videoClips[index]

        let minAllowed = nearestSourceBoundaryLeft(for: clip)
        let clamped = max(minAllowed, min(clip.sourceEnd - 0.1, newStart))
        videoClips[index].sourceStart = clamped
    }

    /// Trim right edge of clip to new end position.
    /// Trimming removes content — neighboring clips are NOT adjusted.
    private func trimClipRight(index: Int, newEnd: Double) {
        guard index >= 0 && index < videoClips.count else { return }
        let clip = videoClips[index]

        let maxAllowed = nearestSourceBoundaryRight(for: clip)
        let clamped = max(clip.sourceStart + 0.1, min(maxAllowed, newEnd))
        videoClips[index].sourceEnd = clamped
    }

    /// Find the nearest source boundary to the left of this clip (other clips' sourceEnd or 0)
    private func nearestSourceBoundaryLeft(for clip: VideoClip) -> Double {
        var boundary: Double = 0
        for other in videoClips where other.id != clip.id {
            // Other clips that occupy source time before this clip's start
            if other.sourceEnd <= clip.sourceStart + 0.01 && other.sourceEnd > boundary {
                boundary = other.sourceEnd
            }
            // Other clips that overlap the region we'd extend into
            if other.sourceStart < clip.sourceStart && other.sourceEnd > boundary {
                boundary = other.sourceEnd
            }
        }
        return boundary
    }

    /// Find the nearest source boundary to the right of this clip (other clips' sourceStart or sourceDuration)
    private func nearestSourceBoundaryRight(for clip: VideoClip) -> Double {
        var boundary: Double = sourceDuration
        for other in videoClips where other.id != clip.id {
            // Other clips that occupy source time after this clip's end
            if other.sourceStart >= clip.sourceEnd - 0.01 && other.sourceStart < boundary {
                boundary = other.sourceStart
            }
            // Other clips that overlap the region we'd extend into
            if other.sourceEnd > clip.sourceEnd && other.sourceStart < boundary {
                boundary = other.sourceStart
            }
        }
        return boundary
    }

    private func deleteClip(index: Int) {
        guard videoClips.count > 1, index >= 0 && index < videoClips.count else { return }
        let clip = videoClips[index]

        // Magnetic gap-fill only when clips are in source order
        if clipsInSourceOrder {
            if index > 0 {
                videoClips[index - 1].sourceEnd = clip.sourceEnd
            } else if index < videoClips.count - 1 {
                videoClips[index + 1].sourceStart = clip.sourceStart
            }
        }

        videoClips.remove(at: index)

    }

    private func splitClipAt(time: Double) {
        guard let clipIndex = videoClips.firstIndex(where: {
            time > $0.sourceStart + 0.1 && time < $0.sourceEnd - 0.1
        }) else { return }

        let clip = videoClips[clipIndex]
        let left = VideoClip(
            sourceStart: clip.sourceStart, sourceEnd: time,
            label: clip.label.isEmpty ? "Clip \(clipIndex + 1)" : clip.label
        )
        let right = VideoClip(
            sourceStart: time, sourceEnd: clip.sourceEnd,
            label: "Clip \(videoClips.count + 1)"
        )
        videoClips.replaceSubrange(clipIndex...clipIndex, with: [left, right])
    }

    private func swapClips(_ a: Int, _ b: Int) {
        guard a >= 0, b >= 0, a < videoClips.count, b < videoClips.count, a != b else { return }
        videoClips.swapAt(a, b)
    }

    /// Calculate the target index for a clip drag and update the drop indicator.
    private func updateDropTarget(fromIndex: Int, offset: CGFloat, trackWidth: CGFloat) {
        guard fromIndex >= 0, fromIndex < videoClips.count else { return }
        if draggingClipId == nil { draggingClipId = videoClips[fromIndex].id }
        let newTarget = calculateDropTarget(fromIndex: fromIndex, offset: offset, trackWidth: trackWidth)
        if newTarget != dropTargetIndex {
            withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
                dropTargetIndex = newTarget
            }
        }
    }

    /// Find the target index by comparing the dragged clip's leading/trailing EDGE
    /// (in the direction of movement) against the midpoints of neighboring clips.
    /// This means a short drag is enough to reorder, even for very long clips.
    private func calculateDropTarget(fromIndex: Int, offset: CGFloat, trackWidth: CGFloat) -> Int {
        // Build visual positions for ALL clips (actual layout the user sees)
        var positions: [(start: CGFloat, end: CGFloat, mid: CGFloat)] = []
        var x: CGFloat = 0
        for c in videoClips {
            let w = CGFloat(c.duration / max(duration, 0.001)) * trackWidth
            positions.append((start: x, end: x + w, mid: x + w / 2))
            x += w
        }

        // Use the edge in the drag direction — not the center
        let draggedEdge: CGFloat
        if offset < 0 {
            draggedEdge = positions[fromIndex].start + offset   // left edge when dragging left
        } else {
            draggedEdge = positions[fromIndex].end + offset     // right edge when dragging right
        }

        var target = fromIndex

        // Check right
        for i in (fromIndex + 1)..<videoClips.count {
            if draggedEdge > positions[i].mid { target = i } else { break }
        }
        // Check left (only if didn't move right)
        if target == fromIndex {
            for i in stride(from: fromIndex - 1, through: 0, by: -1) {
                if draggedEdge < positions[i].mid { target = i } else { break }
            }
        }
        return target
    }

    /// X position for the drop indicator line — shows the boundary where the
    /// clip will land in the actual visible layout (using real clip positions).
    private func dropIndicatorX(dropIndex: Int, fromIndex: Int, trackWidth: CGFloat) -> CGFloat {
        // Use actual clip start positions
        var x: CGFloat = 0
        for (i, c) in videoClips.enumerated() {
            let w = CGFloat(c.duration / max(duration, 0.001)) * trackWidth
            if dropIndex < fromIndex {
                // Moving left: indicator at the LEFT edge of the target clip
                if i == dropIndex { return x }
            } else {
                // Moving right: indicator at the RIGHT edge of the target clip
                if i == dropIndex { return x + w }
            }
            x += w
        }
        return x
    }

    /// Horizontal shift for a non-dragged clip so other clips visually slide to
    /// make room at the drop target.  The dragged clip itself gets shift = 0.
    private func reorderShift(forClipAt idx: Int, trackWidth: CGFloat) -> CGFloat {
        guard let dragId = draggingClipId,
              let fromIdx = videoClips.firstIndex(where: { $0.id == dragId }),
              let toIdx = dropTargetIndex,
              toIdx != fromIdx,
              videoClips[idx].id != dragId else { return 0 }

        let draggedWidth = CGFloat(videoClips[fromIdx].duration / max(duration, 0.001)) * trackWidth

        if fromIdx < toIdx {
            // Dragging right → clips between (from+1...to) shift left
            if idx > fromIdx && idx <= toIdx { return -draggedWidth }
        } else {
            // Dragging left → clips between (to..<from) shift right
            if idx >= toIdx && idx < fromIdx { return draggedWidth }
        }
        return 0
    }

    /// Reorder a clip based on its final drag offset.
    private func reorderClip(fromIndex: Int, byOffset offset: CGFloat, trackWidth: CGFloat) {
        guard fromIndex >= 0, fromIndex < videoClips.count, videoClips.count > 1 else { return }
        guard abs(offset) > 5 else { return }

        let targetIndex = calculateDropTarget(fromIndex: fromIndex, offset: offset, trackWidth: trackWidth)
        guard targetIndex != fromIndex else { return }

        let removed = videoClips.remove(at: fromIndex)
        videoClips.insert(removed, at: min(targetIndex, videoClips.count))
    }

    // MARK: - Zoom Operations

    /// Find the largest gap that overlaps [start, end] and return a fitted zoom range (min 2s).
    private func fitZoomInGap(start: Double, end: Double) -> (Double, Double)? {
        // Build sorted list of occupied ranges
        let occupied = zoomSegments.map { ($0.start, $0.start + $0.duration) }.sorted { $0.0 < $1.0 }
        // Build gaps
        var gaps: [(Double, Double)] = []
        var cursor: Double = 0
        for (s, e) in occupied {
            if s > cursor { gaps.append((cursor, s)) }
            cursor = max(cursor, e)
        }
        if cursor < duration { gaps.append((cursor, duration)) }

        // Find the gap that contains the click point
        let mid = (start + end) / 2
        guard let gap = gaps.first(where: { mid >= $0.0 && mid <= $0.1 }) else { return nil }

        let available = gap.1 - gap.0
        guard available >= 0.5 else { return nil }

        let fitDur = min(end - start, available)
        guard fitDur >= 0.5 else {
            // Not enough room for desired size, use max available (if >= 1s)
            let cStart = max(gap.0, mid - min(available, 1.0) / 2)
            let cDur = min(available, 1.0)  // default click-create size capped at 1s
            return (max(gap.0, min(gap.1 - cDur, cStart)), cDur)
        }
        let fitStart = max(gap.0, min(gap.1 - fitDur, start))
        return (fitStart, fitDur)
    }

    private func addZoomSegment(start: Double, duration dur: Double) {
        let newEnd = start + dur
        let overlaps = zoomSegments.contains { seg in
            let segEnd = seg.start + seg.duration
            return start < segEnd && newEnd > seg.start
        }
        guard !overlaps else { return }

        let seg = ZoomSegment(
            start: start, duration: dur,
            peakScale: 2.0, focus: CGPoint(x: 0.5, y: 0.5)
        )
        zoomSegments.append(seg)
        selectedZoomId = seg.id

        selectedZoomSegment = seg
    }

    private func selectZoom(_ segment: ZoomSegment) {
        selectedZoomId = segment.id
        selectedZoomSegment = segment
    }

    private func updateZoom(_ updated: ZoomSegment) {
        guard let i = zoomSegments.firstIndex(where: { $0.id == updated.id }) else { return }
        let clamped = clampZoomSegment(updated, at: i)
        zoomSegments[i] = clamped
        if selectedZoomId == clamped.id { selectedZoomSegment = clamped }
    }

    private func deleteZoom(_ id: UUID) {
        if selectedZoomId == id {
            selectedZoomId = nil
            selectedZoomSegment = nil
        }
        zoomSegments.removeAll { $0.id == id }
    }

    private func deleteSelected() {
        // Priority: clip > zoom > typing
        if let clipId = selectedClipId {
            if let idx = videoClips.firstIndex(where: { $0.id == clipId }), videoClips.count > 1 {
                selectedClipId = nil
                deleteClip(index: idx)
            }
            return
        }
        if let id = selectedZoomId {
            deleteZoom(id)
            return
        }
        if let id = selectedTypingId {
            selectedTypingId = nil
            typingSegments.removeAll { $0.id == id }
        }
    }

    private func clampZoomSegment(_ segment: ZoomSegment, at index: Int) -> ZoomSegment {
        var s = segment
        let originalDuration = s.duration  // never expand beyond what was passed in
        let sorted = zoomSegments.enumerated().sorted { $0.element.start < $1.element.start }
        guard let sortedIdx = sorted.firstIndex(where: { $0.offset == index }) else { return s }

        let leftBound: Double = sortedIdx > 0
            ? sorted[sortedIdx - 1].element.start + sorted[sortedIdx - 1].element.duration
            : 0
        let rightBound: Double = sortedIdx < sorted.count - 1
            ? sorted[sortedIdx + 1].element.start
            : duration

        if s.start < leftBound { s.start = leftBound }
        if s.start + s.duration > rightBound { s.duration = rightBound - s.start }
        // Never expand beyond the original duration
        s.duration = min(s.duration, originalDuration)
        return s
    }

    private func handleEscape() -> KeyPress.Result {
        if isSplitMode {
            isSplitMode = false
            NSCursor.pop()
            return .handled
        }
        if selectedClipId != nil {
            selectedClipId = nil
            return .handled
        }
        if selectedZoomId != nil {
            selectedZoomId = nil
            selectedZoomSegment = nil
            return .handled
        }
        if selectedTypingId != nil {
            selectedTypingId = nil
            return .handled
        }
        return .ignored
    }
}

// MARK: - Video Clip Bar

private struct VideoClipBar: View {
    let clip: VideoClip
    let index: Int
    let totalClips: Int
    let duration: Double
    let trackWidth: CGFloat
    let trackHeight: CGFloat
    let isSplitMode: Bool
    let isSelected: Bool
    let precedingDuration: Double
    let player: AVPlayer?
    let onSeek: (Double) -> Void
    let onSelect: () -> Void
    let onTrimLeft: (Double) -> Void
    let onTrimRight: (Double) -> Void
    let onDelete: () -> Void
    let onSplit: (Double) -> Void
    let onSwapLeft: (() -> Void)?
    let onSwapRight: (() -> Void)?
    let onDragUpdate: ((CGFloat) -> Void)?
    let onMoveEnd: (CGFloat) -> Void
    let onDragActive: (Bool) -> Void
    let onTrimStarted: (Double) -> Void   // called once at trim start — marks isHovering
    let onTrimEnded: () -> Void           // called once at trim end — clears isHovering

    @State private var isHovered = false
    @State private var dragOrigin: VideoClip? = nil
    @State private var dragMode: DragMode = .none
    @State private var moveOffset: CGFloat = 0
    @State private var moveStartX: CGFloat? = nil  // track-space X at drag start

    private enum DragMode { case none, trimLeft, trimRight, move, scrub }

    private var handleDiameter: CGFloat { trackHeight - 12 }
    private var edgeW: CGFloat { min(handleDiameter + 8, clipW / 3) }

    private let chipGap: CGFloat = 1.5  // half-gap on each side between adjacent clips

    /// Position by array order (cumulative duration of preceding clips)
    private var clipX: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(precedingDuration / duration) * trackWidth + chipGap
    }

    private var clipW: CGFloat {
        guard duration > 0 else { return 20 }
        return max(20, CGFloat(clip.duration / duration) * trackWidth - chipGap * 2)
    }

    /// Opacity multiplier based on interaction state
    private func op(_ base: Double) -> Double {
        isSelected ? base : (isHovered ? base * 0.85 : base * 0.7)
    }

    var body: some View {
        ZStack {
            // White fill
            RoundedRectangle(cornerRadius: (trackHeight - 4) / 2)
                .fill(Color.white)

            // Border
            RoundedRectangle(cornerRadius: (trackHeight - 4) / 2)
                .strokeBorder(
                    isSelected ? Color(hex: "A4EB3F") : Color.white.opacity(isHovered ? 0.3 : 0.1),
                    lineWidth: isSelected ? 2.5 : 1
                )

            // Label — only if there's enough room between handles
            if clipW > handleDiameter * 2 + 20 {
                Text(clip.label.isEmpty ? "Clip" : clip.label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.black.opacity(0.6))
                    .lineLimit(1)
            }

            // Trim edge handles — lime green circles with chevrons (always visible)
            if !isSplitMode {
                HStack {
                    Circle()
                        .fill(Color(hex: "A4EB3F"))
                        .frame(width: handleDiameter, height: handleDiameter)
                        .overlay(
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.black.opacity(0.5))
                        )
                    Spacer()
                    Circle()
                        .fill(Color(hex: "A4EB3F"))
                        .frame(width: handleDiameter, height: handleDiameter)
                        .overlay(
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.black.opacity(0.5))
                        )
                }.padding(.horizontal, 4)
            }
        }
        .frame(width: clipW, height: trackHeight - 4)
        // contentShape + gestures + hover BEFORE offset so hit-testing is in view-local space
        .contentShape(Rectangle())
        .allowsHitTesting(!isSplitMode)
        .highPriorityGesture(unifiedGesture)
        .onHover { h in
            guard dragOrigin == nil else { return }
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = h }
        }
        .onContinuousHover { phase in
            guard dragOrigin == nil else { return }
            switch phase {
            case .active(let loc):
                if loc.x < edgeW || loc.x > clipW - edgeW {
                    NSCursor.resizeLeftRight.set()
                } else if totalClips > 1 {
                    NSCursor.openHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            case .ended:
                NSCursor.arrow.set()
            }
        }
        // offset AFTER gestures — shifts visual + hit area together
        .offset(x: clipX + moveOffset)
        .zIndex(dragMode == .move ? 100 : 0)
        .opacity(dragMode == .move ? 0.85 : 1.0)
        .contextMenu {
            if let onSwapLeft {
                Button("Move Left") { onSwapLeft() }
            }
            if let onSwapRight {
                Button("Move Right") { onSwapRight() }
            }
            if onSwapLeft != nil || onSwapRight != nil {
                Divider()
            }
            if totalClips > 1 {
                Button("Delete Clip", role: .destructive) { onDelete() }
            }
        }
    }

    /// Unified gesture: minimumDistance=0 so taps are captured too.
    /// Tap (no significant movement) → select + seek.
    /// Drag from edge → trim (commits live every frame, adjacent clips shift in real-time).
    /// Drag from body → scrub (preview), promotes to move/reorder after a larger threshold.
    /// Move mode uses track coordinate space to avoid ScrollView distortion.
    private var unifiedGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("videoTrack"))
            .onChanged { v in
                let dist = v.translation.width.magnitude
                if dragOrigin == nil && dist >= 2 {
                    dragOrigin = clip
                    onDragActive(true)
                    // Use local start position for edge detection (relative to clip's leading edge)
                    let localStartX = v.startLocation.x - clipX
                    if localStartX < edgeW {
                        dragMode = .trimLeft
                        onTrimStarted(0)
                    } else if localStartX > clipW - edgeW {
                        dragMode = .trimRight
                        onTrimStarted(0)
                    } else {
                        // Body area — start as scrub, may promote to move later
                        dragMode = .scrub
                        moveStartX = v.startLocation.x
                    }
                }
                guard let orig = dragOrigin else { return }
                switch dragMode {
                case .trimLeft:
                    let basePxL = max(1, CGFloat(orig.duration / max(0.001, duration)) * trackWidth)
                    let sourceDtL = Double(v.translation.width / basePxL) * orig.duration
                    onTrimLeft(orig.sourceStart + sourceDtL)
                    // Preview the frame at the new left edge
                    onSeek(max(0, precedingDuration))
                case .trimRight:
                    let basePxR = max(1, CGFloat(orig.duration / max(0.001, duration)) * trackWidth)
                    let sourceDtR = Double(v.translation.width / basePxR) * orig.duration
                    onTrimRight(orig.sourceEnd + sourceDtR)
                    // Preview the frame at the new right edge
                    onSeek(max(0, precedingDuration + clip.duration))
                case .scrub:
                    // Promote to move after a bigger threshold (only if multiple clips)
                    if totalClips > 1 && dist > 20 {
                        dragMode = .move
                        NSCursor.closedHand.push()
                    } else {
                        // Scrub: convert track-space X to composition time
                        let time = max(0, min(duration, Double(v.location.x / trackWidth) * duration))
                        onSeek(time)
                    }
                case .move:
                    if let startX = moveStartX {
                        let raw = v.location.x - startX
                        // Clamp so clip can't go past track edges
                        let maxLeft = -clipX  // don't go past x=0
                        let maxRight = trackWidth - clipX - clipW  // don't go past track end
                        moveOffset = max(maxLeft, min(maxRight, raw))
                    }
                    onDragUpdate?(moveOffset)
                case .none:
                    break
                }
            }
            .onEnded { v in
                let isTrim = dragMode == .trimLeft || dragMode == .trimRight
                if dragOrigin == nil {
                    // Tap → select + seek to tap position
                    onSelect()
                    let time = max(0, min(duration, Double(v.location.x / trackWidth) * duration))
                    onSeek(time)
                } else {
                    switch dragMode {
                    case .trimLeft, .trimRight:
                        break
                    case .scrub:
                        // Was scrubbing, final seek
                        let time = max(0, min(duration, Double(v.location.x / trackWidth) * duration))
                        onSeek(time)
                    case .move:
                        NSCursor.pop()
                        let finalOffset = moveOffset
                        moveOffset = 0
                        onMoveEnd(finalOffset)
                    case .none:
                        break
                    }
                }
                onDragActive(false)
                moveOffset = 0
                moveStartX = nil
                dragOrigin = nil
                dragMode = .none
                if isTrim { onTrimEnded() }
            }
    }

}

// MARK: - Time Ruler

private struct TimeRuler: View {
    let duration: Double
    let width: CGFloat

    var body: some View {
        Canvas { ctx, size in
            guard duration > 0, width > 0 else { return }
            let h = size.height
            let (major, minor) = intervals()

            var t: Double = 0
            while t <= duration + 0.001 {
                let x = CGFloat(t / duration) * width
                let isMajor = major > 0 && t.remainder(dividingBy: major).magnitude < 0.01

                if isMajor {
                    // Skip 0:00 — can't center it at the edge
                    if t < 0.01 { t += minor; continue }

                    // Tick line for seconds
                    ctx.stroke(
                        Path { p in
                            p.move(to: CGPoint(x: x, y: h - 8))
                            p.addLine(to: CGPoint(x: x, y: h))
                        },
                        with: .color(.gray.opacity(0.4)),
                        lineWidth: 0.5
                    )
                    ctx.draw(
                        Text(fmtTime(t))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary.opacity(0.8)),
                        at: CGPoint(x: x, y: h / 2 - 2),
                        anchor: .center
                    )
                } else {
                    // Dot for intermediate ticks — higher up for spacing from clips
                    let dotSize: CGFloat = 4
                    ctx.fill(
                        Path(ellipseIn: CGRect(
                            x: x - dotSize / 2,
                            y: h - 12 - dotSize / 2,
                            width: dotSize,
                            height: dotSize
                        )),
                        with: .color(.gray.opacity(0.3))
                    )
                }
                t += minor
            }
        }
    }

    private func intervals() -> (Double, Double) {
        if duration <= 15 { return (1.0, 0.5) }
        if duration <= 30 { return (1.0, 0.5) }
        if duration <= 60 { return (5.0, 1.0) }
        if duration <= 120 { return (10.0, 2.0) }
        return (30.0, 5.0)
    }

    private func fmtTime(_ t: Double) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Playhead

private struct TimelineMarker: View {
    let x: CGFloat
    let height: CGFloat
    var opacity: Double = 1.0

    private let color = Color(hex: "A4EB3F") // lime green
    private let headSize: CGFloat = 10
    private let lineW: CGFloat = 1.5

    var body: some View {
        VStack(spacing: 0) {
            // Liquid drop head
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            color.opacity(0.95),
                            color.opacity(0.7)
                        ],
                        center: .init(x: 0.4, y: 0.35),
                        startRadius: 0,
                        endRadius: headSize / 2
                    )
                )
                .frame(width: headSize, height: headSize)
                .overlay(
                    // Glass highlight
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.5), .clear],
                                startPoint: .topLeading,
                                endPoint: .center
                            )
                        )
                        .scaleEffect(0.6)
                        .offset(x: -1.2, y: -1.2)
                )
                .shadow(color: color.opacity(0.4), radius: 3, x: 0, y: 1)

            // Line
            RoundedRectangle(cornerRadius: lineW / 2)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.7), color.opacity(0.2)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: lineW, height: max(0, height - headSize))
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .offset(x: x - headSize / 2)
    }
}

// MARK: - Zoom Chip

private struct ZoomChip: View {
    let segment: ZoomSegment
    let siblings: [ZoomSegment]  // other segments for collision detection
    let duration: Double
    let trackWidth: CGFloat
    let trackHeight: CGFloat
    let isSelected: Bool
    let onSelect: () -> Void
    let onUpdate: (ZoomSegment) -> Void
    let onDelete: () -> Void
    let onDragActive: (Bool) -> Void

    @State private var dragOrigin: ZoomSegment? = nil
    @State private var dragMode: DragMode = .move
    @State private var isHovered = false

    @State private var committedSegment: ZoomSegment? = nil

    private enum DragMode { case move, resizeLeft, resizeRight }

    private var handleDiameter: CGFloat { trackHeight - 12 }
    private var edgeW: CGFloat { min(handleDiameter + 8, chipW / 3) }

    /// The segment used for visual layout (committed value during drag, live value otherwise)
    private var visualSegment: ZoomSegment { committedSegment ?? segment }

    private let chipGap: CGFloat = 1.5

    private var chipX: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(visualSegment.start / duration) * trackWidth + chipGap
    }

    private var chipW: CGFloat {
        guard duration > 0 else { return 20 }
        return max(20, CGFloat(visualSegment.duration / duration) * trackWidth - chipGap * 2)
    }

    /// Opacity multiplier — always full
    private func zop(_ base: Double) -> Double { base }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: (trackHeight - 4) / 2)
                .fill(Color(hex: "A4EB3F").opacity(zop(1.0)))
                .overlay(
                    RoundedRectangle(cornerRadius: (trackHeight - 4) / 2)
                        .strokeBorder(
                            isSelected ? Color.white.opacity(0.5) : Color.white.opacity(isHovered ? 0.3 : 0.1),
                            lineWidth: isSelected ? 2.0 : 1.0
                        )
                )

            if chipW > 40 || isHovered || isSelected {
                HStack(spacing: 4) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                    Text(String(format: "%.1fx", segment.peakScale))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    if chipW > 90 {
                        HStack(spacing: 3) {
                            Image(systemName: segment.mode == .manual ? "mappin" : "computermouse")
                                .font(.system(size: 9, weight: .semibold))
                            Text(segment.mode == .manual ? "Manual" : "Auto")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.12))
                        .clipShape(Capsule())
                        .padding(.leading, 4)
                    }
                }
                .foregroundColor(.black.opacity(0.85))
            }

            // Resize handles — visible on hover/selected, hidden if chip too narrow
            if (isHovered || isSelected) && chipW > handleDiameter * 2 + 12 {
            HStack {
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: handleDiameter, height: handleDiameter)
                    .overlay(
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black.opacity(0.5))
                    )
                Spacer()
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: handleDiameter, height: handleDiameter)
                    .overlay(
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black.opacity(0.5))
                    )
            }.padding(.horizontal, 4)
            }
        }
        .frame(width: chipW, height: trackHeight - 4)
        // contentShape + gestures + hover BEFORE offset
        .contentShape(Rectangle())
        .highPriorityGesture(unifiedDragGesture)
        .onHover { h in
            guard dragOrigin == nil else { return }  // suppress hover changes during drag
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = h }
        }
        .onContinuousHover { phase in
            guard dragOrigin == nil else { return }  // suppress cursor changes during drag
            switch phase {
            case .active(let loc):
                if loc.x < edgeW || loc.x > chipW - edgeW {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.openHand.set()
                }
            case .ended:
                NSCursor.arrow.set()
            }
        }
        // offset AFTER — shifts visual + hit area
        .offset(x: chipX)
        .contextMenu {
            Section("Zoom") {
                ForEach([1.5, 2.0, 3.0, 4.0], id: \.self) { scale in
                    Button {
                        setScale(scale)
                    } label: {
                        Label(String(format: "%.1fx", scale), systemImage: segment.peakScale == scale ? "checkmark.circle.fill" : "magnifyingglass")
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// Unified: minimumDistance=0 so taps select, drags move/resize.
    /// Uses local visual state during drag, commits to model only on end.
    private var unifiedDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("zoomTrack"))
            .onChanged { v in
                let dist = v.translation.width.magnitude + v.translation.height.magnitude
                if dragOrigin == nil && dist >= 2 {
                    dragOrigin = segment
                    committedSegment = segment
                    onDragActive(true)
                    // Detect edge from start position relative to chip
                    let chipStartX = CGFloat(segment.start / duration) * trackWidth
                    let localX = v.startLocation.x - chipStartX
                    let baseW = max(20, CGFloat(segment.duration / duration) * trackWidth)
                    if localX < edgeW {
                        dragMode = .resizeLeft
                    } else if localX > baseW - edgeW {
                        dragMode = .resizeRight
                    } else {
                        dragMode = .move
                        NSCursor.closedHand.push()
                    }
                }
                guard let o = dragOrigin else { return }
                let dt = Double(v.translation.width / trackWidth) * duration
                var s = o
                switch dragMode {
                case .resizeLeft:
                    let end = o.start + o.duration
                    let newStart = max(0, min(end - 0.5, o.start + dt))
                    s.start = newStart
                    s.duration = end - newStart
                case .resizeRight:
                    s.duration = max(0.5, min(duration - o.start, o.duration + dt))
                case .move:
                    s.start = max(0, min(duration - o.duration, o.start + dt))
                }
                committedSegment = clampToSiblings(s)
            }
            .onEnded { _ in
                if dragOrigin == nil {
                    onSelect()
                } else {
                    if let final = committedSegment {
                        onUpdate(final)
                    }
                    if dragMode == .move { NSCursor.pop() }
                }
                onDragActive(false)
                committedSegment = nil
                dragOrigin = nil
                dragMode = .move
            }
    }

    /// Clamp a segment so it doesn't overlap any sibling.
    /// For move: snaps position, duration stays constant.
    /// For resize: clamps the resized edge to sibling boundaries.
    private func clampToSiblings(_ s: ZoomSegment) -> ZoomSegment {
        var result = s

        for sib in siblings {
            let sibEnd = sib.start + sib.duration
            let resEnd = result.start + result.duration  // recalculate each iteration

            switch dragMode {
            case .move:
                // Duration must NOT change during move — only position
                if result.start < sibEnd && resEnd > sib.start {
                    let overlapLeft = sibEnd - result.start
                    let overlapRight = resEnd - sib.start
                    if overlapLeft < overlapRight {
                        result.start = sibEnd
                    } else {
                        result.start = sib.start - result.duration
                    }
                }
            case .resizeLeft:
                let end = result.start + result.duration
                if result.start < sibEnd && end > sib.start && sib.start < result.start {
                    result.start = sibEnd
                    result.duration = end - sibEnd
                }
            case .resizeRight:
                let resEnd2 = result.start + result.duration
                if resEnd2 > sib.start && result.start < sib.start {
                    result.duration = sib.start - result.start
                }
            }
        }

        // Keep within timeline bounds
        result.start = max(0, result.start)
        if result.start + result.duration > duration {
            result.start = duration - result.duration
        }
        return result
    }

    private func setScale(_ scale: CGFloat) {
        var s = segment
        s.peakScale = scale
        onUpdate(s)
    }
}

// MARK: - Typing Chip

private struct TypingChip: View {
    let segment: TypingSegment
    let duration: Double
    let trackWidth: CGFloat
    let trackHeight: CGFloat
    let isSelected: Bool
    let onSelect: () -> Void
    let onUpdateSpeed: (CGFloat) -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var chipX: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(segment.start / duration) * trackWidth
    }

    private var chipW: CGFloat {
        guard duration > 0 else { return 20 }
        return max(20, CGFloat(segment.duration / duration) * trackWidth)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.orange.opacity(isSelected ? 0.40 : (isHovered ? 0.30 : 0.18)))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            isSelected ? Color.orange : Color.orange.opacity(isHovered ? 0.6 : 0.3),
                            lineWidth: isSelected ? 2.0 : 1.0
                        )
                )

            HStack(spacing: 3) {
                Image(systemName: "keyboard")
                    .font(.system(size: 8))
                if chipW > 50 || isHovered || isSelected {
                    Text(String(format: "%.0fx", segment.speed))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
            }
            .foregroundColor(.orange)
        }
        .frame(width: chipW, height: trackHeight - 4)
        // contentShape + tap + hover BEFORE offset
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = h }
        }
        // offset AFTER
        .offset(x: chipX)
        .contextMenu {
            ForEach(TypingSegment.speedPresets, id: \.self) { speed in
                Button(String(format: "%.0fx", speed)) {
                    onUpdateSpeed(speed)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}
