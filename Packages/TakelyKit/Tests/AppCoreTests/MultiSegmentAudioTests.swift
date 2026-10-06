import AVFoundation
import CaptureKit
import Foundation
import ProjectKit
import RenderKit
import TestSupport
import Testing

@testable import AppCore

@Suite struct MultiSegmentAudioTests {
    /// A paused recording (three segments, screen + microphone, nothing to composite) exports with its audio as one
    /// continuous edit: an empty edit at each join made some players drift.
    @Test func audioHasNoEmptyEditsAtSegmentJoins() async throws {
        let bundle = try ProjectBundle.create(in: Synthetic.temporaryFolder())
        var project = Project(
            status: .finished, capture: .init(target: .display, pixelSize: PixelSize(width: 320, height: 200), fps: 30, codec: .h264),
            camera: .init(enabled: false))
        let config = WriterConfig(
            tracks: [.screen, .mic], screenSize: PixelSize(width: 320, height: 200), cameraSize: PixelSize(width: 160, height: 90),
            codec: .h264, fps: 30, videoBitrate: 1_000_000)
        for i in 0..<3 {
            let file = ProjectBundle.segmentFileName(index: i)
            try bundle.writeSidecar(tracks: config.tracks, for: file)
            let base = 1000.0 * Double(i + 1)
            let writer = try SegmentWriter(url: bundle.segmentURL(file), config: config)
            try await RecoveryFixture.feed(writer, from: base, seconds: 1.5, tracks: config.tracks)
            let duration = try await writer.finish(at: Synthetic.seconds(base + 1.5)) ?? 0
            project.segments.append(.init(file: file, duration: duration, tracks: config.tracks))
        }
        try bundle.write(project)
        let url = try await Exporter().export(bundle)
        let audio = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        let segments = try await audio.load(.segments)
        #expect(!segments.contains { $0.isEmpty }, "edits: \(segments.map { $0.isEmpty ? "empty" : "media" })")
        // Gaps kept as silence (≈ 4.472 s), not the pieces butted together (≈ 4.416 s), which would drift for good.
        let duration = try await audio.load(.timeRange).duration.seconds
        #expect(duration > 4.45 && duration < 4.51, "\(duration)")
    }
}
