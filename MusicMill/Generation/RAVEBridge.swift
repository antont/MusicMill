import Foundation

/// Bridge between Swift and Python RAVE server via Unix socket
/// Manages server lifecycle and provides async audio generation
class RAVEBridge {
    
    // MARK: - Types
    
    struct Controls: Codable {
        var styleBlend: [String: Float]?
        var energy: Float
        var tempoFactor: Float
        var variation: Float
        
        enum CodingKeys: String, CodingKey {
            case styleBlend = "style_blend"
            case energy
            case tempoFactor = "tempo_factor"
            case variation
        }
        
        init(styleBlend: [String: Float]? = nil, energy: Float = 0.5,
             tempoFactor: Float = 1.0, variation: Float = 0.5) {
            self.styleBlend = styleBlend
            self.energy = energy
            self.tempoFactor = tempoFactor
            self.variation = variation
        }
    }
    
    struct GenerateRequest: Codable {
        let command: String
        let frames: Int
        let styleBlend: [String: Float]?
        let energy: Float
        let tempoFactor: Float
        let variation: Float
        
        enum CodingKeys: String, CodingKey {
            case command, frames
            case styleBlend = "style_blend"
            case energy
            case tempoFactor = "tempo_factor"
            case variation
        }
    }
    
    struct StylesResponse: Codable {
        let styles: [String]
    }
    
