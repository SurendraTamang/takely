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

    /// A camera that stops mid-segment is noted (the bubble is hidden from there).
    @Test func aCameraThatStoppedIsNoted() async throws {
        let bundle = try ProjectBundle.create(in: Synthetic.temporaryFolder())
        var project = Project(
            status: .finished, capture: .init(target: .display, pixelSize: PixelSize(width: 320, height: 200), fps: 30, codec: .h264),
            camera: .init(enabled: true))
        let config = WriterConfig(
            tracks: [.screen, .camera], screenSize: PixelSize(width: 320, height: 200), cameraSize: PixelSize(width: 160, height: 90),
            codec: .h264, fps: 30, videoBitrate: 1_000_000)
        let file = ProjectBundle.segmentFileName(index: 0)
        try bundle.writeSidecar(tracks: config.tracks, for: file)
        let writer = try SegmentWriter(url: bundle.segmentURL(file), config: config)
        for i in 0..<120 {  // 4 s of screen; the camera only for the first second
            let t = 1000 + Double(i) / 30
            writer.append(Synthetic.video(width: 320, height: 200, pts: Synthetic.seconds(t), rgb: (255, 0, 0)), as: .screen)
            if i < 30 { writer.append(Synthetic.video(width: 160, height: 90, pts: Synthetic.seconds(t), rgb: (0, 255, 0)), as: .camera) }
            try await Task.sleep(for: .milliseconds(2))
        }
        let duration = try await writer.finish(at: Synthetic.seconds(1004)) ?? 0
        project.segments = [.init(file: file, duration: duration, tracks: config.tracks)]
        try bundle.write(project)
        let stopped = try #require(await CameraCheck.stoppedAt(bundle))
        #expect(abs(stopped - 1) < 0.2, "\(stopped)")
        await CameraCheck.note(bundle)
        #expect(try bundle.readProject().notes?["camera"]?.hasPrefix("The camera stopped at 0:01") == true)
        // In the video, after its cuts: a cut before the stop moves it earlier.
        try bundle.write(Edits(cuts: [TimeRange(start: 0, end: 0.9)]))
        await CameraCheck.note(bundle)
        #expect(try bundle.readProject().notes?["camera"]?.hasPrefix("The camera stopped at 0:00") == true)
        // A later segment without any camera track (lost during a pause) counts too.
        var withPause = try bundle.readProject()
        withPause.segments = [.init(file: file, duration: 0.95, tracks: config.tracks), .init(file: file, duration: 2, tracks: [.screen])]
        try bundle.write(withPause)
        try FileManager.default.removeItem(at: bundle.editsURL)
        #expect(await CameraCheck.stoppedAt(bundle) == 0.95)
    }
}
