import Foundation
import SwiftUI
import AppKit
import CoreImage

// MARK: - Background Model
struct VideoBackground: Identifiable, Codable {
    let id = UUID()
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
        if imagePath.isEmpty { return nil }
        return NSImage(contentsOfFile: imagePath)
    }
    
    var ciImage: CIImage? {
        guard let nsImage = nsImage else { return nil }
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return CIImage(cgImage: cgImage)
    }
}

// MARK: - Background Settings
struct BackgroundSettings: Codable {
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
class BackgroundManager: ObservableObject {
    @Published var availableBackgrounds: [VideoBackground] = []
    @Published var settings: BackgroundSettings = .default
    @Published var isEnabled: Bool = true // Enabled by default
    
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
        
        // Load custom backgrounds from bundle
        let bundle = Bundle.main
        print("🔍 Searching for wallpaper files in bundle")
        
        var allImageFiles: [URL] = []
        
        // Get PNG files
        if let pngURLs = bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) {
            allImageFiles.append(contentsOf: pngURLs)
        }
        
        // Get JPG files
        if let jpgURLs = bundle.urls(forResourcesWithExtension: "jpg", subdirectory: nil) {
            allImageFiles.append(contentsOf: jpgURLs)
        }
        
        // Get JPEG files
        if let jpegURLs = bundle.urls(forResourcesWithExtension: "jpeg", subdirectory: nil) {
            allImageFiles.append(contentsOf: jpegURLs)
        }
        
        // Filter out cursor files (keep only wallpapers)
        let wallpaperFiles = allImageFiles.filter { url in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return !name.contains("cursor") && !name.contains("hand") && !name.contains("pointer")
        }
        
        print("🖼️ Found \(wallpaperFiles.count) wallpaper files in bundle")
        
        for file in wallpaperFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.deletingPathExtension().lastPathComponent
            let category = categorizeBackground(name: name)
            
            print("➕ Adding wallpaper: \(name) (\(category.rawValue))")
            let background = VideoBackground(
                name: formatBackgroundName(name),
                imagePath: file.path,
                category: category
            )
            availableBackgrounds.append(background)
        }
        
        print("Loaded \(availableBackgrounds.count) backgrounds from: \(wallpapersDirectory.path)")
        for bg in availableBackgrounds.prefix(3) {
            print("  - \(bg.name) (\(bg.category.rawValue)): \(bg.imagePath)")
        }
        
        // Auto-select the first gradient background by default (not None)
        if settings.selectedBackground == nil {
            let defaultBackground = availableBackgrounds.first { $0.category == .gradients } ?? 
                                   availableBackgrounds.first { !$0.imagePath.isEmpty } ??
                                   availableBackgrounds.first
            if let selected = defaultBackground {
                settings.selectedBackground = selected
                print("🎯 Auto-selected background: \(selected.name) (\(selected.category.rawValue))")
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
        objectWillChange.send()
        print("🎨 Selected background: \(background.name)")
    }
    
    func updatePadding(_ padding: CGFloat) {
        settings.padding = padding
        objectWillChange.send()
    }
    
    func updateCornerRadius(_ radius: CGFloat) {
        settings.cornerRadius = radius
        objectWillChange.send()
    }
    
    func enableBackground(_ enabled: Bool) {
        isEnabled = enabled
        objectWillChange.send()
        print("🎨 Background enabled: \(enabled)")
    }
    
    // MARK: - Background Application
    func applyBackground(to windowImage: CIImage, windowFrame: CGRect, canvasSize: CGSize) -> CIImage {
        guard isEnabled, 
              let background = settings.selectedBackground,
              let backgroundImage = background.ciImage else {
            return windowImage
        }
        
        // Create canvas
        var canvas = backgroundImage
        
        // Scale background to fit canvas
        if settings.scaleToFit {
            let scaleX = canvasSize.width / backgroundImage.extent.width
            let scaleY = canvasSize.height / backgroundImage.extent.height
            let scale = max(scaleX, scaleY) // Scale to fill
            
            canvas = canvas.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            
            // Center the scaled image
            let centerX = (canvasSize.width - canvas.extent.width) / 2
            let centerY = (canvasSize.height - canvas.extent.height) / 2
            canvas = canvas.transformed(by: CGAffineTransform(translationX: centerX, y: centerY))
        }
        
        // Create window with rounded corners if needed
        var processedWindow = windowImage
        if settings.cornerRadius > 0 {
            processedWindow = applyRoundedCorners(to: processedWindow, radius: settings.cornerRadius)
        }
        
        // Add shadow if enabled
        if settings.shadowEnabled {
            processedWindow = applyShadow(to: processedWindow)
        }
        
        // Calculate window position with padding
        let windowWidth = windowImage.extent.width
        let windowHeight = windowImage.extent.height
        let padding = settings.padding
        
        let windowX = (canvasSize.width - windowWidth) / 2
        let windowY = (canvasSize.height - windowHeight) / 2
        
        // Position window on canvas
        processedWindow = processedWindow.transformed(by: CGAffineTransform(translationX: windowX, y: windowY))
        
        // Composite window over background
        return processedWindow.composited(over: canvas)
    }
    
    private func applyRoundedCorners(to image: CIImage, radius: CGFloat) -> CIImage {
        // Create a rounded rectangle mask
        let extent = image.extent
        
        // This is a simplified version - in practice, you'd use Core Graphics to create a rounded mask
        // For now, return the original image
        return image
    }
    
    private func applyShadow(to image: CIImage) -> CIImage {
        // Apply drop shadow
        guard let shadowFilter = CIFilter(name: "CIDropShadow") else { return image }
        
        shadowFilter.setValue(image, forKey: kCIInputImageKey)
        shadowFilter.setValue(settings.shadowOffset.width, forKey: "inputOffset")
        shadowFilter.setValue(settings.shadowBlur, forKey: "inputRadius")
        shadowFilter.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: settings.shadowOpacity), forKey: "inputColor")
        
        return shadowFilter.outputImage ?? image
    }
}