    enum BridgeError: LocalizedError {
        case serverNotRunning
        case connectionFailed(String)
        case communicationError(String)
        case invalidResponse
        case pythonNotFound
        case serverStartFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .serverNotRunning:
                return "RAVE server is not running"
            case .connectionFailed(let msg):
                return "Connection failed: \(msg)"
            case .communicationError(let msg):
                return "Communication error: \(msg)"
            case .invalidResponse:
                return "Invalid response from server"
            case .pythonNotFound:
                return "Python not found in RAVE venv"
            case .serverStartFailed(let msg):
                return "Failed to start server: \(msg)"
            }
        }
    }
    
    enum Status {
        case idle
        case starting
        case running
        case error(String)
    }
    
    // MARK: - Properties
    
    private let socketPath: String
    private(set) var modelName: String
    private var anchorsPath: String?
    
    private var serverProcess: Process?
    private var socket: Int32 = -1
    
    private let audioBufferLock = NSLock()
    private var audioBuffer: [Float] = []
    private var bufferReadPosition: Int = 0
    
    private let statusLock = NSLock()
    private var _status: Status = .idle
    
    var status: Status {
        statusLock.lock()
        defer { statusLock.unlock() }
        return _status
    }
    
    private var availableStyles: [String] = []
    
    private let scriptsPath: URL
    private let venvPath: URL
    
    // MARK: - Constants
    
    private let sampleRate: Double = 48000
    private let samplesPerFrame: Int = 2048
    private let bufferChunkFrames: Int = 50  // ~2 seconds of audio per request
    
    // MARK: - Initialization
    
    init(modelName: String = "percussion", anchorsPath: String? = nil) {
        self.modelName = modelName
        self.anchorsPath = anchorsPath
        self.socketPath = "/tmp/rave_server.sock"
        
        // Get paths
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.venvPath = documentsURL.appendingPathComponent("MusicMill/RAVE/venv")
        
        // Scripts are in the app bundle or workspace
        if let bundleScripts = Bundle.main.url(forResource: "scripts", withExtension: nil) {
            self.scriptsPath = bundleScripts
        } else {
            // Fallback to workspace location (for development)
            self.scriptsPath = URL(fileURLWithPath: "/Users/tonialatalo/src/MusicMill/scripts")
        }
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Model Discovery
    
    /// Gets list of available RAVE models from the pretrained directory
    static func getAvailableModels() -> [String] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let pretrainedDir = documentsURL.appendingPathComponent("MusicMill/RAVE/pretrained")
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: pretrainedDir, includingPropertiesForKeys: nil) else {
            return []
        }
        
        return files
            .filter { $0.pathExtension == "ts" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
    
    /// Switches to a different RAVE model (restarts server)
    func switchModel(to newModel: String) async throws {
        // Stop current server
        stop()
        
        // Update model name
        modelName = newModel
        
        // Clear buffers
        clearBuffer()
        
        // Start with new model
        try await start()
    }
    
    // MARK: - Server Lifecycle
    
    /// Starts the RAVE Python server
    func start() async throws {
        setStatus(.starting)
        
        // Check if server is already running
        if isServerRunning() {
            setStatus(.running)
            try await fetchStyles()
            return
        }
        
        // Check for venv
        let pythonPath = venvPath.appendingPathComponent("bin/python3")
        guard FileManager.default.fileExists(atPath: pythonPath.path) else {
            setStatus(.error("Python venv not found"))
            throw BridgeError.pythonNotFound
        }
        
        // Start server process
        let serverScript = scriptsPath.appendingPathComponent("rave_server.py")
        
        let process = Process()
        process.executableURL = pythonPath
        
        var args = [serverScript.path, "--model", modelName, "--server"]
        if let anchors = anchorsPath {
            args.append(contentsOf: ["--anchors", anchors])
        }
        process.arguments = args
        
        // Set environment
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        
        // Capture output for debugging
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            serverProcess = process
        } catch {
            setStatus(.error("Failed to start: \(error.localizedDescription)"))
            throw BridgeError.serverStartFailed(error.localizedDescription)
        }
        
        // Wait for server to be ready
        for _ in 0..<50 {  // 5 second timeout
            try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds
            
            if isServerRunning() {
                setStatus(.running)
                try await fetchStyles()
                return
            }
            
            // Check if process died
            if !process.isRunning {
                let output = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                setStatus(.error("Server crashed"))
                throw BridgeError.serverStartFailed(output)
            }
        }
        
        setStatus(.error("Server start timeout"))
        throw BridgeError.serverStartFailed("Timeout waiting for server")
    }
    
    /// Stops the RAVE server
    func stop() {
        // Close socket
        if socket >= 0 {
            Darwin.close(socket)
            socket = -1
        }
        
        // Terminate process
        if let process = serverProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        serverProcess = nil
        
        setStatus(.idle)
    }
    
    /// Checks if server is running by attempting to connect
    private func isServerRunning() -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return false
        }
        
        let testSocket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard testSocket >= 0 else { return false }
        defer { Darwin.close(testSocket) }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dest in
                _ = strcpy(dest, ptr)
            }
        }
        
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(testSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        return result == 0
    }
    
    private func setStatus(_ newStatus: Status) {
        statusLock.lock()
        _status = newStatus
        statusLock.unlock()
    }
    
    // MARK: - Communication
    
    /// Connects to the server socket
    private func connect() throws {
        if socket >= 0 {
            Darwin.close(socket)
        }
        
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw BridgeError.connectionFailed("Failed to create socket")
        }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dest in
                _ = strcpy(dest, ptr)
            }
        }
        
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard result == 0 else {
            Darwin.close(socket)
            socket = -1
            throw BridgeError.connectionFailed("Connect failed: \(errno)")
        }
    }
    
    /// Sends a JSON request to the server
    private func sendRequest<T: Encodable>(_ request: T) throws {
        if socket < 0 {
            try connect()
        }
        
        let encoder = JSONEncoder()
        var data = try encoder.encode(request)
        data.append(0)  // Null terminator
        
        let sent = data.withUnsafeBytes { ptr in
            Darwin.send(socket, ptr.baseAddress, data.count, 0)
        }
        
        guard sent == data.count else {
            throw BridgeError.communicationError("Failed to send request")
        }
    }
    
    /// Receives audio data from the server (4-byte length prefix + float32 data)
    private func receiveAudio() throws -> [Float] {
        guard socket >= 0 else {
            throw BridgeError.serverNotRunning
        }
        
        // Read length prefix (4 bytes, unsigned int)
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        var received = 0
        while received < 4 {
            let n = Darwin.recv(socket, &lengthBytes[received], 4 - received, 0)
            guard n > 0 else {
                throw BridgeError.communicationError("Connection closed while reading length")
            }
            received += n
        }
        
        let length = Int(lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self) })
        guard length > 0 && length < 100_000_000 else {  // Sanity check
            throw BridgeError.invalidResponse
        }
        
        // Read audio data
        var audioBytes = [UInt8](repeating: 0, count: length)
        received = 0
        while received < length {
            let n = Darwin.recv(socket, &audioBytes[received], length - received, 0)
            guard n > 0 else {
                throw BridgeError.communicationError("Connection closed while reading audio")
            }
            received += n
        }
        
        // Convert to Float array
        let floatCount = length / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: floatCount)
        audioBytes.withUnsafeBytes { ptr in
            _ = memcpy(&floats, ptr.baseAddress, length)
        }
        
        return floats
    }
    
    /// Receives JSON response from the server
    private func receiveJSON<T: Decodable>(_ type: T.Type) throws -> T {
        guard socket >= 0 else {
            throw BridgeError.serverNotRunning
        }
        
        // Read until null terminator
        var buffer = [UInt8]()
        var byte: UInt8 = 0
        
        while true {
            let n = Darwin.recv(socket, &byte, 1, 0)
            guard n > 0 else {
                throw BridgeError.communicationError("Connection closed")
            }
            
            if byte == 0 {
                break
            }
            buffer.append(byte)
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: Data(buffer))
    }
    
    // MARK: - API
    
    /// Fetches available styles from the server
    private func fetchStyles() async throws {
        try connect()
        
        let request = ["command": "get_styles"]
        try sendRequest(request)
        
        let response = try receiveJSON(StylesResponse.self)
        availableStyles = response.styles
        
        print("RAVEBridge: Available styles: \(availableStyles)")
    }
    
    /// Gets available style names
    func getStyles() -> [String] {
        return availableStyles
    }
    
    /// Generates audio with the specified controls
    func generate(controls: Controls, frames: Int = 50) async throws -> [Float] {
        guard case .running = status else {
            throw BridgeError.serverNotRunning
        }
        
        try connect()
        
        let request = GenerateRequest(
            command: "generate",
            frames: frames,
            styleBlend: controls.styleBlend,
            energy: controls.energy,
            tempoFactor: controls.tempoFactor,
            variation: controls.variation
        )
        
        try sendRequest(request)
        return try receiveAudio()
    }
    
    /// Sets controls without generating (for smooth transitions)
    func setControls(_ controls: Controls) async throws {
        guard case .running = status else {
            throw BridgeError.serverNotRunning
        }
        
        try connect()
        
        struct SetControlsRequest: Encodable {
            let command = "set_controls"
            let styleBlend: [String: Float]?
            let energy: Float
            let tempoFactor: Float
            let variation: Float
            
            enum CodingKeys: String, CodingKey {
                case command
                case styleBlend = "style_blend"
                case energy
                case tempoFactor = "tempo_factor"
                case variation
            }
        }
        
        let request = SetControlsRequest(
            styleBlend: controls.styleBlend,
            energy: controls.energy,
            tempoFactor: controls.tempoFactor,
            variation: controls.variation
        )
        
        try sendRequest(request)
        _ = try receiveJSON([String: String].self)  // {"status": "ok"}
    }
    
    // MARK: - Audio Buffer Management
    
    /// Fills the audio buffer with generated samples
    func fillBuffer(controls: Controls) async throws {
        let audio = try await generate(controls: controls, frames: bufferChunkFrames)
        
        audioBufferLock.lock()
        audioBuffer.append(contentsOf: audio)
        
        // Trim old samples to prevent memory growth
        if bufferReadPosition > 48000 * 2 {  // 2 seconds
            audioBuffer.removeFirst(bufferReadPosition)
            bufferReadPosition = 0
        }
        audioBufferLock.unlock()
    }
    
    /// Reads samples from the buffer (called from audio render thread)
    func readSamples(count: Int) -> [Float] {
        audioBufferLock.lock()
        defer { audioBufferLock.unlock() }
        
        let available = audioBuffer.count - bufferReadPosition
        let toRead = min(count, available)
        
        if toRead <= 0 {
            return [Float](repeating: 0, count: count)
        }
        
        let samples = Array(audioBuffer[bufferReadPosition..<(bufferReadPosition + toRead)])
        bufferReadPosition += toRead
        
        // Pad with zeros if not enough samples
        if samples.count < count {
            return samples + [Float](repeating: 0, count: count - samples.count)
        }
        
        return samples
    }
    
    /// Gets the number of buffered samples available
    var bufferedSamples: Int {
        audioBufferLock.lock()
        defer { audioBufferLock.unlock() }
        return audioBuffer.count - bufferReadPosition
    }
    
    /// Clears the audio buffer
    func clearBuffer() {
        audioBufferLock.lock()
        audioBuffer.removeAll()
        bufferReadPosition = 0
        audioBufferLock.unlock()
    }
}

