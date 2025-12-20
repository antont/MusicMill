import Foundation
import AVFoundation

/// Analyzes audio files in a music collection and extracts segments for training
class AudioAnalyzer {
    
    enum AudioFormat: String, CaseIterable {
        case mp3 = "mp3"
        case aac = "aac"
        case m4a = "m4a"
        case wav = "wav"
        case aiff = "aiff"
        case aif = "aif"
        
        var fileExtension: String {
            return rawValue
        }
        
        static var supportedExtensions: [String] {
            return AudioFormat.allCases.map { $0.fileExtension }
        }
    }
    
    struct AudioFile {
        let url: URL
        let duration: TimeInterval
        let format: AudioFormat
    }
    
    /// Scans a directory for supported audio files
    func scanDirectory(at url: URL) async throws -> [AudioFile] {
        let fileManager = FileManager.default
        var audioFiles: [AudioFile] = []
        
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AudioAnalyzerError.directoryNotFound
        }
        
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }
            
            let pathExtension = fileURL.pathExtension.lowercased()
            guard AudioFormat.supportedExtensions.contains(pathExtension) else {
                continue
            }
            
            if let format = AudioFormat(rawValue: pathExtension),
               let duration = try? await getAudioDuration(url: fileURL) {
                audioFiles.append(AudioFile(url: fileURL, duration: duration, format: format))
            }
        }
        
        return audioFiles
    }
    
    /// Extracts audio segments for training (default: 30-second clips)
    func extractTrainingSegments(from audioFile: AudioFile, segmentDuration: TimeInterval = 30.0) async throws -> [URL] {
        let asset = AVAsset(url: audioFile.url)
        let duration = try await asset.load(.duration)
        let totalDuration = CMTimeGetSeconds(duration)
        
        guard totalDuration >= segmentDuration else {
            // If file is shorter than segment duration, return the whole file
            return [audioFile.url]
        }
        
        var segments: [URL] = []
        let numberOfSegments = Int(totalDuration / segmentDuration)
        
        // Extract multiple segments from the file
        for i in 0..<min(numberOfSegments, 5) { // Limit to 5 segments per file
            let startTime = Double(i) * segmentDuration
            let segmentURL = try await extractSegment(
                from: audioFile.url,
                startTime: startTime,
                duration: segmentDuration
            )
            segments.append(segmentURL)
        }
        
        return segments
    }
    
    /// Extracts a specific segment from an audio file
    private func extractSegment(from url: URL, startTime: TimeInterval, duration: TimeInterval) async throws -> URL {
        let asset = AVAsset(url: url)
        let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        
        guard let exportSession = exportSession else {
            throw AudioAnalyzerError.exportSessionFailed
        }
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw AudioAnalyzerError.segmentExtractionFailed
        }
        
        return outputURL
    }
    
    /// Gets the duration of an audio file
    private func getAudioDuration(url: URL) async throws -> TimeInterval {
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }
    
    enum AudioAnalyzerError: LocalizedError {
        case directoryNotFound
        case exportSessionFailed
        case segmentExtractionFailed
        
        var errorDescription: String? {
            switch self {
            case .directoryNotFound:
                return "Directory not found or cannot be accessed"
            case .exportSessionFailed:
                return "Failed to create export session"
            case .segmentExtractionFailed:
                return "Failed to extract audio segment"
            }
        }
    }
}

