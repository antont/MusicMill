import Foundation
import AVFoundation
import Combine

/// Controls audio playback using AVFoundation
class PlaybackController: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var volume: Float = 1.0
    
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    
    /// Loads a track for playback
    func loadTrack(url: URL) {
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        
        // Clean up previous player
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        
        player = newPlayer
        playerItem = item
        
        // Observe duration
        item.publisher(for: \.duration)
            .sink { [weak self] duration in
                if duration.isValid {
                    self?.duration = CMTimeGetSeconds(duration)
                }
            }
            .store(in: &cancellables)
        
        // Observe time
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
        
        // Set volume
        newPlayer.volume = volume
    }
    
    /// Plays the current track
    func play() {
        player?.play()
        isPlaying = true
    }
    
    /// Pauses playback
    func pause() {
        player?.pause()
        isPlaying = false
    }
    
    /// Seeks to a specific time
    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime)
    }
    
    /// Sets volume (0.0 to 1.0)
    func setVolume(_ volume: Float) {
        self.volume = max(0.0, min(1.0, volume))
        player?.volume = self.volume
    }
    
    /// Sets a cue point
    func setCuePoint(at time: TimeInterval) {
        // Cue points would be stored separately
        // This is a placeholder for cue point functionality
    }
    
    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
    }
}



