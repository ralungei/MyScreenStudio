import Foundation
import ScreenCaptureKit
import AVFoundation
import Combine

enum RecordingMode {
    case fullScreen
    case window
    case area
}

@MainActor
class ScreenRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var availableDisplays: [SCDisplay] = []
    @Published var availableWindows: [SCWindow] = []
    @Published var selectedDisplay: SCDisplay?
    @Published var selectedWindow: SCWindow?
    @Published var selectedArea: CGRect?
    @Published var recordingURL: URL?
    @Published var currentProject: RecordingProject?
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingMode: RecordingMode = .fullScreen
    @Published var recordAudio = true
    @Published var showMouseClicks = true
    
    let cursorManager = CursorManager()
    let backgroundManager = BackgroundManager()
    let mouseTracker = MouseTracker()
    
    private var stream: SCStream?
    private var streamOutput: CaptureEngineStreamOutput?
    private var startTime: Date?
    private var timer: Timer?
    
    override init() {
        super.init()
        Task {
            await requestPermissions()
            await refreshAvailableContent()
        }
    }
    
    func requestPermissions() async {
        do {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("Failed to get permissions: \(error)")
        }
    }
    
    func refreshAvailableContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            availableDisplays = content.displays
            availableWindows = content.windows.filter { window in
                // Filter out small windows, system windows, and other non-recordable windows
                guard window.frame.width > 100 && window.frame.height > 100 else { return false }
                
                // Filter out system applications and processes that shouldn't be recorded
                if let appName = window.owningApplication?.applicationName.lowercased() {
                    let systemApps = [
                        "dock", "finder", "desktop", "wallpaper", "screensaver",
                        "osduihelper", "spotlight", "siri", "controlcenter",
                        "notificationcenter", "menubar", "menuextra",
                        "windowserver", "loginwindow", "securityagent",
                        "coreauthui", "coreservicesuiagent", "usernotificationcenter",
                        "systemuiserver", "applespell", "keychain", "talagent"
                    ]
                    
                    if systemApps.contains(where: appName.contains) {
                        return false
                    }
                }
                
                // Filter out windows with no title or very generic titles
                if let title = window.title {
                    let lowercaseTitle = title.lowercased()
                    let invalidTitles = [
                        "desktop", "wallpaper", "", " ", "item-0", "window",
                        "untitled", "dock", "menubar"
                    ]
                    
                    if invalidTitles.contains(lowercaseTitle) || lowercaseTitle.isEmpty {
                        return false
                    }
                }
                
                // Only include windows that are likely to be actual app windows
                return window.isOnScreen && window.windowLayer == 0
            }
            
            if selectedDisplay == nil {
                selectedDisplay = availableDisplays.first
            }
        } catch {
            print("Failed to get available content: \(error)")
        }
    }
    
    var hasValidSelection: Bool {
        switch recordingMode {
        case .fullScreen:
            return selectedDisplay != nil
        case .window:
            return selectedWindow != nil
        case .area:
            return selectedArea != nil
        }
    }
    
    func startAreaSelection() {
        // This would trigger a native area selection UI
        // For now, we'll simulate with a default area
        selectedArea = CGRect(x: 100, y: 100, width: 800, height: 600)
        recordingMode = .area
    }
    
    func startRecordingWithCurrentSelection() async {
        print("🎬 START RECORDING WITH MODE: \(recordingMode)")
        switch recordingMode {
        case .fullScreen:
            print("   → Starting FULL SCREEN recording")
            await startRecording()
        case .window:
            print("   → Starting WINDOW recording")
            print("   → Selected window: \(selectedWindow?.title ?? "None")")
            await startWindowRecording()
        case .area:
            print("   → Starting AREA recording")
            await startAreaRecording()
        }
    }
    
    func startWindowRecording() async {
        guard !isRecording, let window = selectedWindow else { return }
        
        do {
            // Log detailed window information for debugging
            print("🔍 WINDOW ANALYSIS:")
            print("   Window title: \(window.title ?? "No title")")
            print("   Window frame: \(window.frame)")
            print("   Window size: \(window.frame.width) x \(window.frame.height)")
            print("   Window app: \(window.owningApplication?.applicationName ?? "Unknown")")
            
            // Focus the selected window before starting recording
            if let owningApp = window.owningApplication {
                let bundleIdentifier = owningApp.bundleIdentifier
                print("🎯 Focusing window of app: \(owningApp.applicationName)")
                
                // Use NSWorkspace to activate the app by bundle identifier
                let workspace = NSWorkspace.shared
                if let runningApp = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
                    // Activate the app to bring it to front
                    runningApp.activate()
                    
                    // Small delay to ensure app activation completes
                    try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                    
                    print("✅ App activated: \(owningApp.applicationName)")
                } else {
                    print("⚠️ Could not find running app with bundle ID: \(bundleIdentifier)")
                }
            }
            
            // Get the display that contains this window
            guard let display = availableDisplays.first(where: { display in
                display.frame.intersects(window.frame)
            }) else {
                print("❌ Could not find display for window")
                return
            }
            
            print("🔍 DISPLAY INFO:")
            print("   Display frame: \(display.frame)")
            print("   Display size: \(display.width) x \(display.height)")
            
            // Use desktopIndependentWindow for precise window capture
            let filter = SCContentFilter(desktopIndependentWindow: window)
            
            let configuration = SCStreamConfiguration()
            
            // CRITICAL: Set explicit dimensions to match the window exactly
            let windowWidth = Int(window.frame.width)
            let windowHeight = Int(window.frame.height)
            
            // Ensure dimensions are even (required for H.264)
            let adjustedWidth = windowWidth % 2 == 0 ? windowWidth : windowWidth - 1
            let adjustedHeight = windowHeight % 2 == 0 ? windowHeight : windowHeight - 1
            
            print("🔧 CONFIGURATION:")
            print("   Window dimensions: \(windowWidth) x \(windowHeight)")
            print("   Adjusted for H.264: \(adjustedWidth) x \(adjustedHeight)")
            print("   Window frame in display: \(window.frame)")
            
            // Configure exact window dimensions
            configuration.width = adjustedWidth
            configuration.height = adjustedHeight
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 5
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            
            // Use automatic capture resolution for best quality
            configuration.captureResolution = .automatic
            
            // IMPORTANT: Set scalesToFit to false to prevent scaling
            configuration.scalesToFit = false
            
            // Disable preserving aspect ratio to capture exact window content
            configuration.preservesAspectRatio = false
            
            print("🎯 Configuration complete - capturing window at \(adjustedWidth)x\(adjustedHeight)")
            
            streamOutput = CaptureEngineStreamOutput(
                width: adjustedWidth, // Use exact window dimensions
                height: adjustedHeight,
                backgroundManager: backgroundManager,
                recordingMode: .window
            )
            
            stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            
            try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .main)
            
            try await stream?.startCapture()
            
            // Apply custom cursor for recording
            cursorManager.setCursorForRecording()
            
            // Start mouse tracking for window recording
            mouseTracker.startTracking(windowFrame: window.frame)
            
            // Optionally minimize MyScreenStudio to get out of the way
            // Only do this if we're not recording MyScreenStudio itself
            if let appName = window.owningApplication?.applicationName,
               !appName.contains("MyScreenStudio") {
                // Minimize all MyScreenStudio windows except Dynamic Island (small window)
                await MainActor.run {
                    for window in NSApplication.shared.windows {
                        // Don't minimize the Dynamic Island (small window < 500px width)
                        if window.frame.width >= 500 {
                            window.miniaturize(nil)
                        }
                    }
                }
                print("🎬 MyScreenStudio minimized to avoid interfering with recording")
            }
            
            isRecording = true
            startTime = Date()
            
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    if let start = self?.startTime {
                        self?.recordingDuration = Date().timeIntervalSince(start)
                    }
                }
            }
            
        } catch {
            print("Failed to start window recording: \(error)")
        }
    }
    
    func startAreaRecording() async {
        guard !isRecording, let area = selectedArea, let display = selectedDisplay else { return }
        
        do {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = area
            configuration.width = Int(area.width) * 2
            configuration.height = Int(area.height) * 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 5
            
            streamOutput = CaptureEngineStreamOutput(
                width: Int(area.width) * 2, 
                height: Int(area.height) * 2,
                backgroundManager: backgroundManager,
                recordingMode: .area
            )
            
            stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            
            try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .main)
            
            try await stream?.startCapture()
            
            // Apply custom cursor for recording
            cursorManager.setCursorForRecording()
            
            // Start mouse tracking
            mouseTracker.startTracking(windowFrame: recordingMode == .window ? selectedWindow?.frame : selectedArea)
            
            isRecording = true
            startTime = Date()
            
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    if let start = self?.startTime {
                        self?.recordingDuration = Date().timeIntervalSince(start)
                    }
                }
            }
            
        } catch {
            print("Failed to start area recording: \(error)")
        }
    }
    
    func startRecording() async {
        guard !isRecording, let display = selectedDisplay else { return }
        
        do {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 5
            
            streamOutput = CaptureEngineStreamOutput(
                width: display.width, 
                height: display.height,
                backgroundManager: backgroundManager,
                recordingMode: .fullScreen
            )
            
            stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            
            try stream?.addStreamOutput(streamOutput!, type: .screen, sampleHandlerQueue: .main)
            
            // Audio configuration would go here if needed
            // Note: Audio capture requires additional setup
            
            try await stream?.startCapture()
            
            // Apply custom cursor for recording
            cursorManager.setCursorForRecording()
            
            // Start mouse tracking
            mouseTracker.startTracking(windowFrame: recordingMode == .window ? selectedWindow?.frame : selectedArea)
            
            isRecording = true
            startTime = Date()
            
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    if let start = self?.startTime {
                        self?.recordingDuration = Date().timeIntervalSince(start)
                    }
                }
            }
            
        } catch {
            print("Failed to start recording: \(error)")
        }
    }
    
    func pauseRecording() {
        isPaused = true
        timer?.invalidate()
    }
    
    func resumeRecording() {
        isPaused = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let start = self?.startTime {
                    self?.recordingDuration = Date().timeIntervalSince(start)
                }
            }
        }
    }
    
    func stopRecording() async {
        guard isRecording else { return }
        
        print("Stopping recording...")
        
        do {
            try await stream?.stopCapture()
        } catch {
            print("Error stopping capture: \(error)")
        }
        
        // Stop mouse tracking
        mouseTracker.stopTracking()
        
        isRecording = false
        isPaused = false
        timer?.invalidate()
        recordingDuration = 0
        
        if let output = streamOutput {
            recordingURL = await output.saveRecording()
            if let url = recordingURL {
                print("Recording saved to: \(url.path)")
                // Verify file exists
                if FileManager.default.fileExists(atPath: url.path) {
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    print("File exists, size: \(fileSize) bytes")
                    
                    // Create project from recording
                    await createProject(from: url)
                } else {
                    print("Warning: File does not exist at path")
                }
            } else {
                print("Failed to save recording")
            }
        }
    }
    
    private func createProject(from videoURL: URL) async {
        let settings = RecordingSettings(
            quality: .ultra,
            frameRate: 60,
            recordAudio: recordAudio,
            showMouseClicks: showMouseClicks,
            autoZoom: false,
            zoomIntensity: 1.5,
            cursorSize: 1.0,
            smoothCursor: true,
            smoothingIntensity: 0.5
        )
        
        let projectManager = ProjectManager()
        let project = projectManager.createProject(
            name: "Recording \(Date().formatted(date: .abbreviated, time: .shortened))",
            videoURL: videoURL,
            settings: settings
        )
        
        // Save mouse tracking data
        let projectDir = URL(fileURLWithPath: project.videoPath).deletingLastPathComponent()
        let mouseDataURL = projectDir.appendingPathComponent("mouse_data.json")
        
        do {
            try mouseTracker.saveMetadata(to: mouseDataURL)
            print("Saved mouse tracking data for project")
        } catch {
            print("Failed to save mouse tracking data: \(error)")
        }
        
        currentProject = project
        print("Created project: \(project.name)")
    }
}

