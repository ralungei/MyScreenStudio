import Foundation
import SwiftUI
import Observation

// MARK: - Recording Project Model
@Observable
class RecordingProject: Codable, Identifiable {
    let id: UUID
    var name: String
    var createdAt: Date
    var lastModified: Date
    var duration: TimeInterval
    var videoPath: String // Path to the raw video file
    var thumbnailPath: String? // Path to thumbnail image
    var settings: RecordingSettings
    var effects: [VideoEffect]
    var exports: [ExportRecord]
    var mouseMetadata: CursorMetadata?
    
    init(name: String, videoPath: String, settings: RecordingSettings) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.lastModified = Date()
        self.duration = 0
        self.videoPath = videoPath
        self.settings = settings
        self.effects = []
        self.exports = []
    }
    
    func updateLastModified() {
        self.lastModified = Date()
    }
    
    // Load mouse tracking data for this project
    func loadMouseMetadata() {
        let projectDir = URL(fileURLWithPath: videoPath).deletingLastPathComponent()
        let mouseDataURL = projectDir.appendingPathComponent("mouse_data.json")
        
        do {
            let data = try Data(contentsOf: mouseDataURL)
            mouseMetadata = try JSONDecoder().decode(CursorMetadata.self, from: data)
            print("🖱️ Loaded mouse metadata for project: \(name) (\(mouseMetadata?.events.count ?? 0) events)")
        } catch {
            print("⚠️ Could not load mouse metadata for project: \(name) - \(error)")
            mouseMetadata = nil
        }
    }
    
    // MARK: - Editor State Persistence

    /// Directory containing the project files (alongside mouse_data.json, project.msstudio)
    var projectDirectory: URL {
        URL(fileURLWithPath: videoPath).deletingLastPathComponent()
    }

    func saveEditorState(_ state: EditorState) {
        let url = projectDirectory.appendingPathComponent(EditorState.fileName)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            print("⚠️ Failed to save editor state: \(error)")
        }
    }

    func loadEditorState() -> EditorState? {
        let url = projectDirectory.appendingPathComponent(EditorState.fileName)
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(EditorState.self, from: data)
        } catch {
            // No saved state yet — expected on first open
            return nil
        }
    }

    // MARK: - Codable Implementation
    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, lastModified, duration, videoPath, thumbnailPath, settings, effects, exports
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastModified = try container.decode(Date.self, forKey: .lastModified)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        videoPath = try container.decode(String.self, forKey: .videoPath)
        thumbnailPath = try container.decodeIfPresent(String.self, forKey: .thumbnailPath)
        settings = try container.decode(RecordingSettings.self, forKey: .settings)
        effects = try container.decode([VideoEffect].self, forKey: .effects)
        exports = try container.decode([ExportRecord].self, forKey: .exports)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastModified, forKey: .lastModified)
        try container.encode(duration, forKey: .duration)
        try container.encode(videoPath, forKey: .videoPath)
        try container.encode(thumbnailPath, forKey: .thumbnailPath)
        try container.encode(settings, forKey: .settings)
        try container.encode(effects, forKey: .effects)
        try container.encode(exports, forKey: .exports)
    }
}

// MARK: - Recording Settings
struct RecordingSettings: Codable {
    var quality: VideoQuality
    var frameRate: Int
    var recordAudio: Bool
    var showMouseClicks: Bool
    var autoZoom: Bool
    var zoomIntensity: Double
    var cursorSize: Double
    var smoothCursor: Bool
    var smoothingIntensity: Double
    
    static var `default`: RecordingSettings {
        RecordingSettings(
            quality: .high,
            frameRate: 60,
            recordAudio: true,
            showMouseClicks: true,
            autoZoom: false,
            zoomIntensity: 1.5,
            cursorSize: 1.0,
            smoothCursor: true,
            smoothingIntensity: 0.5
        )
    }
}

// MARK: - Video Effects
struct VideoEffect: Codable, Identifiable {
    let id: UUID
    var type: EffectType
    var startTime: TimeInterval
    var endTime: TimeInterval
    var parameters: [String: Double]
    var isEnabled: Bool
    
    init(type: EffectType, startTime: TimeInterval, endTime: TimeInterval, parameters: [String: Double] = [:], isEnabled: Bool = true) {
        self.id = UUID()
        self.type = type
        self.startTime = startTime
        self.endTime = endTime
        self.parameters = parameters
        self.isEnabled = isEnabled
    }
    
    enum EffectType: String, Codable, CaseIterable {
        case zoom = "zoom"
        case blur = "blur"
        case highlight = "highlight"
        case transition = "transition"
        case cursor = "cursor"
    }
}

// MARK: - Export Records
struct ExportRecord: Codable, Identifiable {
    let id: UUID
    let exportedAt: Date
    let outputPath: String
    let format: ExportFormat
    let quality: VideoQuality
    let fileSize: Int64
    
    init(exportedAt: Date, outputPath: String, format: ExportFormat, quality: VideoQuality, fileSize: Int64) {
        self.id = UUID()
        self.exportedAt = exportedAt
        self.outputPath = outputPath
        self.format = format
        self.quality = quality
        self.fileSize = fileSize
    }
    
    enum ExportFormat: String, Codable, CaseIterable {
        case mov = "mov"
        case mp4 = "mp4"
        case gif = "gif"
    }
}

// MARK: - Project Manager
@MainActor
@Observable
class ProjectManager {
    var currentProject: RecordingProject?
    var availableProjects: [RecordingProject] = []
    
    private let projectsDirectory: URL
    private let fileManager = FileManager.default
    
    init() {
        // Create projects directory in Documents
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        projectsDirectory = documentsPath.appendingPathComponent("MyScreenStudio Projects")
        
        createProjectsDirectory()
        loadAvailableProjects()
    }
    
