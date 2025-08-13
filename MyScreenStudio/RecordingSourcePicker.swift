import SwiftUI
import ScreenCaptureKit
import AppKit

struct RecordingSourcePicker: View {
    @ObservedObject var recorder: ScreenRecorder
    @Binding var isPresented: Bool
    @State private var selectedTab = "window"
    @State private var selectedWindow: SCWindow?
    @State private var selectedApp: SCRunningApplication?
    @State private var hoveredWindow: SCWindow?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Text("Select Recording Source")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Picker("", selection: $selectedTab) {
                    Text("Window").tag("window")
                    Text("Area").tag("area")
                    Text("Full Screen").tag("screen")
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Content
            ScrollView {
                switch selectedTab {
                case "screen":
                    ScreenSelectionView(recorder: recorder, isPresented: $isPresented)
                    
                case "window":
                    WindowSelectionView(
                        recorder: recorder,
                        selectedWindow: $selectedWindow,
                        hoveredWindow: $hoveredWindow,
                        isPresented: $isPresented
                    )
                    
                case "area":
                    AreaSelectionView(recorder: recorder, isPresented: $isPresented)
                    
                default:
                    EmptyView()
                }
            }
            .frame(height: 400)
            
            Divider()
            
            // Footer
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Toggle("Record Audio", isOn: $recorder.recordAudio)
                Toggle("Show Mouse Clicks", isOn: $recorder.showMouseClicks)
                
                Spacer()
                
                Button("Start Recording") {
                    Task {
                        await recorder.startRecordingWithCurrentSelection()
                        isPresented = false
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(!recorder.hasValidSelection)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 800, height: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            await recorder.refreshAvailableContent()
        }
    }
}

struct ScreenSelectionView: View {
    @ObservedObject var recorder: ScreenRecorder
    @Binding var isPresented: Bool
    
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250))], spacing: 20) {
            ForEach(recorder.availableDisplays, id: \.displayID) { display in
                VStack {
                    // Display preview
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            VStack {
                                Image(systemName: "display")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                                Text("Display \(display.displayID)")
                                    .font(.headline)
                                Text("\(display.width) × \(display.height)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(recorder.selectedDisplay?.displayID == display.displayID ? Color.accentColor : Color.clear, lineWidth: 3)
                        )
                        .frame(height: 150)
                    
                    Button("Select") {
                        recorder.selectedDisplay = display
                        recorder.recordingMode = .fullScreen
                    }
                    .buttonStyle(.bordered)
                }
                .onTapGesture {
                    recorder.selectedDisplay = display
                    recorder.recordingMode = .fullScreen
                }
            }
        }
        .padding()
    }
}

struct WindowSelectionView: View {
    @ObservedObject var recorder: ScreenRecorder
    @Binding var selectedWindow: SCWindow?
    @Binding var hoveredWindow: SCWindow?
    @Binding var isPresented: Bool
    
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 16) {
            ForEach(recorder.availableWindows, id: \.windowID) { window in
                WindowThumbnail(
                    window: window,
                    isSelected: selectedWindow?.windowID == window.windowID,
                    isHovered: hoveredWindow?.windowID == window.windowID
                )
                .onTapGesture {
                    selectedWindow = window
                    recorder.selectedWindow = window
                    recorder.recordingMode = .window
                }
                .onHover { hovering in
                    if hovering {
                        hoveredWindow = window
                    } else if hoveredWindow?.windowID == window.windowID {
                        hoveredWindow = nil
                    }
                }
            }
        }
        .padding()
    }
}

struct WindowThumbnail: View {
    let window: SCWindow
    let isSelected: Bool
    let isHovered: Bool
    @State private var thumbnail: NSImage?
    
    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.1))
                .overlay(
                    Group {
                        if let thumbnail = thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            VStack {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.secondary)
                                Text(window.title ?? "Untitled")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .padding(8)
                        }
                    }
                )
                .frame(height: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : (isHovered ? Color.gray : Color.clear), lineWidth: isSelected ? 3 : 1)
                )
                .overlay(
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "app.fill")
                                .font(.caption2)
                            Text(window.owningApplication?.applicationName ?? "Unknown")
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                    }
                )
                .scaleEffect(isHovered ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: isHovered)
        }
        .task {
            await captureWindowThumbnail()
        }
    }
    
    @MainActor
    private func captureWindowThumbnail() async {
        // Use ScreenCaptureKit for window thumbnails
        do {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            
            // Set thumbnail size (smaller for better performance)
            let thumbnailSize = 300.0
            let aspectRatio = window.frame.width / window.frame.height
            
            if aspectRatio > 1 {
                configuration.width = Int(thumbnailSize)
                configuration.height = Int(thumbnailSize / aspectRatio)
            } else {
                configuration.width = Int(thumbnailSize * aspectRatio)
                configuration.height = Int(thumbnailSize)
            }
            
            configuration.captureResolution = .automatic
            configuration.scalesToFit = true
            
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            
            thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } catch {
            print("Failed to capture window thumbnail for window \(window.windowID): \(error)")
            // Fallback: Don't show thumbnail, just show app icon and name
        }
    }
}

struct AreaSelectionView: View {
    @ObservedObject var recorder: ScreenRecorder
    @Binding var isPresented: Bool
    @State private var selectionStart: CGPoint?
    @State private var selectionEnd: CGPoint?
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("Click 'Select Area' to choose a custom recording area")
                .font(.headline)
            
            Text("You'll be able to drag to select the exact area you want to record")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            
            Button(action: {
                startAreaSelection()
            }) {
                Label("Select Area", systemImage: "viewfinder")
                    .frame(width: 150)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            
            if recorder.selectedArea != nil {
                Text("Area Selected: \(Int(recorder.selectedArea!.width)) × \(Int(recorder.selectedArea!.height))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private func startAreaSelection() {
        isPresented = false
        recorder.startAreaSelection()
    }
}
