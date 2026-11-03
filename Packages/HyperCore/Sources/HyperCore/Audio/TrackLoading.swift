import Foundation

public enum TrackLoadError: Error, Equatable, Sendable {
    case fileNotFound(URL)
    case unreadable(URL, String)
}

/// Produces decoded tracks at a given sample rate.
public protocol TrackLoading: Sendable {
    func track(for url: URL, sampleRate: Double) async throws -> AudioTrack
}
