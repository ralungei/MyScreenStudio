import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = ScreenRecorder()
    @StateObject private var projectManager = ProjectManager()
    @State private var showingExportSheet = false
    @State private var showingSourcePicker = false
    @State private var selectedQuality = VideoQuality.high
    @State private var showingMockLayout = false
    @State private var mockProject: RecordingProject?
    
    var body: some View {
        Group {
            if showingMockLayout, let project = mockProject {
                // Video editor view
                VideoEditorView(project: project, projectManager: projectManager)
            } else if let project = projectManager.currentProject {
                // Studio view when project is open
                VideoEditorView(project: project, projectManager: projectManager)
            } else {
                // Main recording interface when no project is open
                NavigationSplitView {
                    SidebarView(
                        recorder: recorder, 
                        projectManager: projectManager,
                        showingMockLayout: $showingMockLayout,
                        mockProject: $mockProject
                    )
                    .navigationSplitViewColumnWidth(min: 250, ideal: 300)
                } detail: {
                    RecordingView(recorder: recorder, 
                                 projectManager: projectManager,
                                 showingExportSheet: $showingExportSheet,
                                 showingSourcePicker: $showingSourcePicker,
                                 selectedQuality: $selectedQuality)
                }
                .sheet(isPresented: $showingSourcePicker) {
                    RecordingSourcePicker(recorder: recorder, isPresented: $showingSourcePicker)
                }
            }
        }
        .onReceive(recorder.$currentProject) { project in
            if let project = project {
                projectManager.openProject(project)
            }
        }
        .onReceive(projectManager.$currentProject) { project in
            // Close mock layout when project manager changes
            if showingMockLayout && project == nil {
                showingMockLayout = false
                mockProject = nil
            }
        }
    }
}

struct SidebarView: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var projectManager: ProjectManager
    @State private var selectedTab = "recording"
    @State private var showingDeleteConfirmation = false
    @State private var projectToDelete: RecordingProject?
    @Binding var showingMockLayout: Bool
    @Binding var mockProject: RecordingProject?
    
    var body: some View {
        List {
            Section("Recording") {
                ForEach(recorder.availableDisplays, id: \.displayID) { display in
                    HStack {
                        Image(systemName: "display")
                        VStack(alignment: .leading) {
                            Text("Display \(display.displayID)")
                                .font(.headline)
                            Text("\(display.width) x \(display.height)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if recorder.selectedDisplay?.displayID == display.displayID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        recorder.selectedDisplay = display
                    }
                }
            }
            
            Section {
                if projectManager.availableProjects.isEmpty {
                    Text("No projects yet")
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    ForEach(projectManager.availableProjects) { project in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(project.lastModified.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            
                            Button(action: {
                                projectToDelete = project
                                showingDeleteConfirmation = true
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("Delete project")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            mockProject = project
                            showingMockLayout = true
                        }
                        .contextMenu {
                            Button("Open") {
                                mockProject = project
                                showingMockLayout = true
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                projectToDelete = project
                                showingDeleteConfirmation = true
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Text("(\(projectManager.availableProjects.count))")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            
            
        }
        .listStyle(SidebarListStyle())
        .navigationTitle("MyScreenStudio")
        .alert("Delete Project", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let project = projectToDelete {
                    projectManager.deleteProject(project)
                    projectToDelete = nil
                }
            }
        } message: {
            if let project = projectToDelete {
                Text("Are you sure you want to delete '\(project.name)'? This action cannot be undone.")
            }
        }
    }
}

struct RecordingView: View {
    @ObservedObject var recorder: ScreenRecorder
    @ObservedObject var projectManager: ProjectManager
    @Binding var showingExportSheet: Bool
    @Binding var showingSourcePicker: Bool
    @Binding var selectedQuality: VideoQuality
    
    var body: some View {
        VStack(spacing: 30) {
            if !recorder.isRecording {
                VStack(spacing: 20) {
                    Image(systemName: "video.circle")
                        .font(.system(size: 80))
                        .foregroundColor(.secondary)
                    
                    Text("Ready to Record")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    
                    Text("Select a display from the sidebar and click record to begin")
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                            .frame(width: 150, height: 150)
                        
                        Circle()
                            .trim(from: 0, to: min(recorder.recordingDuration / 60, 1))
                            .stroke(Color.red, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .frame(width: 150, height: 150)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear, value: recorder.recordingDuration)
                        
                        VStack {
                            Image(systemName: "record.circle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.red)
                                .symbolEffect(.pulse)
                            
                            Text(formatTime(recorder.recordingDuration))
                                .font(.system(.title2, design: .monospaced))
                                .fontWeight(.medium)
                        }
                    }
                    
                    Text("Recording...")
                        .font(.title)
                        .fontWeight(.semibold)
                }
            }
            
            HStack(spacing: 20) {
                if !recorder.isRecording {
                    ModernButton("Start Recording", icon: "record.circle", style: .primary) {
                        showingSourcePicker = true
                    }
                } else {
                    if !recorder.isPaused {
                        Button(action: {
                            recorder.pauseRecording()
                        }) {
                            Label("Pause", systemImage: "pause.circle")
                                .frame(width: 120)
                        }
                        .controlSize(.large)
                        .buttonStyle(.bordered)
                    } else {
                        Button(action: {
                            recorder.resumeRecording()
                        }) {
                            Label("Resume", systemImage: "play.circle")
                                .frame(width: 120)
                        }
                        .controlSize(.large)
                        .buttonStyle(.bordered)
                    }
                    
                    Button(action: {
                        Task {
                            await recorder.stopRecording()
                            // The project will be automatically opened via the onReceive in ContentView
                        }
                    }) {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .frame(width: 120)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            
            if !recorder.isRecording && !projectManager.availableProjects.isEmpty {
                ModernButton("Open Latest Project", icon: "folder.fill", style: .secondary) {
                    if let latestProject = projectManager.availableProjects.first {
                        projectManager.openProject(latestProject)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingExportSheet) {
            if let latestProject = projectManager.availableProjects.first {
                LegacyExportView(project: latestProject, selectedQuality: $selectedQuality)
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct LegacyExportView: View {
    let project: RecordingProject
    @Binding var selectedQuality: VideoQuality
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Export Settings")
                .font(.title2)
                .fontWeight(.semibold)
            
            Picker("Quality", selection: $selectedQuality) {
                ForEach(VideoQuality.allCases) { quality in
                    Text(quality.rawValue).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Button("Export") {
                    let videoURL = URL(fileURLWithPath: project.videoPath)
                    NSWorkspace.shared.open(videoURL.deletingLastPathComponent())
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(width: 400, height: 200)
    }
}

enum VideoQuality: String, CaseIterable, Identifiable, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case ultra = "4K"
    
    var id: String { rawValue }
}

#Preview {
    ContentView()
}