# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MyScreenStudio is a macOS screen recording application built with SwiftUI and ScreenCaptureKit. It provides an intuitive interface for recording full screens, specific windows, or custom areas with real-time video effects and professional export options.

## Development Commands

### Build and Run
```bash
# Open project in Xcode
open MyScreenStudio.xcodeproj

# Build from command line (requires xcodebuild)
xcodebuild -project MyScreenStudio.xcodeproj -scheme MyScreenStudio build

# Run from Xcode using Cmd+R or Product > Run
```

### Testing
```bash
# Run tests from command line
xcodebuild test -project MyScreenStudio.xcodeproj -scheme MyScreenStudio -destination 'platform=macOS'

# Run tests from Xcode using Cmd+U or Product > Test
```

## Architecture Overview

### Core Components

**ScreenRecorder** (`ScreenRecorder.swift`): The central recording engine that manages:
- Display and window discovery via ScreenCaptureKit
- Recording state management (start/stop/pause/resume)
- Multiple recording modes (full screen, window, custom area)
- Audio capture configuration
- Timer-based duration tracking

**CaptureEngineStreamOutput** (`ScreenRecorder.swift:255-364`): Handles video stream processing:
- AVAssetWriter configuration for H.264/AAC encoding
- Real-time sample buffer processing
- Output file management in temporary directory
- Bitrate and quality settings (6Mbps video, 128kbps audio)

**VideoEffectsProcessor** (`VideoEffectsProcessor.swift`): Real-time video enhancement:
- Cursor tracking with smoothing algorithms
- Dynamic zoom with cursor following
- Background blur and motion blur effects
- CoreImage filter pipeline

### UI Architecture

**ContentView** (`ContentView.swift`): Main application interface using NavigationSplitView:
- Sidebar with display list and recent recordings
- Detail view with recording controls and status
- Sheet presentations for source picker and video preview

**RecordingSourcePicker** (`RecordingSourcePicker.swift`): Multi-mode source selection:
- Tabbed interface (Screen/Window/Area selection)
- Live window thumbnails using CGWindowListCreateImage
- Real-time display discovery and filtering

**VideoPreviewView** (`VideoPreviewView.swift`): Post-recording review interface:
- AVPlayer integration with custom controls
- Export options and file management
- QuickTime integration for external playback

**SettingsView** (`SettingsView.swift`): Preferences interface with @AppStorage:
- Video quality and frame rate settings
- Audio capture configuration (system/microphone)
- Visual effects parameters (zoom, cursor smoothing)
- Keyboard shortcuts configuration

### Key Dependencies

- **ScreenCaptureKit**: Modern macOS screen capture (requires macOS 12.3+)
- **AVFoundation**: Video encoding, playback, and audio processing
- **CoreImage**: Real-time video effects and filtering
- **SwiftData**: Data persistence (Item.swift model currently unused)
- **AppKit**: System integration (NSWorkspace, NSScreen, CGWindowList)

## Code Patterns

### State Management
- Uses @ObservedObject pattern for ScreenRecorder shared across views
- @Published properties for reactive UI updates
- @AppStorage for persistent user preferences
- @State for local view state and temporary selections

### Async/Await Usage
- All ScreenCaptureKit operations use async/await
- Recording start/stop operations are properly awaited
- Permission requests and content discovery are asynchronous

### Error Handling
- Print statements for debugging (not production-ready)
- Basic do-catch blocks around ScreenCaptureKit operations
- File system operations should be enhanced with proper error handling

### Memory Management
- @MainActor annotations for UI-bound classes
- Proper timer invalidation to prevent retain cycles
- AVPlayer cleanup in onDisappear handlers

## Recording Workflow

1. **Permission Request**: App requests ScreenCaptureKit permissions on launch
2. **Content Discovery**: Queries available displays and windows
3. **Source Selection**: User chooses recording mode and target
4. **Stream Configuration**: Sets up SCStream with appropriate filters and settings
5. **Output Setup**: Configures AVAssetWriter with video/audio inputs
6. **Recording**: Processes sample buffers through effects pipeline
7. **Completion**: Finalizes output file and updates UI state

## Recent Fixes & Status

### ✅ Fixed Issues
- **Recording functionality**: Core H.264 video recording now works correctly
- **ScreenCaptureKit integration**: Proper pixel buffer handling with BGRA format
- **Dimension handling**: Automatic adjustment to even numbers required by H.264
- **Window filtering**: Enhanced filtering to exclude system windows (Dock, OSDUIHelper, etc.)
- **Compilation warnings**: Fixed deprecated CGWindowListCreateImage and string interpolation issues
- **Project system**: Complete project-based workflow similar to ScreenStudio
- **Custom cursors**: Integration of custom cursor PNGs for professional recordings
- **Video backgrounds**: Professional wallpaper system with padding and effects controls