    private func createProjectsDirectory() {
        if !fileManager.fileExists(atPath: projectsDirectory.path) {
            try? fileManager.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        }
    }
    
    func createProject(name: String, videoURL: URL, settings: RecordingSettings) -> RecordingProject {
        let projectName = name.isEmpty ? "Recording \(Date().timeIntervalSince1970)" : name
        
        // Create project first to get its ID
        let project = RecordingProject(
            name: projectName,
            videoPath: "", // Will be set after moving file
            settings: settings
        )
        
        // Use project ID for folder name consistency
        let projectFolder = projectsDirectory.appendingPathComponent("\(projectName)_\(project.id.uuidString)")
        
        // Create project folder
        try? fileManager.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        
        // Move video to project folder
        let videoDestination = projectFolder.appendingPathComponent("recording.mov")
        try? fileManager.moveItem(at: videoURL, to: videoDestination)
        
        // Update project with correct video path
        project.videoPath = videoDestination.path
        
        // Get video duration
        project.duration = getVideoDuration(url: videoDestination)
        
        // Save project
        saveProject(project, to: projectFolder)
        
        return project
    }
    
    func saveProject(_ project: RecordingProject, to folder: URL? = nil) {
        project.updateLastModified()
        
        let projectFolder = folder ?? getProjectFolder(for: project)
        let projectFile = projectFolder.appendingPathComponent("project.msstudio")
        
        print("💾 Saving project to: \(projectFile.path)")
        print("💾 Project folder exists: \(fileManager.fileExists(atPath: projectFolder.path))")
        
        do {
            // Ensure the project folder exists
            if !fileManager.fileExists(atPath: projectFolder.path) {
                try fileManager.createDirectory(at: projectFolder, withIntermediateDirectories: true, attributes: nil)
                print("💾 Created project folder: \(projectFolder.path)")
            }
            
            let data = try JSONEncoder().encode(project)
            try data.write(to: projectFile)
            print("💾 Successfully saved project file: \(projectFile.path)")
        } catch {
            print("❌ Failed to save project: \(error)")
            print("❌ Project folder path: \(projectFolder.path)")
            print("❌ Project file path: \(projectFile.path)")
        }
    }
    
    func loadProject(from folder: URL) -> RecordingProject? {
        let projectFile = folder.appendingPathComponent("project.msstudio")
        
        guard let data = try? Data(contentsOf: projectFile),
              let project = try? JSONDecoder().decode(RecordingProject.self, from: data) else {
            return nil
        }
        
        return project
    }
    
    func loadAvailableProjects() {
        availableProjects.removeAll()
        
        guard let contents = try? fileManager.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        
        for folder in contents {
            if let project = loadProject(from: folder) {
                availableProjects.append(project)
            }
        }
        
        // Sort by last modified date
        availableProjects.sort { $0.lastModified > $1.lastModified }
    }
    
    func openProject(_ project: RecordingProject) {
        currentProject = project
    }
    
    func closeProject() {
        if currentProject != nil {
            saveCurrentProject()
        }
        currentProject = nil
    }
    
    func saveCurrentProject() {
        guard let project = currentProject else { return }
        saveProject(project)
    }
    
    func deleteProject(_ project: RecordingProject) {
        let projectFolder = getProjectFolder(for: project)
        
        print("🗑️ Attempting to delete project at: \(projectFolder.path)")
        print("🗑️ Project ID: \(project.id)")
        print("🗑️ Available projects before deletion: \(availableProjects.count)")
        
        do {
            // Check if folder exists before trying to delete
            if fileManager.fileExists(atPath: projectFolder.path) {
                try fileManager.removeItem(at: projectFolder)
                print("🗑️ Successfully deleted folder: \(projectFolder.path)")
            } else {
                print("⚠️ Project folder not found at: \(projectFolder.path)")
            }
            
            // Remove from available projects list (this will trigger UI update)
            self.availableProjects.removeAll { $0.id == project.id }
            print("🗑️ Removed project from list. Available projects after deletion: \(self.availableProjects.count)")

            // Close project if it's currently open
            if self.currentProject?.id == project.id {
                self.currentProject = nil
                print("🗑️ Closed current project")
            }
            
            print("🗑️ Successfully deleted project: \(project.name)")
            
        } catch {
            print("❌ Failed to delete project folder: \(error)")
            // Even if folder deletion fails, remove from list
            availableProjects.removeAll { $0.id == project.id }
            if currentProject?.id == project.id {
                currentProject = nil
            }
        }
    }
    
    private func getProjectFolder(for project: RecordingProject) -> URL {
        let expectedFolder = projectsDirectory.appendingPathComponent("\(project.name)_\(project.id.uuidString)")
        
        // First try the expected folder name
        if fileManager.fileExists(atPath: expectedFolder.path) {
            return expectedFolder
        }
        
        // If not found, search for any folder with the same project name (for backwards compatibility)
        if let contents = try? fileManager.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil) {
            for folder in contents {
                let folderName = folder.lastPathComponent
                
                // Try exact project ID match first
                if folderName.contains(project.id.uuidString) {
                    print("🔍 Found project folder by ID: \(folder.path)")
                    return folder
                }
                
                // Try project name match (for old projects)
                if folderName.hasPrefix(project.name + "_") {
                    print("🔍 Found project folder by name: \(folder.path)")
                    return folder
                }
            }
        }
        
        print("🔍 No existing folder found, using expected path: \(expectedFolder.path)")
        // Fallback to expected folder name
        return expectedFolder
    }
    
    private func getVideoDuration(url: URL) -> TimeInterval {
        // This would use AVAsset to get duration
        // For now, return 0
        return 0
    }
}