class CaptureEngineStreamOutput: NSObject, SCStreamOutput {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var startTime: CMTime = .zero
    private let outputURL: URL
    private var videoWidth: Int
    private var videoHeight: Int
    private var sampleBufferCount = 0
    private var hasLoggedFormat = false
    private let backgroundManager: BackgroundManager?
    private let recordingMode: RecordingMode
    private let context = CIContext()
    
    init(width: Int, height: Int, backgroundManager: BackgroundManager? = nil, recordingMode: RecordingMode = .fullScreen) {
        // Create a temporary directory for recordings
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "Recording_\(Date().timeIntervalSince1970).mov"
        outputURL = tempDir.appendingPathComponent(fileName)
        
        self.backgroundManager = backgroundManager
        self.recordingMode = recordingMode
        
        // For window recording with dynamic dimensions, defer setup until first frame
        if width == 0 && height == 0 {
            videoWidth = 0
            videoHeight = 0
            print("Will save recording to: \(outputURL.path) - dimensions will be detected from first frame")
        } else {
            // Always record exact dimensions - padding/background applied only in playback
            // Ensure dimensions are even numbers (required for H.264)
            videoWidth = width % 2 == 0 ? width : width - 1
            videoHeight = height % 2 == 0 ? height : height - 1
            
            print("Will save recording to: \(outputURL.path)")
            if videoWidth != width || videoHeight != height {
                print("Video dimensions: \(videoWidth) x \(videoHeight) (adjusted from \(width) x \(height) for H.264)")
            } else {
                print("Video dimensions: \(videoWidth) x \(videoHeight)")
            }
        }
        
        super.init()
        
        // Setup asset writer after super.init() if dimensions are known
        if videoWidth > 0 && videoHeight > 0 {
            setupAssetWriter()
        }
    }
    