### 🚧 Current Limitations
- **Audio capture**: Temporarily disabled until proper implementation (ScreenRecorder.swift:348-357)
- **Area selection**: Uses placeholder implementation (ScreenRecorder.swift:76-81)
- **Video effects**: Not integrated into recording pipeline yet
- **Export functionality**: Basic file operations, no transcoding options
- **Error handling**: Relies on console logging rather than user notifications

### 📋 Recording Quality
- **Format**: H.264 video in .mov container
- **Resolution**: Matches source display/window resolution
- **Frame Rate**: 60 FPS target with adaptive bitrate
- **File Size**: ~1.7MB for short recordings (varies by content and duration)

## File Structure

```
MyScreenStudio/
├── MyScreenStudioApp.swift          # App entry point with WindowGroup
├── ContentView.swift                # Main UI with project/recording switching
├── ScreenRecorder.swift             # Core recording logic and stream output
├── RecordingSourcePicker.swift      # Source selection interface
├── RecordingProject.swift           # Project data model and ProjectManager
├── RecordingStudioView.swift        # Full studio editing interface
├── CustomCursor.swift               # Custom cursor management system
├── VideoPreviewView.swift           # Legacy preview (replaced by studio)
├── SettingsView.swift               # User preferences with cursor settings
├── VideoEffectsProcessor.swift      # Real-time video effects (not integrated)
├── Item.swift                       # SwiftData model (unused)
├── Resources/
│   ├── Cursors/                     # Custom cursor PNG files
│   │   ├── cursor.png               # Standard arrow cursor
│   │   ├── cursor (1).png           # Alternative arrow cursor  
│   │   └── hand (1).png             # Hand pointer cursor
│   └── Wallpapers/                  # Background wallpaper collection
│       ├── Abstract Shapes.jpg      # Abstract backgrounds
│       ├── Aurora.jpg               # Nature backgrounds
│       ├── Desert 6.jpg             # Landscape backgrounds
│       ├── hello-Blue-1-dragged.jpg # Gradient backgrounds
│       ├── Mojave Day.jpg           # macOS official wallpapers
│       ├── Ventura light.jpg        # System backgrounds
│       └── [30+ additional wallpapers]
├── Assets.xcassets/                 # App icons and resources
└── Info.plist                       # App configuration and entitlements
```

## Custom Cursor System

### **CursorManager Features:**
- **Automatic cursor loading**: Scans Resources/Cursors/ directory for PNG files
- **Hot spot configuration**: Intelligent hot spot positioning based on cursor type
- **Recording integration**: Applies custom cursors during screen recording
- **User preferences**: Settings panel for cursor selection and enable/disable
- **Real-time preview**: Visual cursor selection with preview thumbnails

### **Available Cursors:**
1. **System Default** - Standard macOS cursor
2. **Custom Arrow** - Professional arrow cursor (cursor.png)  
3. **Rounded Arrow** - Smooth rounded arrow (cursor (1).png)
4. **Hand Pointer** - Click/selection hand (hand (1).png)

### **Usage:**
- **Settings > Cursor tab**: Configure cursor preferences
- **Studio > Effects tab**: Quick cursor settings during editing
- **Recording**: Custom cursor appears in recorded video automatically

## Video Background System

### **BackgroundManager Features:**
- **Professional wallpaper library**: 30+ high-quality backgrounds across 5 categories
- **Smart categorization**: Gradients, Nature, Abstract, Minimal, and Dynamic collections
- **Real-time preview**: Visual background selection with thumbnails
- **Flexible padding control**: Adjustable margins around window content (0-200px)
- **Visual effects**: Corner radius, drop shadows, and scaling options
- **Window-specific**: Backgrounds apply only to window recordings for professional look

### **Background Categories:**
1. **None** - Transparent background (default)
2. **Gradients** - Colorful gradient backgrounds (hello-* series)
3. **Nature** - Landscapes, mountains, desert scenes
4. **Abstract** - Artistic and geometric patterns
5. **Minimal** - Clean, professional backgrounds
6. **Dynamic** - macOS system wallpapers with depth

### **Background Settings:**
- **Padding**: 0-200px spacing around recorded window
- **Corner Radius**: 0-50px rounded corners for modern look
- **Drop Shadow**: Configurable shadow with opacity and blur
- **Scale to Fit**: Automatic background scaling to match video dimensions

### **Usage:**
- **Settings > Background tab**: Main background configuration
- **Studio > Effects > Background**: Quick settings during editing
- **Window Recording**: Backgrounds automatically applied with padding
- **Real-time Preview**: See changes instantly in the studio interface