import SwiftUI
import AppKit
import ScreenCaptureKit
import Observation

// MARK: - Recording Backdrop Manager
@MainActor
@Observable
class RecordingBackdropManager {
    private var backdropWindow: NSWindow?
    var isShowing = false
    
    func showBackdrop(excludingWindow targetWindow: SCWindow) {
        guard backdropWindow == nil else { return }
        
        // Get all screens to create backdrop on each
        let screens = NSScreen.screens
        
        for screen in screens {
            createBackdropWindow(for: screen, excludingWindow: targetWindow)
        }
        
        isShowing = true
        print("🎭 Backdrop shown for window: \(targetWindow.title ?? "Unknown")")
    }
    
    func hideBackdrop() {
        backdropWindow?.close()
        backdropWindow = nil
        isShowing = false
        print("🎭 Backdrop hidden")
    }
    
    private func createBackdropWindow(for screen: NSScreen, excludingWindow targetWindow: SCWindow) {
        let backdropView = RecordingBackdropView(
            screenFrame: screen.frame,
            excludedWindowFrame: CGRect(
                x: targetWindow.frame.origin.x,
                y: targetWindow.frame.origin.y,
                width: targetWindow.frame.width,
                height: targetWindow.frame.height
            )
        )
        
        let hostingView = NSHostingView(rootView: backdropView)
        
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        
        // Configure window to be overlay
        window.contentView = hostingView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true // Let clicks pass through to other apps
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // Show window
        window.makeKeyAndOrderFront(nil)
        
        self.backdropWindow = window
    }
}

// MARK: - Recording Backdrop View
struct RecordingBackdropView: View {
    let screenFrame: CGRect
    let excludedWindowFrame: CGRect
    
    var body: some View {
        ZStack {
            // Black backdrop covering entire screen
            Rectangle()
                .fill(Color.black.opacity(0.7))
                .frame(
                    width: screenFrame.width,
                    height: screenFrame.height
                )
            
            // Transparent cutout for the target window
            Rectangle()
                .fill(Color.clear)
                .frame(
                    width: excludedWindowFrame.width + 20, // Add some padding
                    height: excludedWindowFrame.height + 20
                )
                .position(
                    x: excludedWindowFrame.midX - screenFrame.minX,
                    y: screenFrame.height - (excludedWindowFrame.midY - screenFrame.minY) // Flip Y coordinate
                )
                .blendMode(.destinationOut) // Creates transparent hole
        }
        .compositingGroup() // Necessary for blendMode to work properly
        .onTapGesture {
            // Allow dismissing backdrop by clicking on it
            // This could be extended to pause recording or show controls
        }
    }
}

// MARK: - Alternative Backdrop with Border Highlight
struct RecordingBackdropHighlightView: View {
    let screenFrame: CGRect
    let excludedWindowFrame: CGRect
    
    var body: some View {
        ZStack {
            // Black backdrop
            Rectangle()
                .fill(Color.black.opacity(0.6))
                .frame(
                    width: screenFrame.width,
                    height: screenFrame.height
                )
            
            // Highlighted window area with border
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.blue, lineWidth: 3)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.clear)
                )
                .frame(
                    width: excludedWindowFrame.width + 20,
                    height: excludedWindowFrame.height + 20
                )
                .position(
                    x: excludedWindowFrame.midX - screenFrame.minX,
                    y: screenFrame.height - (excludedWindowFrame.midY - screenFrame.minY)
                )
                .shadow(color: .blue.opacity(0.5), radius: 20)
                .allowsHitTesting(false)
        }
    }
}

#Preview {
    RecordingBackdropView(
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        excludedWindowFrame: CGRect(x: 400, y: 300, width: 800, height: 600)
    )
}