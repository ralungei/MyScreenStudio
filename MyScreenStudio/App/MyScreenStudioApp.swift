//
//  MyScreenStudioApp.swift
//  MyScreenStudio
//
//  Created by Ras Alungei on 10/8/25.
//

import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var configuredWindows: Set<ObjectIdentifier> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureAllWindows()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }

    @objc func windowDidBecomeMain(notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let id = ObjectIdentifier(window)

        // Only configure each window once to avoid triggering
        // constraint recalculation during layout passes.
        guard !configuredWindows.contains(id) else { return }
        configuredWindows.insert(id)

        // Defer to the next run-loop tick so the window finishes
        // its initial layout before we touch its properties.
        DispatchQueue.main.async { [weak self] in
            self?.configureWindow(window)
        }
    }

    private func configureWindow(_ window: NSWindow) {
        if window.frame.width < 500 {
            // Dynamic Island — transparent, no title bar, draggable
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
        // Editor windows use .hiddenTitleBar — traffic lights visible by default.
    }

    func configureAllWindows() {
        for window in NSApplication.shared.windows {
            let id = ObjectIdentifier(window)
            guard !configuredWindows.contains(id) else { continue }
            configuredWindows.insert(id)
            configureWindow(window)
        }
    }
}

@main
struct MyScreenStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var projectManager = ProjectManager()

    var body: some Scene {
        WindowGroup("main") {
            DynamicIslandBar(projectManager: projectManager)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 80)

        WindowGroup(for: UUID.self) { $projectId in
            if let projectId = projectId,
               let project = projectManager.availableProjects.first(where: { $0.id == projectId }) {
                VideoEditorView(project: project, projectManager: projectManager)
            } else {
                EmptyView()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)


        Settings {
            SettingsView()
        }
    }
}
