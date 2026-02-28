import Foundation
import CoreGraphics

/// Persisted editor state — saved as `editor_state.json` in the project folder.
struct EditorState: Codable {
    // Editing
    var videoClips: [VideoClip]
    var zoomSegments: [ZoomSegment]
    var typingSegments: [TypingSegment]?
    var cropRect: CropRect
    var selectedAspectRatio: String  // AspectRatio.rawValue

    // Background
    var backgroundSettings: BackgroundSettings

    // Cursor
    var cursorScale: CGFloat
    var cursorSmoothing: CGFloat
    var cursorOpacity: CGFloat
    var cursorShadow: Bool
    var cursorEnabled: Bool
    var showClickEffects: Bool
    var clickEffectStyle: String?     // ClickEffectStyle rawValue
    var clickEffectColorHex: String?  // hex color string
    var clickEffectSize: CGFloat?     // 0.5...2.0
    var selectedCursorName: String?   // matched by name on load

    // Audio
    var recordAudio: Bool?
    var audioSource: String?       // "system", "microphone", "both"
    var systemVolume: CGFloat?     // 0...1
    var micVolume: CGFloat?        // 0...1

    // Click sounds
    var clickSoundEnabled: Bool?
    var clickSoundStyle: String?   // ClickSoundStyle rawValue
    var clickSoundVolume: CGFloat? // 0...1

    // Zoom sounds
    var zoomSoundEnabled: Bool?
    var zoomSoundVolume: CGFloat?  // 0...1

    // UI
    var selectedTab: Int
    var inspectorCollapsed: Bool

    static let fileName = "editor_state.json"
}
