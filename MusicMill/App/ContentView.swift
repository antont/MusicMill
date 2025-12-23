import SwiftUI

struct ContentView: View {
    @EnvironmentObject var modelManager: ModelManager
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            PhrasePerformanceView()
                .tabItem {
                    Label("Phrase", systemImage: "music.note.list")
                }
                .tag(0)
            
            GranularPerformanceView()
                .tabItem {
                    Label("Granular", systemImage: "waveform.path")
                }
                .tag(1)
            
            RAVEView()
                .tabItem {
                    Label("RAVE", systemImage: "waveform")
                }
                .tag(2)
            
            TrainingView()
                .tabItem {
                    Label("Training", systemImage: "brain")
                }
                .tag(3)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
