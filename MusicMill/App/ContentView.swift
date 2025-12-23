import SwiftUI

struct ContentView: View {
    @EnvironmentObject var modelManager: ModelManager
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            HyperPhraseView()
                .tabItem {
                    Label("HyperMusic", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .tag(0)
            
            PhrasePerformanceView()
                .tabItem {
                    Label("Phrase", systemImage: "music.note.list")
                }
                .tag(1)
            
            GranularPerformanceView()
                .tabItem {
                    Label("Granular", systemImage: "waveform.path")
                }
                .tag(2)
            
            RAVEView()
                .tabItem {
                    Label("RAVE", systemImage: "waveform")
                }
                .tag(3)
            
            TrainingView()
                .tabItem {
                    Label("Training", systemImage: "brain")
                }
                .tag(4)
        }
        .frame(minWidth: 1000, minHeight: 700)
    }
}
