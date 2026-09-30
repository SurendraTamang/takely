import AVFoundation
import ProjectKit
import TestSupport
import Testing

@testable import CaptureKit

@Suite struct SegmentWriterTests {
    let config = WriterConfig(
        tracks: [.screen, .camera, .system, .mic],
        screenSize: PixelSize(width: 320, height: 200),
        cameraSize: PixelSize(width: 160, height: 90),
        codec: .h264, fps: 30, videoBitrate: 1_000_000
    )

    /// Writes one second starting at host time 1000 s, like a real capture would.
    func writeOneSecond(to url: URL) async throws -> (SegmentWriter, Double?) {
        let writer = try SegmentWriter(url: url, config: config)
        writer.append(Synthetic.audio(pts: Synthetic.seconds(999.5)), as: .system)
        for i in 0..<30 {
            let t = 1000 + Double(i) / 30
            writer.append(Synthetic.video(width: 320, height: 200, pts: Synthetic.seconds(t), rgb: (255, 0, 0)), as: .screen)
            writer.append(Synthetic.video(width: 160, height: 90, pts: Synthetic.seconds(t), rgb: (0, 255, 0)), as: .camera)
            try await Task.sleep(for: .milliseconds(2))
        }
        for i in 0..<47 {
            let t = Synthetic.seconds(1000 + Double(i) * 1024 / 48_000)
            writer.append(Synthetic.audio(pts: t), as: .system)
            writer.append(Synthetic.audio(pts: t), as: .mic)
        }
        let duration = try await writer.finish(at: Synthetic.seconds(1001))
        return (writer, duration)
    }

    @Test func writesOneTrackPerKindInConfigOrder() async throws {
        let url = Synthetic.temporaryFolder().appending(path: "segment.mov")
        _ = try await writeOneSecond(to: url)
        let tracks = try await AVURLAsset(url: url).load(.tracks)
        let types = tracks.sorted { $0.trackID < $1.trackID }.map(\.mediaType)
        #expect(types == [.video, .video, .audio, .audio])
    }

    @Test func durationRunsFromFirstScreenFrameToEnd() async throws {
        let url = Synthetic.temporaryFolder().appending(path: "segment.mov")
        let (writer, duration) = try await writeOneSecond(to: url)
        #expect(abs((duration ?? 0) - 1.0) < 0.001)
        #expect(writer.startTime == Synthetic.seconds(1000))
        let assetDuration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(assetDuration - 1.0) < 0.05)
    }

    @Test func ignoresAudioBeforeFirstScreenFrame() throws {
        let url = Synthetic.temporaryFolder().appending(path: "segment.mov")
        let writer = try SegmentWriter(url: url, config: config)
        #expect(!writer.append(Synthetic.audio(pts: Synthetic.seconds(1)), as: .mic))
        #expect(writer.startTime == nil)
    }

    @Test func segmentWithoutScreenFramesIsDeleted() async throws {
        let url = Synthetic.temporaryFolder().appending(path: "segment.mov")
        let writer = try SegmentWriter(url: url, config: config)
        #expect(try await writer.finish(at: Synthetic.seconds(5)) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func rejectsAppendsAfterFinish() async throws {
        let url = Synthetic.temporaryFolder().appending(path: "segment.mov")
        let (writer, _) = try await writeOneSecond(to: url)
        #expect(!writer.append(Synthetic.audio(pts: Synthetic.seconds(1000.5)), as: .mic))
    }

    @Test func staticScreenSpansWholeSegment() async throws {
        let url = Synthetic.temporaryFolder().appending(path: "segment.mov")
        let writer = try SegmentWriter(url: url, config: config)
        writer.append(Synthetic.video(width: 320, height: 200, pts: Synthetic.seconds(1000), rgb: (255, 0, 0)), as: .screen)
        _ = try await writer.finish(at: Synthetic.seconds(1003))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        let screenTrack = tracks.sorted { $0.trackID < $1.trackID }.first { $0.mediaType == .video }!
        let timeRange = try await screenTrack.load(.timeRange)
        #expect(abs(timeRange.duration.seconds - 3.0) < 0.05)
        let assetDuration = try await asset.load(.duration).seconds
        #expect(abs(assetDuration - 3.0) < 0.05)
    }

    @Test func finishTwiceIsSafe() async throws {
        let url = Synthetic.temporaryFolder().appending(path: "segment.mov")
        let (writer, _) = try await writeOneSecond(to: url)
        #expect(try await writer.finish(at: Synthetic.seconds(1002)) == nil)
    }

    @Test func keepsAudioStraddlingSessionStart() throws {
        let url = Synthetic.temporaryFolder().appending(path: "segment.mov")
        let writer = try SegmentWriter(url: url, config: config)
        writer.append(Synthetic.video(width: 320, height: 200, pts: Synthetic.seconds(1000), rgb: (255, 0, 0)), as: .screen)
        #expect(writer.append(Synthetic.audio(pts: Synthetic.seconds(999.99)), as: .system))
        #expect(!writer.append(Synthetic.audio(pts: Synthetic.seconds(999.9)), as: .mic))
    }

    @Test func rejectsNonIncreasingVideoPTS() async throws {
        let url = Synthetic.temporaryFolder().appending(path: "segment.mov")
        let writer = try SegmentWriter(url: url, config: config)
        #expect(writer.append(Synthetic.video(width: 320, height: 200, pts: Synthetic.seconds(1000), rgb: (255, 0, 0)), as: .screen))
        #expect(writer.append(Synthetic.video(width: 320, height: 200, pts: Synthetic.seconds(1000.1), rgb: (255, 0, 0)), as: .screen))
        #expect(!writer.append(Synthetic.video(width: 320, height: 200, pts: Synthetic.seconds(1000.1), rgb: (255, 0, 0)), as: .screen))
        #expect(!writer.append(Synthetic.video(width: 320, height: 200, pts: Synthetic.seconds(1000.05), rgb: (255, 0, 0)), as: .screen))
        #expect(writer.append(Synthetic.video(width: 320, height: 200, pts: Synthetic.seconds(1000.2), rgb: (255, 0, 0)), as: .screen))
        _ = try await writer.finish(at: Synthetic.seconds(1001))
        #expect(writer.failure == nil)
    }

    @Test func recordsOnlyWrittenTracks() async throws {
        let url = Synthetic.temporaryFolder().appending(path: "segment.mov")
        let writer = try SegmentWriter(url: url, config: config)
        for i in 0..<30 {
            let t = 1000 + Double(i) / 30
            writer.append(Synthetic.video(width: 320, height: 200, pts: Synthetic.seconds(t), rgb: (255, 0, 0)), as: .screen)
            try await Task.sleep(for: .milliseconds(2))
        }
        for i in 0..<47 {
            let t = Synthetic.seconds(1000 + Double(i) * 1024 / 48_000)
            writer.append(Synthetic.audio(pts: t), as: .mic)
        }
        _ = try await writer.finish(at: Synthetic.seconds(1001))
        #expect(writer.writtenTracks == [.screen, .mic])
        let tracks = try await AVURLAsset(url: url).load(.tracks)
        let sorted = tracks.sorted { $0.trackID < $1.trackID }
        #expect(sorted.count == 2)
        #expect(sorted.map(\.mediaType) == [.video, .audio])
    }
}