// MARK: - Background Preview View
struct BackgroundPreviewView: View {
    let background: VideoBackground
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 65, height: 42)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                
                if background.imagePath.isEmpty {
                    // None option
                    VStack {
                        Image(systemName: "slash.circle")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("None")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else if let image = background.nsImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 65, height: 42)
                        .clipped()
                        .cornerRadius(8)
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            
        }
        .onTapGesture {
            onSelect()
        }
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isSelected)
    }
}

// MARK: - Background Settings View
struct BackgroundSettingsView: View {
    @StateObject private var backgroundManager = BackgroundManager()
    @State private var selectedCategory: VideoBackground.BackgroundCategory = .minimal
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Video Background")
                    .font(.headline)
                Spacer()
                Text("\(backgroundManager.availableBackgrounds.count) fondos")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Toggle("Enable Background", isOn: $backgroundManager.isEnabled)
                .onChange(of: backgroundManager.isEnabled) { enabled in
                    backgroundManager.enableBackground(enabled)
                }
            
            if backgroundManager.isEnabled {
                // Category selector
                Picker("Category", selection: $selectedCategory) {
                    ForEach(VideoBackground.BackgroundCategory.allCases, id: \.self) { category in
                        Text(category.displayName).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 8)
                
                // Background grid
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 120))
                    ], spacing: 12) {
                        ForEach(filteredBackgrounds) { background in
                            BackgroundPreviewView(
                                background: background,
                                isSelected: backgroundManager.settings.selectedBackground?.id == background.id,
                                onSelect: {
                                    backgroundManager.selectBackground(background)
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 200)
                
                Divider()
                
                // Settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Appearance")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    VStack(spacing: 16) {
                        ModernSlider("Padding", value: $backgroundManager.settings.padding, range: 0...200, step: 5)
                        
                        ModernSlider("Corners", value: $backgroundManager.settings.cornerRadius, range: 0...50, step: 1)
                    }
                    
                    Toggle("Drop Shadow", isOn: $backgroundManager.settings.shadowEnabled)
                    
                    if backgroundManager.settings.shadowEnabled {
                        HStack {
                            Text("Shadow:")
                                .frame(width: 80, alignment: .leading)
                            Slider(value: $backgroundManager.settings.shadowOpacity, in: 0...1, step: 0.1)
                            Text("\(Int(backgroundManager.settings.shadowOpacity * 100))%")
                                .frame(width: 45)
                                .font(.caption)
                        }
                        .padding(.leading, 20)
                    }
                }
            }
            
            Spacer()
        }
        .padding()
    }
    
    private var filteredBackgrounds: [VideoBackground] {
        if selectedCategory == .none {
            return backgroundManager.availableBackgrounds.filter { $0.category == .none }
        }
        return backgroundManager.availableBackgrounds.filter { $0.category == selectedCategory }
    }
}