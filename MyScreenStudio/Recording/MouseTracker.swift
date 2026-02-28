import Foundation
import CoreGraphics
import AppKit
import Observation

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
    case leftClickUp
    case rightClick
    case rightClickUp
    case leftDrag
    case rightDrag
    case scroll(deltaX: Double, deltaY: Double)
}

struct CursorMetadata: Codable {
    var events: [MouseEvent] = []
    var keyTimestamps: [TimeInterval] = []  // Timestamps of keyDown events
    var recordingStartTime: Date?
    var recordingDuration: TimeInterval = 0
    var windowFrame: CGRect? // For window recordings
    var recordedArea: CGRect? // The actual recorded area (screen or window frame)

    // Custom decoder so old recordings without keyTimestamps don't crash
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decodeIfPresent([MouseEvent].self, forKey: .events) ?? []
        keyTimestamps = try container.decodeIfPresent([TimeInterval].self, forKey: .keyTimestamps) ?? []
        recordingStartTime = try container.decodeIfPresent(Date.self, forKey: .recordingStartTime)
        recordingDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .recordingDuration) ?? 0
        windowFrame = try container.decodeIfPresent(CGRect.self, forKey: .windowFrame)
        recordedArea = try container.decodeIfPresent(CGRect.self, forKey: .recordedArea)
    }

    init() {}

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
        case .move, .leftClickUp, .rightClickUp, .scroll:
            return false
        }
    }
}

// MARK: - Mouse Tracker

@MainActor
@Observable
class MouseTracker {
    var isTracking = false
    var metadata = CursorMetadata()
    
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var startTime: Date?
    private var recordingWindowFrame: CGRect?
    
    // Start tracking mouse events
    func startTracking(windowFrame: CGRect? = nil, recordedArea: CGRect? = nil) {
        guard !isTracking else { return }

        print("🖱️ Starting mouse tracking...")
        isTracking = true
        startTime = Date()
        recordingWindowFrame = windowFrame
        metadata = CursorMetadata()
        metadata.recordingStartTime = startTime
        metadata.windowFrame = windowFrame
        metadata.recordedArea = recordedArea ?? windowFrame

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
        let mouseTypes: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .leftMouseDragged, .rightMouseDragged, .scrollWheel, .keyDown
        ]

        // Monitor events globally (when app is not in focus)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseTypes) { [weak self] event in
            if event.type == .keyDown {
                self?.handleKeyEvent(event)
            } else {
                self?.handleMouseEvent(event)
            }
        }

        // Monitor events locally (when app is in focus)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseTypes) { [weak self] event in
            if event.type == .keyDown {
                self?.handleKeyEvent(event)
            } else {
                self?.handleMouseEvent(event)
            }
            return event
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
        case .leftMouseDown:
            eventType = .leftClick
        case .leftMouseUp:
            eventType = .leftClickUp
        case .rightMouseDown:
            eventType = .rightClick
        case .rightMouseUp:
            eventType = .rightClickUp
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
    
    private func handleKeyEvent(_ event: NSEvent) {
        guard isTracking, let startTime = startTime else { return }
        // Ignore modifier-only keys (Shift, Cmd, etc.)
        guard !event.modifierFlags.contains(.command) else { return }
        let timestamp = Date().timeIntervalSince(startTime)
        metadata.keyTimestamps.append(timestamp)
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
        // NSEvent monitors are automatically removed when their object is deallocated
        // Explicit cleanup is not required for deinit
    }
}

// MARK: - Extensions
// CGPoint and CGRect already conform to Codable in iOS 14+ / macOS 11+