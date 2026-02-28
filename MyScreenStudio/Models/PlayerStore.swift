import AVFoundation

@MainActor
final class PlayerStore: ObservableObject {
    let player: AVPlayer
    
    init(url: URL) {
        player = AVPlayer(url: url)
        player.automaticallyWaitsToMinimizeStalling = false
        player.currentItem?.preferredForwardBufferDuration = 0
    }
}