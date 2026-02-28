import SwiftUI

// MARK: - Dynamic Island Bar (Main View)
struct DynamicIslandBar: View {
    @StateObject private var recorder = ScreenRecorder()
    var projectManager: ProjectManager
    @Environment(\.openWindow) private var openWindow
    @State private var showingProjects = false
    @State private var showingSourcePicker = false
    @State private var isExpanded = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 16) {
            if recorder.isRecording {
                // Recording indicator with pulse
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulseScale)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulseScale)

                    Text(TimeFormatting.mmss(recorder.recordingDuration))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)

                // Stop Recording Button
                Button(action: {
                    Task {
                        await recorder.stopRecording()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12))
                        Text("Stop")
                            .font(.system(size: 13, weight: .medium))
                        Text(ScreenRecorder.stopShortcutLabel)
                            .font(.system(size: 10, weight: .regular))
                            .opacity(0.7)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.red)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

            } else {
                // Projects Button
                Button(action: {
                    showingProjects.toggle()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                        Text("Projects")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
                .glassEffect(.regular, in: .capsule)

                // Start Recording Button
                Button(action: {
                    showingSourcePicker = true
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle")
                            .font(.system(size: 12))
                        Text("Start Recording")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(hex: "A4EB3F"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Close Button
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .glassEffect(.regular, in: .circle)
        }
        .opacity(isExpanded ? 1.0 : 0.0)
        .padding()
        .frame(width: isExpanded ? 450 : 60, height: 60)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30))
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .animation(.spring(response: 0.8, dampingFraction: 0.7), value: isExpanded)
        .toolbar(.hidden, for: .windowToolbar)
        .onAppear {
            recorder.projectManager = projectManager
            withAnimation(.interpolatingSpring(mass: 0.8, stiffness: 500, damping: 30, initialVelocity: 0)) {
                isExpanded = true
            }
        }
        .onChange(of: recorder.isRecording) { _, recording in
            pulseScale = recording ? 0.6 : 1.0
        }
        .onChange(of: recorder.currentProject?.id) { _, newId in
            guard let newId else { return }
            openWindow(value: newId)
        }
        .sheet(isPresented: $showingProjects) {
            ProjectsListView(projectManager: projectManager)
                .frame(width: 600, height: 400)
        }
        .sheet(isPresented: $showingSourcePicker) {
            RecordingSourcePicker(recorder: recorder, isPresented: $showingSourcePicker)
        }
    }
    
}

// MARK: - Projects List View (Modal)
struct ProjectsListView: View {
    var projectManager: ProjectManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var showingDeleteConfirmation = false
    @State private var projectToDelete: RecordingProject?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Projects")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            // Projects List
            if projectManager.availableProjects.isEmpty {
                Spacer()
                Text("No projects yet")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List(projectManager.availableProjects) { project in
                    ProjectRowWithDelete(
                        project: project,
                        onSelect: {
                            openWindow(value: project.id)
                            dismiss()
                        },
                        onDelete: {
                            projectToDelete = project
                            showingDeleteConfirmation = true
                        }
                    )
                }
            }
        }
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

// MARK: - Project Row with Delete Button
struct ProjectRowWithDelete: View {
    let project: RecordingProject
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false
    @State private var isDeleteHovered = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(project.name)
                    .font(.headline)
                Text(project.lastModified.formatted())
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            
            HStack(spacing: 16) {
                if isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                            .font(.system(size: 14))
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(Color.red.opacity(isDeleteHovered ? 0.2 : 0.1))
                            )
                            .scaleEffect(isDeleteHovered ? 1.1 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .help("Delete project")
                    .transition(.opacity.combined(with: .scale))
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isDeleteHovered = hovering
                        }
                    }
                }
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.gray.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}