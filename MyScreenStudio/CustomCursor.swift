import Foundation
import SwiftUI
import AppKit

// MARK: - Custom Cursor Model
struct CustomCursor: Identifiable, Codable {
    let id = UUID()
    let name: String
    let imagePath: String
    let hotSpot: CGPoint
    var isActive: Bool = false
    
    init(name: String, imagePath: String, hotSpot: CGPoint = CGPoint(x: 0, y: 0)) {
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
class CursorManager: ObservableObject {
    @Published var availableCursors: [CustomCursor] = []
    @Published var selectedCursor: CustomCursor?
    @Published var isEnabled: Bool = true // Enabled by default
    
    private let cursorsDirectory: URL
    
    init() {
        // Get the cursors directory from bundle resources
        let bundle = Bundle.main
        cursorsDirectory = URL(fileURLWithPath: bundle.resourcePath ?? "")
        
        loadAvailableCursors()
    }
    
    func loadAvailableCursors() {
        availableCursors.removeAll()
        
        // Default system cursor
        availableCursors.append(CustomCursor(name: "System Default", imagePath: ""))
        
        // Load custom cursors from bundle using Bundle.main.urls
        let bundle = Bundle.main
        print("🔍 Searching for PNG cursor files in bundle")
        
        if let pngURLs = bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) {
            let cursorFiles = pngURLs.filter { url in
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                return name.contains("cursor") || name.contains("hand") || name.contains("pointer")
            }
            
            print("🖼️ Found \(cursorFiles.count) cursor PNG files in bundle")
            
            for file in cursorFiles {
                let name = file.deletingPathExtension().lastPathComponent
                print("➕ Adding cursor: \(name) from \(file.path)")
                let cursor = CustomCursor(
                    name: formatCursorName(name),
                    imagePath: file.path,
                    hotSpot: getHotSpotForCursor(named: name)
                )
                availableCursors.append(cursor)
            }
        } else {
            print("❌ No PNG files found in bundle")
        }
        
        print("Loaded \(availableCursors.count) cursors from: \(cursorsDirectory.path)")
        for cursor in availableCursors {
            print("  - \(cursor.name): \(cursor.imagePath)")
        }
        
        // Auto-select the first custom cursor by default (not System Default)
        if selectedCursor == nil {
            selectedCursor = availableCursors.first { !$0.imagePath.isEmpty } ?? availableCursors.first
            if let selected = selectedCursor {
                print("🎯 Auto-selected cursor: \(selected.name)")
                // Don't auto-apply cursor to system
            }
        }
    }
    
    private func formatCursorName(_ name: String) -> String {
        return name
            .replacingOccurrences(of: "(1)", with: "2")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
    
    private func getHotSpotForCursor(named name: String) -> CGPoint {
        // Define hot spots for different cursor types
        let lowercaseName = name.lowercased()
        
        if lowercaseName.contains("hand") {
            return CGPoint(x: 8, y: 8) // Hand cursor hot spot
        } else if lowercaseName.contains("cursor") {
            return CGPoint(x: 0, y: 0) // Arrow cursor hot spot
        }
        
        return CGPoint(x: 8, y: 8) // Default hot spot
    }
    
    func selectCursor(_ cursor: CustomCursor) {
        selectedCursor = cursor
        // Don't apply cursor to system - just store selection
        objectWillChange.send()
    }
    
    func enableCustomCursor(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            applyCursor()
        } else {
            // Reset to system cursor
            NSCursor.arrow.set()
        }
        objectWillChange.send()
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

// MARK: - Cursor Settings View
struct CursorSettingsView: View {
    @StateObject private var cursorManager = CursorManager()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Custom Cursor")
                    .font(.headline)
                Spacer()
                Text("\(cursorManager.availableCursors.count) cursors")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Toggle("Enable Custom Cursor", isOn: $cursorManager.isEnabled)
                .onChange(of: cursorManager.isEnabled) { enabled in
                    cursorManager.enableCustomCursor(enabled)
                }
            
            if cursorManager.isEnabled {
                Text("Select Cursor:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 90))
                ], spacing: 12) {
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
                .padding(.vertical)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Cursor Info:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("• Custom cursors will appear in your recordings")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text("• \(cursorManager.availableCursors.count) cursors available")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
    }
}