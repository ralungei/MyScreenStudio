import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultQuality") private var defaultQuality = "High"
    @AppStorage("showMouseClicks") private var showMouseClicks = true
    @AppStorage("highlightClicks") private var highlightClicks = true
    @AppStorage("recordSystemAudio") private var recordSystemAudio = true
    @AppStorage("recordMicrophone") private var recordMicrophone = false
    @AppStorage("frameRate") private var frameRate = 60
    @AppStorage("autoZoom") private var autoZoom = true
    @AppStorage("zoomIntensity") private var zoomIntensity = 1.5
    @AppStorage("cursorSize") private var cursorSize = 1.0
    @AppStorage("smoothCursor") private var smoothCursor = true
    @AppStorage("smoothingIntensity") private var smoothingIntensity = 0.5
    
    var body: some View {
        TabView {
            GeneralSettingsView(
                defaultQuality: $defaultQuality,
                frameRate: $frameRate
            )
            .tabItem {
                Label("General", systemImage: "gear")
            }
            
            RecordingSettingsView(
                recordSystemAudio: $recordSystemAudio,
                recordMicrophone: $recordMicrophone
            )
            .tabItem {
                Label("Recording", systemImage: "record.circle")
            }
            
            EffectsSettingsView(
                showMouseClicks: $showMouseClicks,
                highlightClicks: $highlightClicks,
                autoZoom: $autoZoom,
                zoomIntensity: $zoomIntensity,
                cursorSize: $cursorSize,
                smoothCursor: $smoothCursor,
                smoothingIntensity: $smoothingIntensity
            )
            .tabItem {
                Label("Effects", systemImage: "sparkles")
            }
            
            ShortcutsSettingsView()
            .tabItem {
                Label("Shortcuts", systemImage: "keyboard")
            }
            
            CursorSettingsTab()
            .tabItem {
                Label("Cursor", systemImage: "cursorarrow.click")
            }

            BackgroundSettingsTab()
            .tabItem {
                Label("Background", systemImage: "photo.on.rectangle")
            }
        }
        .frame(width: 600, height: 400)
    }
}

struct GeneralSettingsView: View {
    @Binding var defaultQuality: String
    @Binding var frameRate: Int
    
    var body: some View {
        Form {
            Section {
                Picker("Default Quality", selection: $defaultQuality) {
                    Text("Low").tag("Low")
                    Text("Medium").tag("Medium")
                    Text("High").tag("High")
                    Text("4K").tag("4K")
                }
                
                Picker("Frame Rate", selection: $frameRate) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                    Text("120 FPS").tag(120)
                }
                
                HStack {
                    Text("Output Directory:")
                    Text("~/Movies/MyScreenStudio")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Change...") {
                        
                    }
                }
            } header: {
                Text("Video Settings")
            }
        }
        .padding()
    }
}

struct RecordingSettingsView: View {
    @Binding var recordSystemAudio: Bool
    @Binding var recordMicrophone: Bool
    @State private var selectedMicrophone = "Default"
    @State private var microphoneVolume: Double = 0.7
    
    var body: some View {
        Form {
            Section {
                Toggle("Record System Audio", isOn: $recordSystemAudio)
                
                Toggle("Record Microphone", isOn: $recordMicrophone)
                
                if recordMicrophone {
                    Picker("Microphone", selection: $selectedMicrophone) {
                        Text("Default").tag("Default")
                        Text("Built-in Microphone").tag("Built-in")
                        Text("External Microphone").tag("External")
                    }
                    .padding(.leading, 20)
                    
                    HStack {
                        Text("Volume:")
                        Slider(value: $microphoneVolume, in: 0...1)
                        Text("\(Int(microphoneVolume * 100))%")
                            .frame(width: 40)
                    }
                    .padding(.leading, 20)
                }
            } header: {
                Text("Audio Settings")
            }
            
            Section {
                Toggle("Show countdown before recording", isOn: .constant(true))
                Toggle("Play sound when recording starts/stops", isOn: .constant(true))
                Toggle("Show recording indicator in menu bar", isOn: .constant(true))
            } header: {
                Text("Recording Options")
            }
        }
        .padding()
    }
}

