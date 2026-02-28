import SwiftUI

struct ContentView: View {
    @State private var projectManager = ProjectManager()

    var body: some View {
        Group {
            if let project = projectManager.currentProject {
                VideoEditorView(project: project, projectManager: projectManager)
            } else {
                DynamicIslandBar(projectManager: projectManager)
            }
        }
    }
}

#Preview {
    ContentView()
}
