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
            
            DJMixerView()
                .tabItem {
                    Label("DJ Mixer", systemImage: "slider.horizontal.3")
                }
                .tag(1)
            
            PreparationView()
                .tabItem {
                    Label("Prep", systemImage: "pencil.and.list.clipboard")
                }
                .tag(2)
            
            PhrasePerformanceView()
                .tabItem {
                    Label("Phrase", systemImage: "music.note.list")
                }
                .tag(3)
            
            GranularPerformanceView()
                .tabItem {
                    Label("Granular", systemImage: "waveform.path")
                }
                .tag(4)
            
            RAVEView()
                .tabItem {
                    Label("RAVE", systemImage: "waveform")
                }
                .tag(5)
            
            TrainingView()
                .tabItem {
                    Label("Training", systemImage: "brain")
                }
                .tag(6)
        }
        .frame(minWidth: 1000, minHeight: 700)
    }
}
