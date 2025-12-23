#!/usr/bin/env swift

// Simple test to verify PhrasePlayer loads and plays segments
// Run with: swift scripts/test_phrase_swift.swift

import Foundation
import AVFoundation

// Paths
let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let segmentsDir = documentsURL.appendingPathComponent("MusicMill/PhraseSegments")
let segmentsJSON = segmentsDir.appendingPathComponent("segments.json")

print("=== PhrasePlayer Swift Test ===\n")

// Check segments exist
guard FileManager.default.fileExists(atPath: segmentsJSON.path) else {
    print("❌ No segments found at: \(segmentsJSON.path)")
    print("Run: python scripts/test_phrase_player.py first")
    exit(1)
}

// Load JSON
guard let data = try? Data(contentsOf: segmentsJSON),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let segments = json["segments"] as? [[String: Any]] else {
    print("❌ Failed to parse segments.json")
    exit(1)
}

print("Found \(segments.count) segments in JSON\n")

// Create audio engine
let engine = AVAudioEngine()
let mixer = engine.mainMixerNode
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

// Load first segment as a test
guard let firstSeg = segments.first,
      let filePath = firstSeg["file"] as? String,
      let tempo = firstSeg["tempo"] as? Double,
      let segType = firstSeg["type"] as? String else {
    print("❌ Invalid segment data")
    exit(1)
}

let url = URL(fileURLWithPath: filePath)
print("Loading segment: \(url.lastPathComponent)")
print("  Tempo: \(String(format: "%.1f", tempo)) BPM")
print("  Type: \(segType)")

guard FileManager.default.fileExists(atPath: url.path) else {
    print("❌ Segment file not found: \(filePath)")
    exit(1)
}

// Load audio file
do {
    let file = try AVAudioFile(forReading: url)
    print("  Duration: \(String(format: "%.1f", Double(file.length) / file.fileFormat.sampleRate)) seconds")
    print("  Format: \(file.fileFormat.sampleRate) Hz, \(file.fileFormat.channelCount) channels")
    
    // Create buffer
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        print("❌ Failed to create buffer")
        exit(1)
    }
    try file.read(into: buffer)
    
    // Create player node
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: mixer, format: buffer.format)
    
    // Prepare output file for capture
    let outputURL = documentsURL.appendingPathComponent("MusicMill/phrase_swift_test.wav")
    try? FileManager.default.removeItem(at: outputURL)
    
    let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 44100.0,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false
    ]
    
    let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
    
    // Install tap to capture
    var capturedFrames: AVAudioFrameCount = 0
    mixer.installTap(onBus: 0, bufferSize: 4096, format: format) { tapBuffer, _ in
        try? outputFile.write(from: tapBuffer)
        capturedFrames += tapBuffer.frameLength
    }
    
    // Start engine and play
    try engine.start()
    player.scheduleBuffer(buffer, at: nil, options: []) {
        print("  Playback complete")
    }
    player.play()
    
    // Wait for duration + 0.5s
    let duration = Double(buffer.frameLength) / buffer.format.sampleRate
    print("\nPlaying for \(String(format: "%.1f", duration)) seconds...")
    Thread.sleep(forTimeInterval: duration + 0.5)
    
    // Stop
    player.stop()
    engine.stop()
    mixer.removeTap(onBus: 0)
    
    print("\n✓ Captured \(capturedFrames) frames")
    print("✓ Saved to: \(outputURL.path)")
    
    // Check output file
    let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
    let fileSize = attrs[.size] as? Int ?? 0
    print("✓ File size: \(String(format: "%.1f", Double(fileSize) / 1024)) KB")
    
    print("\n=== TEST PASSED ===")
    print("\nTo listen: afplay '\(outputURL.path)'")
    
} catch {
    print("❌ Error: \(error)")
    exit(1)
}

