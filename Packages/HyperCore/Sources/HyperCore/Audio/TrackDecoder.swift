import AVFoundation
import Foundation

/// Decodes an audio file to deinterleaved Float32 stereo at the requested sample rate.
///
/// The file is read in chunks (a fresh buffer per converter callback), so peak memory is
/// the output track plus one small chunk, never the whole file as a second copy.
public struct TrackDecoder: TrackLoading {
    private static let inputChunkFrames: AVAudioFrameCount = 32_768
    private static let outputChunkFrames: AVAudioFrameCount = 32_768

    public init() {}

    public func track(for url: URL, sampleRate: Double) async throws -> AudioTrack {
        try await Task.detached(priority: .userInitiated) {
            try Self.decode(url: url, sampleRate: sampleRate)
        }.value
    }

    static func decode(url: URL, sampleRate: Double) throws -> AudioTrack {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TrackLoadError.fileNotFound(url)
        }
        func fail(_ message: String) -> TrackLoadError { .unreadable(url, message) }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw fail(error.localizedDescription)
        }
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw fail("unsupported format \(inFormat)")
        }
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outputChunkFrames),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inputChunkFrames) else {
            throw fail("could not allocate decode buffers")
        }

        // Output storage, sized from the expected length and grown if the converter overshoots.
        let ratio = sampleRate / inFormat.sampleRate
        var capacity = max(Int((Double(file.length) * ratio).rounded(.up)) + 4096, 1)
        var left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        var right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        var written = 0
        func freeBuffers() { left.deallocate(); right.deallocate() }

        let source = ChunkSource(file: file, buffer: inBuffer)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            source.next(status)
        }

        while true {
            outBuffer.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
            if let readError = source.readError { freeBuffers(); throw fail(readError.localizedDescription) }
            if status == .error {
                freeBuffers()
                throw fail(convError?.localizedDescription ?? "conversion failed")
            }
            let n = Int(outBuffer.frameLength)
            if n > 0, let channels = outBuffer.floatChannelData {
                if written + n > capacity {
                    let newCapacity = max(capacity * 2, written + n)
                    let newLeft = UnsafeMutablePointer<Float>.allocate(capacity: newCapacity)
                    let newRight = UnsafeMutablePointer<Float>.allocate(capacity: newCapacity)
                    newLeft.update(from: left, count: written)
                    newRight.update(from: right, count: written)
                    freeBuffers()
                    left = newLeft; right = newRight; capacity = newCapacity
                }
                (left + written).update(from: channels[0], count: n)
                (right + written).update(from: channels[1], count: n)
                written += n
            }
            if status == .endOfStream { break }
        }

        return AudioTrack(url: url, sampleRate: sampleRate, adoptingLeft: left, right: right,
                          frameCount: written)
    }

    /// Feeds the converter one freshly read chunk per callback, then `.endOfStream`.
    /// Only ever used from the single decoding thread.
    private final class ChunkSource: @unchecked Sendable {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        var finished = false
        var readError: Error?

        init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
            self.file = file
            self.buffer = buffer
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if !finished && file.framePosition >= file.length { finished = true }
            if !finished {
                buffer.frameLength = 0
                do {
                    try file.read(into: buffer, frameCount: buffer.frameCapacity)
                } catch {
                    readError = error
                    finished = true
                }
                if buffer.frameLength == 0 { finished = true }
            }
            if finished {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
    }
}
