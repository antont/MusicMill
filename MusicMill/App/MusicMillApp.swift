import SwiftUI

@main
struct MusicMillApp: App {
    @StateObject private var modelManager = ModelManager()
    @StateObject private var trainingDataManager = TrainingDataManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(modelManager)
                .environmentObject(trainingDataManager)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
    }
}