struct EffectsSettingsView: View {
    @Binding var showMouseClicks: Bool
    @Binding var highlightClicks: Bool
    @Binding var autoZoom: Bool
    @Binding var zoomIntensity: Double
    @Binding var cursorSize: Double
    @Binding var smoothCursor: Bool
    @Binding var smoothingIntensity: Double
    
    var body: some View {
        Form {
            Section {
                Toggle("Show Mouse Clicks", isOn: $showMouseClicks)
                
                if showMouseClicks {
                    Toggle("Highlight Clicks", isOn: $highlightClicks)
                        .padding(.leading, 20)
                }
                
                HStack {
                    Text("Cursor Size:")
                    Slider(value: $cursorSize, in: 0.5...2.0)
                    Text(String(format: "%.1fx", cursorSize))
                        .frame(width: 40)
                }
            } header: {
                Text("Cursor")
            }
            
            Section {
                Toggle("Auto Zoom on Clicks", isOn: $autoZoom)
                
                if autoZoom {
                    HStack {
                        Text("Zoom Intensity:")
                        Slider(value: $zoomIntensity, in: 1.0...3.0)
                        Text(String(format: "%.1fx", zoomIntensity))
                            .frame(width: 40)
                    }
                    .padding(.leading, 20)
                }
                
                Toggle("Smooth Cursor Movement", isOn: $smoothCursor)
                
                if smoothCursor {
                    HStack {
                        Text("Smoothing:")
                        Slider(value: $smoothingIntensity, in: 0...1)
                        Text("\(Int(smoothingIntensity * 100))%")
                            .frame(width: 40)
                    }
                    .padding(.leading, 20)
                }
            } header: {
                Text("Effects")
            }
        }
        .padding()
    }
}

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section {
                ShortcutRow(action: "Start/Stop Recording", shortcut: "⌘ ⇧ R")
                ShortcutRow(action: "Pause/Resume", shortcut: "⌘ ⇧ P")
                ShortcutRow(action: "Cancel Recording", shortcut: "⌘ ⇧ C")
            } header: {
                Text("Recording")
            }
            
            Section {
                ShortcutRow(action: "Zoom In", shortcut: "⌘ +")
                ShortcutRow(action: "Zoom Out", shortcut: "⌘ -")
                ShortcutRow(action: "Reset Zoom", shortcut: "⌘ 0")
            } header: {
                Text("View")
            }
            
            Text("Click on a shortcut to change it")
                .foregroundColor(.secondary)
                .font(.caption)
                .padding(.top)
        }
        .padding()
    }
}

struct ShortcutRow: View {
    let action: String
    let shortcut: String
    
    var body: some View {
        HStack {
            Text(action)
            Spacer()
            Text(shortcut)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(4)
                .font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Cursor Settings Tab
struct CursorSettingsTab: View {
    @State private var cursorManager = CursorManager()

    var body: some View {
        Form {
            Section {
                Toggle("Enable Custom Cursor", isOn: $cursorManager.isEnabled)

                if cursorManager.isEnabled {
                    ForEach(cursorManager.availableCursors) { cursor in
                        HStack {
                            if let img = NSImage(contentsOfFile: cursor.imagePath) {
                                Image(nsImage: img)
                                    .resizable()
                                    .frame(width: 24, height: 24)
                            }
                            Text(cursor.name)
                            Spacer()
                            if cursorManager.selectedCursor?.id == cursor.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { cursorManager.selectedCursor = cursor }
                    }
                }
            } header: {
                Text("Custom Cursor")
            }
        }
        .padding()
    }
}

// MARK: - Background Settings Tab
struct BackgroundSettingsTab: View {
    var body: some View {
        Form {
            Section {
                Text("Background settings are available in the project editor sidebar.")
                    .foregroundColor(.secondary)
            } header: {
                Text("Background")
            }
        }
        .padding()
    }
}

#Preview {
    SettingsView()
}