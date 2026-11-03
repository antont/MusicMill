import SwiftUI

@main
struct MusicMillApp: App {
    @StateObject private var modelManager = ModelManager()
    @StateObject private var trainingDataManager = TrainingDataManager()
    /// HyperMusic audio engine, session and output routing, for the app's lifetime.
    @State private var appAudio = AppAudio()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(modelManager)
                .environmentObject(trainingDataManager)
                .environment(appAudio)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
    }
}

