import AVFoundation
import CaptureKit
import ProjectKit
import RenderKit
import TestSupport
import Testing

@testable import AppCore

/// Builds bundles the way a real recording leaves them, including one that "crashed" mid-segment.
enum RecoveryFixture {
    static let config = WriterConfig(
        tracks: [.screen, .camera, .system, .mic], screenSize: PixelSize(width: 320, height: 200),
        cameraSize: PixelSize(width: 160, height: 90), codec: .h264, fps: 30, videoBitrate: 1_000_000)

    static func project(status: Project.Status) -> Project {
        Project(
            status: status,
            capture: .init(target: .display, pixelSize: PixelSize(width: 320, height: 200), fps: 30, codec: .h264),
            camera: .init(enabled: true))
    }

    /// Feeds all configured tracks interleaved in time order, as real capture does; AVAssetWriter
    /// holds back writing until every input has data.
    static func feed(_ writer: SegmentWriter, from base: Double, seconds: Double, tracks: [TrackKind]) async throws {
        var nextAudio = base
        for i in 0..<Int(seconds * 30) {
            let t = base + Double(i) / 30
            writer.append(Synthetic.video(width: 320, height: 200, pts: Synthetic.seconds(t), rgb: (255, 0, 0)), as: .screen)
            if tracks.contains(.camera), i % 2 == 0 {
                writer.append(Synthetic.video(width: 160, height: 90, pts: Synthetic.seconds(t), rgb: (0, 255, 0)), as: .camera)
            }
            while nextAudio <= t {
                if tracks.contains(.system) { writer.append(Synthetic.audio(pts: Synthetic.seconds(nextAudio)), as: .system) }
                if tracks.contains(.mic) { writer.append(Synthetic.audio(pts: Synthetic.seconds(nextAudio)), as: .mic) }
                nextAudio += 1024.0 / 48_000
            }
            try await Task.sleep(for: .milliseconds(4))
        }
    }

    /// Segment 0 finished normally (1 s); segment 1 copied while still being written (6 s fed → ~4 s readable).
    static func crashedBundle(in folder: URL) async throws -> ProjectBundle {
        let bundle = try ProjectBundle.create(in: folder)
        try bundle.write(project(status: .recording))
        for index in 0..<2 {
            let file = ProjectBundle.segmentFileName(index: index)
            try bundle.writeSidecar(tracks: config.tracks, for: file)
            let base = 1000.0 * Double(index + 1)
            let url = index == 0 ? bundle.segmentURL(file) : folder.appending(path: "live-\(UUID()).mov")
            let writer = try SegmentWriter(url: url, config: config)
            try await feed(writer, from: base, seconds: index == 0 ? 1 : 6, tracks: config.tracks)
            if index == 0 {
                _ = try await writer.finish(at: Synthetic.seconds(base + 1))
            } else {
                try await Task.sleep(for: .seconds(1))
                try FileManager.default.copyItem(at: url, to: bundle.segmentURL(file))  // the "crash"
                _ = try await writer.finish(at: Synthetic.seconds(base + 6))
            }
        }
        return bundle
    }
}

@Suite struct RecoveryServiceTests {
    @Test func rebuildsACrashedBundleAndItExports() async throws {
        let bundle = try await RecoveryFixture.crashedBundle(in: Synthetic.temporaryFolder())
        let report = try await RecoveryService.rebuild(bundle)
        #expect(report.skipped.isEmpty)
        #expect(report.project.status == .finished)
        #expect(report.project.segments.map(\.file) == ["segment-000.mov", "segment-001.mov"])
        #expect(report.project.segments.allSatisfy { $0.tracks == [.screen, .camera, .system, .mic] })
        #expect(report.project.segments[1].duration > 1.5)
        #expect(try bundle.readProject() == report.project)
        let url = try await Exporter().export(bundle)
        #expect(try await AVURLAsset(url: url).load(.duration).seconds > 2.5)
    }

    @Test func segmentWithoutSidecarIsSkippedNotGuessed() async throws {
        let bundle = try await RecoveryFixture.crashedBundle(in: Synthetic.temporaryFolder())
        try FileManager.default.removeItem(at: bundle.sidecarURL(for: "segment-000.mov"))
        let report = try await RecoveryService.rebuild(bundle)
        #expect(report.skipped == ["segment-000.mov"])
        #expect(report.project.segments.map(\.file) == ["segment-001.mov"])
    }

    @Test func nothingUsableThrows() async throws {
        let bundle = try ProjectBundle.create(in: Synthetic.temporaryFolder())
        try bundle.write(RecoveryFixture.project(status: .recording))
        try Data("not a movie".utf8).write(to: bundle.segmentURL("segment-000.mov"))
        try bundle.writeSidecar(tracks: [.screen], for: "segment-000.mov")
        await #expect(throws: RecoveryError.nothingRecoverable) { try await RecoveryService.rebuild(bundle) }
    }

    @Test func scanFindsCrashedAndUnexportedButNotExported() async throws {
        let folder = Synthetic.temporaryFolder()
        func make(_ status: Project.Status, at seconds: Double) throws -> ProjectBundle {
            let bundle = try ProjectBundle.create(in: folder, date: Date(timeIntervalSince1970: seconds))
            var project = RecoveryFixture.project(status: status)
            project.createdAt = Date(timeIntervalSince1970: seconds)
            try bundle.write(project)
            return bundle
        }
        let unexported = try make(.finished, at: 2)
        let crashed = try make(.recording, at: 1)
        let exported = try make(.finished, at: 3)
        try Data().write(to: exported.exportURL)

        let found = RecoveryService.scan(folder)
        #expect(found.map(\.bundle) == [crashed, unexported])  // oldest first
        #expect(found.map(\.kind) == [.crashed, .unexported])
    }
}
