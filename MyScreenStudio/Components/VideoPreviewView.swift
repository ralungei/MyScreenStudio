import SwiftUI
import AVKit

struct VideoPreviewView: View {
    let videoURL: URL?
    @Binding var isPresented: Bool
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Recording Preview")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: {
                    isPresented = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title2)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            // Video Player
            if let player = player {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .onAppear {
                        setupPlayer()
                    }
            } else {
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        Text("Loading video...")
                            .foregroundColor(.white)
                    )
            }
            
            // Controls
            VStack(spacing: 12) {
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 4)
                        
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geometry.size.width * (duration > 0 ? currentTime / duration : 0), height: 4)
                    }
                    .cornerRadius(2)
                }
                .frame(height: 4)
                .padding(.horizontal)
                
                // Playback controls
                HStack(spacing: 20) {
                    Button(action: {
                        player?.seek(to: .zero)
                        player?.play()
                    }) {
                        Image(systemName: "backward.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: togglePlayPause) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 50, height: 50)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        player?.seek(to: CMTime(seconds: duration, preferredTimescale: 1))
                    }) {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Text(formatTime(currentTime))
                        .font(.system(.caption, design: .monospaced))
                    Text("/")
                        .foregroundColor(.secondary)
                    Text(formatTime(duration))
                        .font(.system(.caption, design: .monospaced))
                }
                .padding(.horizontal)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Action buttons
            HStack {
                Button("Delete Recording") {
                    if let url = videoURL {
                        try? FileManager.default.removeItem(at: url)
                    }
                    isPresented = false
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .foregroundColor(.red)
                
                Spacer()
                
                Button("Save As...") {
                    saveVideo()
                }
                .buttonStyle(.bordered)
                
                Button("Open in QuickTime") {
                    if let url = videoURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                
                Button("Export") {
                    exportVideo()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 900, height: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
        }
    }
    
    private func setupPlayer() {
        guard let url = videoURL else { return }
        
        player = AVPlayer(url: url)
        
        // Get duration
        Task {
            do {
                let asset = AVAsset(url: url)
                let duration = try await asset.load(.duration)
                await MainActor.run {
                    self.duration = duration.seconds
                }
            } catch {
                print("Failed to load duration: \(error)")
            }
        }
        
        // Observe playback time
        player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 1000), queue: .main) { time in
            currentTime = time.seconds
            
            // Check if ended
            if let duration = player?.currentItem?.duration.seconds,
               time.seconds >= duration {
                isPlaying = false
            }
        }
    }
    
    private func togglePlayPause() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func saveVideo() {
        guard let url = videoURL else { return }
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.quickTimeMovie]
        savePanel.nameFieldStringValue = "Recording.mov"
        
        savePanel.begin { response in
            if response == .OK, let destination = savePanel.url {
                try? FileManager.default.copyItem(at: url, to: destination)
            }
        }
    }
    
    private func exportVideo() {
        guard let url = videoURL else { return }
        
        // For now, just open the folder
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}