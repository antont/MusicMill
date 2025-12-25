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
            
            PreparationView()
                .tabItem {
                    Label("Prep", systemImage: "pencil.and.list.clipboard")
                }
                .tag(1)
            
            PhrasePerformanceView()
                .tabItem {
                    Label("Phrase", systemImage: "music.note.list")
                }
                .tag(2)
            
            GranularPerformanceView()
                .tabItem {
                    Label("Granular", systemImage: "waveform.path")
                }
                .tag(3)
            
            RAVEView()
                .tabItem {
                    Label("RAVE", systemImage: "waveform")
                }
                .tag(4)
            
            TrainingView()
                .tabItem {
                    Label("Training", systemImage: "brain")
                }
                .tag(5)
        }
        .frame(minWidth: 1000, minHeight: 700)
    }
}
