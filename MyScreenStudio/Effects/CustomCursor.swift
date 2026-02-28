import Foundation
import SwiftUI
import AppKit
import Observation

// MARK: - Click Effect Style
enum ClickEffectStyle: String, CaseIterable, Codable {
    case ring = "Ring"
    case ripple = "Ripple"
}

// MARK: - Custom Cursor Model
struct CustomCursor: Identifiable, Codable {
    let id: UUID
    let name: String
    let imagePath: String
    let hotSpot: CGPoint
    var isActive: Bool = false
    
    init(name: String, imagePath: String, hotSpot: CGPoint = CGPoint(x: 0, y: 0)) {
        self.id = UUID()
        self.name = name
        self.imagePath = imagePath
        self.hotSpot = hotSpot
    }
    
    var nsImage: NSImage? {
        return NSImage(contentsOfFile: imagePath)
    }
    
    var nsCursor: NSCursor? {
        guard let image = nsImage else { return nil }
        return NSCursor(image: image, hotSpot: hotSpot)
    }
}

// MARK: - Cursor Manager
@MainActor
@Observable
class CursorManager {
    var availableCursors: [CustomCursor] = []
    var selectedCursor: CustomCursor?
    var isEnabled: Bool = true

    // Cursor appearance
    var cursorScale: CGFloat = 2.0        // 0.5 ... 3.0
    var smoothing: CGFloat = 0.12         // 0.02 (very smooth) ... 0.5 (snappy)
    var showClickEffects: Bool = true
    var clickEffectStyle: ClickEffectStyle = .ripple
    var clickEffectColor: Color = .white
    var clickEffectSize: CGFloat = 1.0     // 0.5 ... 2.0
    var cursorOpacity: CGFloat = 1.0      // 0.3 ... 1.0
    var cursorShadow: Bool = true
    
    private let cursorsDirectory: URL
    
    init() {
        // Get the cursors directory from bundle resources
        let bundle = Bundle.main
        cursorsDirectory = URL(fileURLWithPath: bundle.resourcePath ?? "")
        
        loadAvailableCursors()
    }
    
    func loadAvailableCursors() {
        availableCursors.removeAll()

        let bundle = Bundle.main
        if let pngURLs = bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) {
            let cursorFiles = pngURLs.filter { url in
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                return name.contains("cursor") || name.contains("hand") || name.contains("pointer")
            }

            for file in cursorFiles {
                let name = file.deletingPathExtension().lastPathComponent
                let cursor = CustomCursor(
                    name: formatCursorName(name),
                    imagePath: file.path,
                    hotSpot: getHotSpotForCursor(named: name)
                )
                availableCursors.append(cursor)
            }
        }

        // Auto-select the first cursor by default
        if selectedCursor == nil {
            selectedCursor = availableCursors.first
        }
    }
    
    private func formatCursorName(_ name: String) -> String {
        var clean = name
            .replacingOccurrences(of: "@4x", with: "")
            .replacingOccurrences(of: "@2x", with: "")
            .replacingOccurrences(of: "(1)", with: "2")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        // Capitalize each word
        clean = clean.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        return clean
    }

    private func getHotSpotForCursor(named name: String) -> CGPoint {
        let n = name.lowercased()
        if n.contains("pointer") || n.contains("hand") {
            return CGPoint(x: 6, y: 1)   // Finger tip
        } else if n.contains("drag") {
            return CGPoint(x: 12, y: 12)  // Center of palm
        } else if n.contains("default") || n.contains("cursor") {
            return CGPoint(x: 1.75, y: 0.25)  // Arrow tip (measured from @4x PNG)
        }
        return CGPoint(x: 1.75, y: 0.25)
    }
    
    func selectCursor(_ cursor: CustomCursor) {
        selectedCursor = cursor
    }

    func enableCustomCursor(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            applyCursor()
        } else {
            NSCursor.arrow.set()
        }
    }
    
    private func applyCursor() {
        // Always apply cursor for immediate preview, regardless of isEnabled state
        if let cursor = selectedCursor {
            if cursor.imagePath.isEmpty {
                // System default
                NSCursor.arrow.set()
            } else if let nsCursor = cursor.nsCursor {
                nsCursor.set()
            }
        }
    }
    
    func setCursorForRecording() {
        guard isEnabled, let cursor = selectedCursor else { return }
        
        // Apply cursor during recording
        if let nsCursor = cursor.nsCursor {
            nsCursor.set()
        }
    }
}

// MARK: - Cursor Preview View
struct CursorPreviewView: View {
    let cursor: CustomCursor
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 45, height: 45)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                
                if cursor.imagePath.isEmpty {
                    // System cursor preview
                    Image(systemName: "cursorarrow")
                        .font(.title)
                        .foregroundColor(.primary)
                } else if let image = cursor.nsImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 20, maxHeight: 20)
                } else {
                    Image(systemName: "questionmark")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            
        }
        .onTapGesture {
            onSelect()
        }
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
    }
}

