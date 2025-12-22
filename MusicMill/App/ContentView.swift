import SwiftUI

struct ContentView: View {
    @EnvironmentObject var modelManager: ModelManager
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            TrainingView()
                .tabItem {
                    Label("Training", systemImage: "brain")
                }
                .tag(0)
            
            PerformanceView()
                .tabItem {
                    Label("Performance", systemImage: "music.note")
                }
                .tag(1)
            
            RAVEView()
                .tabItem {
                    Label("RAVE", systemImage: "waveform")
                }
                .tag(2)
        }
        .frame(minWidth: 1200, minHeight: 800)
    }
}

