import SwiftUI
import AVFoundation

// MARK: - Professional Timeline (Based on iOS Photos App)

struct ProfessionalTimelineView: View {
    @Binding var currentTime: Double
    let duration: Double
    @Binding var zoom: CGFloat
    @Binding var offset: CGFloat
    let onSeek: (Double) -> Void
    let onHover: (Double?) -> Void
    
    @State private var isDragging = false
    @State private var hoverTime: Double? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Timeline scrubber area
            TimelineTrack(
                currentTime: currentTime,
                duration: duration,
                hoverTime: hoverTime,
                isDragging: isDragging,
                onSeek: onSeek,
                onDragChanged: { time in
                    hoverTime = time
                    onHover(time)
                    // Smooth seeking while dragging
                    onSeek(time)
                },
                onDragEnded: {
                    isDragging = false
                    hoverTime = nil
                    onHover(nil)
                },
                onHoverChanged: { time in
                    if !isDragging {
                        hoverTime = time
                        onHover(time)
                    }
                }
            )
            
            // Video and effect tracks
            VStack(spacing: 8) {
                TrackView(name: "VIDEO CLIP", color: .blue, duration: duration)
                TrackView(name: "ZOOM", color: .green, duration: duration)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(Color.gray.opacity(0.05))
        }
    }
}

// MARK: - Timeline Track (Main Scrubbing Area) - CORREGIDO

struct TimelineTrack: View {
    let currentTime: Double
    let duration: Double
    let hoverTime: Double?
    let isDragging: Bool
    let onSeek: (Double) -> Void
    let onDragChanged: (Double) -> Void
    let onDragEnded: () -> Void
    let onHoverChanged: (Double?) -> Void
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 60)
                
                // Playhead line - CORREGIDO
                HStack {
                    Spacer()
                        .frame(width: currentTimeOffset(in: geometry.size.width))
                    
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2, height: 60)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .gesture(
                // Usamos DragGesture para capturar clicks y drags correctamente
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let progress = value.location.x / geometry.size.width
                        let time = max(0, min(duration, progress * duration))
                        print("🎯 INTERACTION - Mouse: \(value.location.x), Width: \(geometry.size.width), Progress: \(progress), Time: \(time)")
                        onSeek(time)
                    }
                    .onEnded { _ in
                        onDragEnded()
                    }
            )
        }
        .frame(width: UIConstants.timelineWidth, height: 60)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }
    
    // FUNCIÓN CORREGIDA para calcular offset
    private func currentTimeOffset(in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let progress = currentTime / duration
        let offset = progress * width
        print("📍 OFFSET CALC - Time: \(currentTime), Duration: \(duration), Width: \(width), Progress: \(progress), Offset: \(offset)")
        return offset
    }
}

struct UIConstants {
    static let timelineWidth: CGFloat = 800
}

// MARK: - Time Markers

struct TimeMarkers: View {
    let duration: Double
    let width: CGFloat
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(timeMarkers, id: \.self) { time in
                VStack(spacing: 4) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.8))
                        .frame(width: 1, height: isMainMark(time) ? 20 : 12)
                    
                    if isMainMark(time) {
                        Text(formatTime(time))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: markerWidth)
            }
        }
    }
    
    private var timeMarkers: [Double] {
        let interval = 1.0 // 1 second intervals
        let count = Int(duration / interval) + 1
        return (0..<count).map { Double($0) * interval }
    }
    
    private var markerWidth: CGFloat {
        let markerCount = timeMarkers.count
        return markerCount > 0 ? width / CGFloat(markerCount) : width
    }
    
    private func isMainMark(_ time: Double) -> Bool {
        return time.truncatingRemainder(dividingBy: 5.0) == 0 // Every 5 seconds
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Playhead - SIMPLIFICADO

struct Playhead: View {
    let time: Double
    let duration: Double
    let width: CGFloat
    let color: Color
    
    var body: some View {
        let position = duration > 0 ? (time / duration) * width : 0
        let _ = print("📍 PLAYHEAD - Time: \(time), Duration: \(duration), Width: \(width), Position: \(position)")
        
        VStack(spacing: 0) {
            // Pin at top
            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                )
            
            // Line extending down
            Rectangle()
                .fill(color)
                .frame(width: 3, height: 120)
        }
        .offset(x: position - 8) // Center the 16px pin
    }
}

// MARK: - Track View

struct TrackView: View {
    let name: String
    let color: Color
    let duration: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(color)
                Spacer()
            }
            
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.25))
                .frame(height: 40)
                .overlay(
                    Text(name == "VIDEO CLIP" ? "main_recording.mov" : "")
                        .font(.caption2)
                        .foregroundColor(color)
                )
        }
    }
}