    private func setupAssetWriter() {
        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            
            // Use specific video settings that work better with ScreenCaptureKit
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: NSNumber(value: videoWidth * videoHeight * 4), // Dynamic bitrate
                    AVVideoExpectedSourceFrameRateKey: NSNumber(value: 60),
                    AVVideoMaxKeyFrameIntervalKey: NSNumber(value: 60)
                ]
            ]
            
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput?.expectsMediaDataInRealTime = true
            
            // Add pixel buffer adaptor specifically for ScreenCaptureKit
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: videoWidth,
                kCVPixelBufferHeightKey as String: videoHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput!,
                sourcePixelBufferAttributes: pixelBufferAttributes
            )
            
            // Audio input temporarily disabled until proper audio capture is implemented
            // let audioSettings: [String: Any] = [
            //     AVFormatIDKey: kAudioFormatMPEG4AAC,
            //     AVSampleRateKey: 48000,
            //     AVNumberOfChannelsKey: 2,
            //     AVEncoderBitRateKey: 128000
            // ]
            // 
            // audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            // audioInput?.expectsMediaDataInRealTime = true
            
            if let videoInput = videoInput {
                assetWriter?.add(videoInput)
            }
            
            // Audio input temporarily disabled
            // if let audioInput = audioInput {
            //     assetWriter?.add(audioInput)
            // }
            
        } catch {
            print("Failed to setup asset writer: \(error)")
        }
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { 
            print("Invalid sample buffer received")
            return 
        }
        
        if type == .screen && !hasLoggedFormat {
            // Log sample buffer details for debugging (only once)
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                let formatType = CVPixelBufferGetPixelFormatType(pixelBuffer)
                
                print("🔍 CAPTURE ANALYSIS:")
                print("   Expected dimensions (configured): \(videoWidth) x \(videoHeight)")
                print("   Actual buffer dimensions: \(width) x \(height)")
                print("   Recording mode: \(recordingMode)")
                
                // If dimensions weren't set (dynamic window recording), set them now
                if videoWidth == 0 && videoHeight == 0 {
                    videoWidth = width % 2 == 0 ? width : width - 1
                    videoHeight = height % 2 == 0 ? height : height - 1
                    print("   ⚠️  Using dynamic detection - adjusted to: \(videoWidth) x \(videoHeight)")
                    setupAssetWriter()
                } else {
                    // Check if actual capture matches our configuration
                    if width != videoWidth || height != videoHeight {
                        print("   ⚠️  MISMATCH DETECTED!")
                        print("   ⚠️  This is why we see black bars - ScreenCaptureKit is capturing \(width)x\(height)")
                        print("   ⚠️  But we configured it for \(videoWidth)x\(videoHeight)")
                    } else {
                        print("   ✅ Perfect match - no black bars expected")
                    }
                }
                
                print("First sample buffer: \(width)x\(height), format: \(formatType), expected: \(videoWidth)x\(videoHeight)")
                hasLoggedFormat = true
            }
        }
        
        if assetWriter?.status == .unknown {
            guard assetWriter?.startWriting() == true else {
                print("Failed to start writing: \(assetWriter?.error?.localizedDescription ?? "Unknown error")")
                return
            }
            let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            assetWriter?.startSession(atSourceTime: sourceTime)
            startTime = sourceTime
            print("Started recording session at time: \(sourceTime.seconds)")
        }
        
        guard assetWriter?.status == .writing else {
            if assetWriter?.status == .failed {
                print("Asset writer failed: \(assetWriter?.error?.localizedDescription ?? "Unknown error")")
            }
            return
        }
        
        switch type {
        case .screen:
            guard let pixelBufferAdaptor = pixelBufferAdaptor,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            
            // Only process if the input is ready - this is normal behavior
            guard pixelBufferAdaptor.assetWriterInput.isReadyForMoreMediaData else {
                return // Silently skip when not ready
            }
            
            sampleBufferCount += 1
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            // Apply background if enabled
            let processedBuffer = applyBackgroundIfNeeded(to: pixelBuffer)
            
            if pixelBufferAdaptor.append(processedBuffer, withPresentationTime: presentationTime) {
                if sampleBufferCount <= 10 || sampleBufferCount % 60 == 0 {
                    print("Successfully appended pixel buffer #\(sampleBufferCount)")
                }
            } else {
                print("Failed to append pixel buffer #\(sampleBufferCount)")
                if let error = assetWriter?.error {
                    print("Asset writer error after failed append: \(error)")
                }
            }
            
        case .audio, .microphone:
            // Audio temporarily disabled
            break
        @unknown default:
            break
        }
    }
    
    func saveRecording() async -> URL? {
        print("Saving recording to: \(outputURL.path)")
        
        videoInput?.markAsFinished()
        // audioInput?.markAsFinished() // Audio temporarily disabled
        
        await assetWriter?.finishWriting()
        
        print("Asset writer status: \(String(describing: assetWriter?.status.rawValue))")
        if let error = assetWriter?.error {
            print("Asset writer error: \(error)")
        }
        
        if assetWriter?.status == .completed {
            print("Recording completed successfully")
            // Reempaqueta para que Quick Look lo previsualice (moov al principio)
            if let fastStartURL = await fastStart(url: outputURL, fileType: .mov) {
                return fastStartURL
            }
            return outputURL
        }
        
        print("Recording failed with status: \(String(describing: assetWriter?.status))")
        return nil
    }
    
    private func applyBackgroundIfNeeded(to pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        guard recordingMode == .window else {
            return pixelBuffer
        }
        
        // Background and effects are now applied only in playback, not during recording
        // This ensures window recordings contain only the window content
        return pixelBuffer
        
        // Convert pixel buffer to CIImage
        /*let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Calculate canvas size with padding
        let canvasSize = CGSize(width: videoWidth, height: videoHeight)
        let windowFrame = inputImage.extent
        
        // Apply background
        let processedImage = backgroundManager.applyBackground(
            to: inputImage,
            windowFrame: windowFrame,
            canvasSize: canvasSize
        )*/
        
        // Convert back to pixel buffer
        /*guard let outputBuffer = createPixelBuffer(from: processedImage, size: canvasSize) else {
            print("Failed to create output pixel buffer")
            return pixelBuffer
        }
        
        return outputBuffer*/
    }
    
    private func createPixelBuffer(from image: CIImage, size: CGSize) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        context.render(image, to: buffer)
        return buffer
    }
    
    private func fastStart(url: URL, fileType: AVFileType) async -> URL? {
        let asset = AVAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return nil }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_faststart")
            .appendingPathExtension(url.pathExtension)
        try? FileManager.default.removeItem(at: tmp)
        export.outputURL = tmp
        export.outputFileType = fileType
        export.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { cont in
            export.exportAsynchronously { cont.resume() }
        }

        guard export.status == .completed else { return nil }
        // Sustituye el original por el "fast-start"
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmp, to: url)
        return url
    }
}