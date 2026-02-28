import SwiftUI
import AVFoundation
import AppKit

// MARK: - Custom Video View

struct CustomVideoView: NSViewRepresentable {
    let player: AVPlayer
    var cropRect: CropRect

    init(player: AVPlayer, cropRect: CropRect = .full) {
        self.player = player
        self.cropRect = cropRect
    }

    func makeNSView(context: Context) -> CustomVideoNSView {
        return CustomVideoNSView(player: player)
    }

    func updateNSView(_ nsView: CustomVideoNSView, context: Context) {
        nsView.updateCrop(cropRect)
    }
}

class CustomVideoNSView: NSView {
    private var playerLayer: AVPlayerLayer?
    private var currentCrop: CropRect = .full

    init(player: AVPlayer) {
        super.init(frame: .zero)
        setupPlayerLayer(with: player)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupPlayerLayer(with player: AVPlayer) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true

        playerLayer = AVPlayerLayer(player: player)
        playerLayer?.videoGravity = .resizeAspectFill
        playerLayer?.backgroundColor = NSColor.clear.cgColor
        playerLayer?.frame = bounds

        if let playerLayer = playerLayer {
            layer?.addSublayer(playerLayer)
        }
    }

    func updateCrop(_ crop: CropRect) {
        guard crop != currentCrop else { return }
        currentCrop = crop
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.contentsRect = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
        CATransaction.commit()
    }

    // This view is display-only. Returning nil prevents the NSView from
    // intercepting mouse events that should reach SwiftUI buttons above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }
}
