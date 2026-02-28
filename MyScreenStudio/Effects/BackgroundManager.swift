import Foundation
import SwiftUI
import AppKit
import Observation

// MARK: - Image Cache
final class BackgroundImageCache {
    static let shared = BackgroundImageCache()
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    func image(for path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[path] { return cached }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = img
        return img
    }
}

// MARK: - Background Model
struct VideoBackground: Identifiable, Codable, Equatable {
    var id = UUID()
    let name: String
    let imagePath: String
    let category: BackgroundCategory
    var isActive: Bool = false

    enum BackgroundCategory: String, Codable, CaseIterable {
        case none = "None"
        case gradients = "Gradients"
        case nature = "Nature"
        case abstract = "Abstract"
        case minimal = "Minimal"
        case dynamic = "Dynamic"

        var displayName: String { rawValue }
    }

    init(name: String, imagePath: String, category: BackgroundCategory = .minimal) {
        self.name = name
        self.imagePath = imagePath
        self.category = category
    }

    var nsImage: NSImage? {
        BackgroundImageCache.shared.image(for: imagePath)
    }
}

// MARK: - Background Settings
struct BackgroundSettings: Codable, Equatable {
    var selectedBackground: VideoBackground?
    var padding: CGFloat = 50.0 // Padding around the window
    var cornerRadius: CGFloat = 12.0 // Rounded corners for window
    var shadowEnabled: Bool = true
    var shadowOpacity: CGFloat = 0.3
    var shadowOffset: CGSize = CGSize(width: 0, height: 8)
    var shadowBlur: CGFloat = 20.0
    var scaleToFit: Bool = true
    
    static var `default`: BackgroundSettings {
        BackgroundSettings()
    }
}

// MARK: - Background Manager
@MainActor
@Observable
class BackgroundManager {
    var availableBackgrounds: [VideoBackground] = []
    var settings: BackgroundSettings = .default
    var isEnabled: Bool = true // Enabled by default
    
    private let wallpapersDirectory: URL
    
    init() {
        // Get the wallpapers directory from bundle resources
        let bundle = Bundle.main
        wallpapersDirectory = URL(fileURLWithPath: bundle.resourcePath ?? "")
        
        loadAvailableBackgrounds()
    }
    
    func loadAvailableBackgrounds() {
        availableBackgrounds.removeAll()

        // Add "None" option
        availableBackgrounds.append(VideoBackground(name: "None", imagePath: "", category: .none))

        let bundle = Bundle.main
        var allImageFiles: [URL] = []

        if let pngURLs = bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) {
            allImageFiles.append(contentsOf: pngURLs)
        }
        if let jpgURLs = bundle.urls(forResourcesWithExtension: "jpg", subdirectory: nil) {
            allImageFiles.append(contentsOf: jpgURLs)
        }
        if let jpegURLs = bundle.urls(forResourcesWithExtension: "jpeg", subdirectory: nil) {
            allImageFiles.append(contentsOf: jpegURLs)
        }

        let wallpaperFiles = allImageFiles.filter { url in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return !name.contains("cursor") && !name.contains("hand") && !name.contains("pointer")
        }

        for file in wallpaperFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.deletingPathExtension().lastPathComponent
            let category = categorizeBackground(name: name)
            let background = VideoBackground(
                name: formatBackgroundName(name),
                imagePath: file.path,
                category: category
            )
            availableBackgrounds.append(background)
        }

        // Auto-select the first gradient background by default (not None)
        if settings.selectedBackground == nil {
            let defaultBackground = availableBackgrounds.first { $0.category == .gradients } ??
                                   availableBackgrounds.first { !$0.imagePath.isEmpty } ??
                                   availableBackgrounds.first
            if let selected = defaultBackground {
                settings.selectedBackground = selected
            }
        }
    }
    
    private func categorizeBackground(name: String) -> VideoBackground.BackgroundCategory {
        let lowercaseName = name.lowercased()
        
        if lowercaseName.contains("gradient") || lowercaseName.contains("hello-") {
            return .gradients
        } else if lowercaseName.contains("mojave") || lowercaseName.contains("desert") || lowercaseName.contains("beach") || lowercaseName.contains("cliffs") || lowercaseName.contains("fuji") {
            return .nature
        } else if lowercaseName.contains("abstract") || lowercaseName.contains("aurora") {
            return .abstract
        } else if lowercaseName.contains("dynamic") || lowercaseName.contains("appearance") {
            return .dynamic
        } else {
            return .minimal
        }
    }
    
    private func formatBackgroundName(_ name: String) -> String {
        return name
            .replacingOccurrences(of: "-dragged", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
    
    func selectBackground(_ background: VideoBackground) {
        settings.selectedBackground = background
    }

    func updatePadding(_ padding: CGFloat) {
        settings.padding = padding
    }

    func updateCornerRadius(_ radius: CGFloat) {
        settings.cornerRadius = radius
    }

    func enableBackground(_ enabled: Bool) {
        isEnabled = enabled
    }
    
}

// MARK: - Background Preview View
struct BackgroundPreviewView: View {
    let background: VideoBackground
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )

            if background.imagePath.isEmpty {
                VStack(spacing: 2) {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("None")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            } else if let image = background.nsImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .cornerRadius(6)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .aspectRatio(1.3, contentMode: .fit)
        .onTapGesture {
            onSelect()
        }
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
    }
}

