import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Dynamic Island Bar (Main View)
struct DynamicIslandBar: View {
    @StateObject private var recorder = ScreenRecorder()
    @ObservedObject var projectManager: ProjectManager
    @State private var showingProjects = false
    @State private var showingRecording = false
    @State private var showingSourcePicker = false
    @State private var isExpanded = false
    @State private var bounceScale: CGFloat = 1.0
    
    init(projectManager: ProjectManager) {
        self.projectManager = projectManager
    }
    
    var body: some View {
        HStack(spacing: 16) {
            if recorder.isRecording {
                // Recording indicator with pulse
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .scaleEffect(bounceScale)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: bounceScale)
                    
                    Text(formatRecordingTime(recorder.recordingDuration))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.black.opacity(0.8))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.1))
                .clipShape(Capsule())
                
                // Stop Recording Button
                Button(action: {
                    Task {
                        await recorder.stopRecording()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12))
                        Text("Stop Recording")
                            .font(.system(size: 13, weight: .medium))
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
                    .foregroundColor(.black.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                
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
                    .foregroundColor(.black.opacity(0.5))
                    .frame(width: 24, height: 24)
                    .background(Color.black.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .opacity(isExpanded ? 1.0 : 0.0)
        .padding()
        .frame(width: isExpanded ? 450 : 60, height: 60)
        .background(
            RoundedRectangle(cornerRadius: isExpanded ? 30 : 30)
                .fill(Color.white)
                .onTapGesture {
                    // Rebote suave cuando toca las partes vacías
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        bounceScale = 0.98
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            bounceScale = 1.0
                        }
                    }
                }
        )
        .scaleEffect(bounceScale)
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .animation(.spring(response: 0.8, dampingFraction: 0.7), value: isExpanded)
        .toolbar(.hidden, for: .windowToolbar)
        .onAppear {
            // Animación estilo Dynamic Island real - más rápida
            withAnimation(.interpolatingSpring(mass: 0.8, stiffness: 500, damping: 30, initialVelocity: 0)) {
                isExpanded = true
            }
        }
        .sheet(isPresented: $showingProjects) {
            ProjectsListView(projectManager: projectManager)
                .frame(width: 600, height: 400)
        }
        .sheet(isPresented: $showingSourcePicker) {
            RecordingSourcePicker(recorder: recorder, isPresented: $showingSourcePicker)
        }
    }
    
    private func formatRecordingTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Projects List View (Modal)
struct ProjectsListView: View {
    @ObservedObject var projectManager: ProjectManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) private var openWindow
    
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
                    HStack {
                        VStack(alignment: .leading) {
                            Text(project.name)
                                .font(.headline)
                            Text(project.lastModified.formatted())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        openWindow(value: project.id)
                        dismiss()
                    }
                }
            }
        }
    }
}