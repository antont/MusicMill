import Foundation
import AVFoundation
import Combine
import CoreAudio

/// Audio output device information
struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let hasOutput: Bool
    let channelCount: Int
    
    var displayName: String {
        "\(name) (\(channelCount)ch)"
    }
}

/// Output type for routing
enum AudioOutput {
    case main
    case cue
}

/// AudioRouter manages dual audio engines for DJ-style cue monitoring.
/// Main engine plays to speakers, cue engine plays to headphones.
class AudioRouter: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var availableDevices: [AudioDevice] = []
    @Published var mainOutputDeviceId: AudioDeviceID?
    @Published var cueOutputDeviceId: AudioDeviceID?
    @Published private(set) var isMainEngineRunning = false
    @Published private(set) var isCueEngineRunning = false
    
    /// Mix of cue output: 0 = main deck only, 1 = cue deck only
    @Published var cueMix: Float = 1.0
    
    // MARK: - Audio Engines
    
    let mainEngine = AVAudioEngine()
    let cueEngine = AVAudioEngine()
    
    // Mixer nodes for each engine
    private let mainMixer = AVAudioMixerNode()
    private let cueMixer = AVAudioMixerNode()
    
    // Source nodes for decks (to be connected)
    var mainDeckSourceNode: AVAudioSourceNode?
    var cueDeckSourceNode: AVAudioSourceNode?
    
    // MARK: - Properties
    
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var cancellables = Set<AnyCancellable>()
    
    let sampleRate: Double = 44100.0
    let channelCount: AVAudioChannelCount = 2
    
    // MARK: - Initialization
    
    init() {
        setupEngines()
        refreshDeviceList()
        setupDeviceChangeListener()
    }
    
    deinit {
        removeDeviceChangeListener()
        stopAll()
    }
    
    // MARK: - Setup
    
    private func setupEngines() {
        // Main engine setup
        mainEngine.attach(mainMixer)
        mainEngine.connect(mainMixer, to: mainEngine.mainMixerNode, format: standardFormat)
        
        // Cue engine setup
        cueEngine.attach(cueMixer)
        cueEngine.connect(cueMixer, to: cueEngine.mainMixerNode, format: standardFormat)
    }
    
    private var standardFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
    }
    
    // MARK: - Device Management
    
    /// Refresh the list of available audio output devices
    func refreshDeviceList() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard status == noErr else {
            print("AudioRouter: Failed to get device list size: \(status)")
            return
        }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIds = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIds
        )
        
        guard status == noErr else {
            print("AudioRouter: Failed to get device list: \(status)")
            return
        }
        
        var devices: [AudioDevice] = []
        
        for deviceId in deviceIds {
            if let device = getDeviceInfo(deviceId), device.hasOutput {
                devices.append(device)
            }
        }
        
        DispatchQueue.main.async {
            self.availableDevices = devices
            
            // Auto-select default devices if not set
            if self.mainOutputDeviceId == nil {
                self.mainOutputDeviceId = self.getDefaultOutputDevice()
            }
        }
    }
    
    private func getDeviceInfo(_ deviceId: AudioDeviceID) -> AudioDevice? {
        // Get device name
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        
        var status = AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &dataSize, &name)
        guard status == noErr else { return nil }
        
        // Get device UID
        propertyAddress.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        dataSize = UInt32(MemoryLayout<CFString>.size)
        
        status = AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &dataSize, &uid)
        guard status == noErr else { return nil }
        
        // Check if device has output
        propertyAddress.mSelector = kAudioDevicePropertyStreamConfiguration
        propertyAddress.mScope = kAudioDevicePropertyScopeOutput
        
        status = AudioObjectGetPropertyDataSize(deviceId, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else { return nil }
        
        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferListPointer.deallocate() }
        
        status = AudioObjectGetPropertyData(deviceId, &propertyAddress, 0, nil, &dataSize, bufferListPointer)
        guard status == noErr else { return nil }
        
        let bufferList = bufferListPointer.pointee
        let hasOutput = bufferList.mNumberBuffers > 0
        
        // Get channel count
        var channelCount = 0
        if hasOutput {
            let buffers = UnsafeBufferPointer(
                start: &bufferListPointer.pointee.mBuffers,
                count: Int(bufferList.mNumberBuffers)
            )
            for buffer in buffers {
                channelCount += Int(buffer.mNumberChannels)
            }
        }
        
        return AudioDevice(
            id: deviceId,
            name: name as String,
            uid: uid as String,
            hasOutput: hasOutput,
            channelCount: channelCount
        )
    }
    
    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceId: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceId
        )
        
        return status == noErr ? deviceId : nil
    }
    
    /// Set output device for an engine
    func setOutputDevice(_ deviceId: AudioDeviceID, for output: AudioOutput) {
        let engine = output == .main ? mainEngine : cueEngine
        
        // Stop engine if running
        let wasRunning = engine.isRunning
        if wasRunning {
            engine.stop()
        }
        
        // Get the audio unit
        guard let audioUnit = engine.outputNode.audioUnit else {
            print("AudioRouter: No audio unit available")
            return
        }
        
        // Set the device
        var deviceIdVar = deviceId
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIdVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        
        if status != noErr {
            print("AudioRouter: Failed to set output device: \(status)")
        }
        
        // Update published property
        DispatchQueue.main.async {
            if output == .main {
                self.mainOutputDeviceId = deviceId
            } else {
                self.cueOutputDeviceId = deviceId
            }
        }
        
        // Restart if was running
        if wasRunning {
            do {
                try engine.start()
            } catch {
                print("AudioRouter: Failed to restart engine: \(error)")
            }
        }
    }
    
    // MARK: - Device Change Listener
    
    private func setupDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        deviceListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDeviceList()
            }
        }
        
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            deviceListenerBlock!
        )
    }
    
    private func removeDeviceChangeListener() {
        guard let block = deviceListenerBlock else { return }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }
    
    // MARK: - Engine Control
    
    /// Start the main audio engine
    func startMainEngine() throws {
        guard !mainEngine.isRunning else { return }
        
        try mainEngine.start()
        
        DispatchQueue.main.async {
            self.isMainEngineRunning = true
        }
    }
    
    /// Start the cue audio engine
    func startCueEngine() throws {
        guard !cueEngine.isRunning else { return }
        
        try cueEngine.start()
        
        DispatchQueue.main.async {
            self.isCueEngineRunning = true
        }
    }
    
    /// Stop the main engine
    func stopMainEngine() {
        mainEngine.stop()
        
        DispatchQueue.main.async {
            self.isMainEngineRunning = false
        }
    }
    
    /// Stop the cue engine
    func stopCueEngine() {
        cueEngine.stop()
        
        DispatchQueue.main.async {
            self.isCueEngineRunning = false
        }
    }
    
    /// Stop all engines
    func stopAll() {
        stopMainEngine()
        stopCueEngine()
    }
    
    // MARK: - Deck Connection
    
    /// Connect a source node to the main deck
    func connectMainDeck(_ sourceNode: AVAudioSourceNode) {
        // Disconnect existing if any
        if let existing = mainDeckSourceNode {
            mainEngine.detach(existing)
        }
        
        mainEngine.attach(sourceNode)
        mainEngine.connect(sourceNode, to: mainMixer, format: standardFormat)
        mainDeckSourceNode = sourceNode
    }
    
    /// Connect a source node to the cue deck
    func connectCueDeck(_ sourceNode: AVAudioSourceNode) {
        // Disconnect existing if any
        if let existing = cueDeckSourceNode {
            cueEngine.detach(existing)
        }
        
        cueEngine.attach(sourceNode)
        cueEngine.connect(sourceNode, to: cueMixer, format: standardFormat)
        cueDeckSourceNode = sourceNode
    }
    
    /// Disconnect the main deck
    func disconnectMainDeck() {
        guard let node = mainDeckSourceNode else { return }
        mainEngine.detach(node)
        mainDeckSourceNode = nil
    }
    
    /// Disconnect the cue deck
    func disconnectCueDeck() {
        guard let node = cueDeckSourceNode else { return }
        cueEngine.detach(node)
        cueDeckSourceNode = nil
    }
    
    // MARK: - Volume Control
    
    /// Set main output volume (0-1)
    func setMainVolume(_ volume: Float) {
        mainEngine.mainMixerNode.outputVolume = max(0, min(1, volume))
    }
    
    /// Set cue output volume (0-1)
    func setCueVolume(_ volume: Float) {
        cueEngine.mainMixerNode.outputVolume = max(0, min(1, volume))
    }
}

