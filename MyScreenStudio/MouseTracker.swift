import Foundation
import CoreGraphics
import AppKit

// MARK: - Mouse Event Data Models

struct MouseEvent: Codable {
    let timestamp: TimeInterval // Time relative to recording start
    let position: CGPoint // Screen coordinates
    let type: MouseEventType
    let windowFrame: CGRect? // For window recordings, to convert to relative coords
}

enum MouseEventType: Codable, Equatable {
    case move
    case leftClick
    case rightClick
    case leftDrag
    case rightDrag
    case scroll(deltaX: Double, deltaY: Double)
}

struct CursorMetadata: Codable {
    var events: [MouseEvent] = []
    var recordingStartTime: Date?
    var recordingDuration: TimeInterval = 0
    var windowFrame: CGRect? // For window recordings
    
    mutating func addEvent(_ event: MouseEvent) {
        events.append(event)
    }
    
    // Get cursor position at specific time in recording
    func getCursorPosition(at time: TimeInterval) -> CGPoint? {
        // Find the most recent move event before or at this time
        let relevantEvents = events.filter { 
            $0.timestamp <= time && ($0.type == .move || isClickEvent($0.type))
        }
        
        return relevantEvents.last?.position
    }
    
    // Get click events at specific time (with tolerance)
    func getClickEvents(at time: TimeInterval, tolerance: TimeInterval = 0.1) -> [MouseEvent] {
        return events.filter { event in
            let timeDiff = abs(event.timestamp - time)
            return timeDiff <= tolerance && isClickEvent(event.type)
        }
    }
    
    private func isClickEvent(_ type: MouseEventType) -> Bool {
        switch type {
        case .leftClick, .rightClick, .leftDrag, .rightDrag:
            return true
        case .move, .scroll:
            return false
        }
    }
}

// MARK: - Mouse Tracker

@MainActor
class MouseTracker: ObservableObject {
    @Published var isTracking = false
    @Published var metadata = CursorMetadata()
    
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var startTime: Date?
    private var recordingWindowFrame: CGRect?
    
    // Start tracking mouse events
    func startTracking(windowFrame: CGRect? = nil) {
        guard !isTracking else { return }
        
        print("🖱️ Starting mouse tracking...")
        isTracking = true
        startTime = Date()
        recordingWindowFrame = windowFrame
        metadata = CursorMetadata()
        metadata.recordingStartTime = startTime
        metadata.windowFrame = windowFrame
        
        setupMouseMonitoring()
    }
    
    // Stop tracking and finalize metadata
    func stopTracking() {
        guard isTracking else { return }
        
        print("🖱️ Stopping mouse tracking...")
        isTracking = false
        
        if let startTime = startTime {
            metadata.recordingDuration = Date().timeIntervalSince(startTime)
        }
        
        cleanupMonitoring()
        
        print("🖱️ Mouse tracking completed. Captured \(metadata.events.count) events")
    }
    
    private func setupMouseMonitoring() {
        // Monitor mouse events globally (when app is not in focus)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .leftMouseDragged, .rightMouseDragged, .scrollWheel
        ]) { [weak self] event in
            self?.handleMouseEvent(event)
        }
        
        // Monitor mouse events locally (when app is in focus)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .leftMouseDragged, .rightMouseDragged, .scrollWheel
        ]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event // Don't consume the event
        }
    }
    
    private func cleanupMonitoring() {
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        
        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
    
    private func handleMouseEvent(_ event: NSEvent) {
        guard isTracking, let startTime = startTime else { return }
        
        let timestamp = Date().timeIntervalSince(startTime)
        let screenLocation = NSEvent.mouseLocation
        
        // Convert NSEvent coordinates to standard screen coordinates
        let screenFrame = NSScreen.main?.frame ?? .zero
        let position = CGPoint(
            x: screenLocation.x,
            y: screenFrame.height - screenLocation.y // Flip Y coordinate
        )
        
        let eventType: MouseEventType
        
        switch event.type {
        case .mouseMoved:
            eventType = .move
        case .leftMouseDown, .leftMouseUp:
            eventType = .leftClick
        case .rightMouseDown, .rightMouseUp:
            eventType = .rightClick
        case .leftMouseDragged:
            eventType = .leftDrag
        case .rightMouseDragged:
            eventType = .rightDrag
        case .scrollWheel:
            eventType = .scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        default:
            return // Ignore other event types
        }
        
        let mouseEvent = MouseEvent(
            timestamp: timestamp,
            position: position,
            type: eventType,
            windowFrame: recordingWindowFrame
        )
        
        // Add event to metadata (on main thread since we're @MainActor)
        metadata.addEvent(mouseEvent)
        
        // Log occasionally for debugging
        if metadata.events.count % 100 == 0 {
            print("🖱️ Captured \(metadata.events.count) mouse events")
        }
    }
    
    // Convert screen coordinates to window-relative coordinates for window recordings
    func convertToWindowCoordinates(_ screenPoint: CGPoint, windowFrame: CGRect) -> CGPoint {
        return CGPoint(
            x: screenPoint.x - windowFrame.origin.x,
            y: screenPoint.y - windowFrame.origin.y
        )
    }
    
    // Save metadata to file
    func saveMetadata(to url: URL) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: url)
        print("🖱️ Saved mouse metadata to: \(url.path)")
    }
    
    // Load metadata from file
    func loadMetadata(from url: URL) throws {
        let data = try Data(contentsOf: url)
        metadata = try JSONDecoder().decode(CursorMetadata.self, from: data)
        print("🖱️ Loaded mouse metadata with \(metadata.events.count) events")
    }
    
    deinit {
        Task { @MainActor in
            cleanupMonitoring()
        }
    }
}

// MARK: - Extensions
// CGPoint and CGRect already conform to Codable in iOS 14+ / macOS 11+