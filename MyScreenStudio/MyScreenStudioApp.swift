//
//  MyScreenStudioApp.swift
//  MyScreenStudio
//
//  Created by Ras Alungei on 10/8/25.
//

import SwiftUI

@main
struct MyScreenStudioApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            SidebarCommands()
        }
        
        Settings {
            SettingsView()
        }
    }
}