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

    /// Segment 0 finished normally (1 s) and is listed in the manifest, like a real closed segment;
    /// segment 1 copied while still being written (6 s fed → ~4 s readable) and is left for recovery.
    static func crashedBundle(in folder: URL) async throws -> ProjectBundle {
        let bundle = try ProjectBundle.create(in: folder)
        var project = project(status: .recording)

        let file0 = ProjectBundle.segmentFileName(index: 0)
        try bundle.writeSidecar(tracks: config.tracks, for: file0)
        let base0 = 1000.0
        let writer0 = try SegmentWriter(url: bundle.segmentURL(file0), config: config)
        try await feed(writer0, from: base0, seconds: 1, tracks: config.tracks)
        let duration0 = try await writer0.finish(at: Synthetic.seconds(base0 + 1)) ?? 0
        project.segments = [Project.Segment(file: file0, duration: duration0, tracks: config.tracks)]
        try bundle.write(project)
        try bundle.write(CursorTrack(samples: [CursorSample(t: 0, x: 0.1, y: 0.1), CursorSample(t: 0.9, x: 0.2, y: 0.2)]))

        let file1 = ProjectBundle.segmentFileName(index: 1)
        try bundle.writeSidecar(tracks: config.tracks, for: file1)
        let base1 = 2000.0
        let url1 = folder.appending(path: "live-\(UUID()).mov")
        let writer1 = try SegmentWriter(url: url1, config: config)
        try await feed(writer1, from: base1, seconds: 6, tracks: config.tracks)
        try await Task.sleep(for: .seconds(1))
        try FileManager.default.copyItem(at: url1, to: bundle.segmentURL(file1))  // the "crash"
        _ = try await writer1.finish(at: Synthetic.seconds(base1 + 6))

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
        #expect(abs(report.project.segments[0].duration - 1.0) < 0.01)
        #expect(abs(report.project.segments[1].duration - 4.0) < 0.15)
        #expect(try bundle.readProject() == report.project)
        #expect(try bundle.readCursor().coveredUntil == report.project.segments[0].duration)
        let url = try await Exporter().export(bundle)
        #expect(abs(try await AVURLAsset(url: url).load(.duration).seconds - 5.0) < 0.15)
    }

    @Test func segmentWithoutSidecarIsSkippedNotGuessed() async throws {
        let bundle = try await RecoveryFixture.crashedBundle(in: Synthetic.temporaryFolder())
        try FileManager.default.removeItem(at: bundle.sidecarURL(for: "segment-001.mov"))
        let report = try await RecoveryService.rebuild(bundle)
        #expect(report.skipped == ["segment-001.mov"])
        #expect(report.project.segments.map(\.file) == ["segment-000.mov"])
    }

    /// A segment whose close failed (renamed `.failed` by the capture session), an unreadable one and a good one after them.
    @Test func quarantinedAndUnreadableSegmentsAreLeftOutOfTheRebuild() async throws {
        let bundle = try await RecoveryFixture.crashedBundle(in: Synthetic.temporaryFolder())
        let fm = FileManager.default
        try fm.copyItem(at: bundle.segmentURL("segment-001.mov"), to: bundle.segmentURL("segment-003.mov"))
        try bundle.writeSidecar(tracks: RecoveryFixture.config.tracks, for: "segment-003.mov")
        try Data("not a movie".utf8).write(to: bundle.segmentURL("segment-002.mov"))
        try bundle.writeSidecar(tracks: RecoveryFixture.config.tracks, for: "segment-002.mov")
        for url in [bundle.segmentURL("segment-001.mov"), bundle.sidecarURL(for: "segment-001.mov")] {
            try fm.moveItem(at: url, to: url.appendingPathExtension("failed"))
        }
        let report = try await RecoveryService.rebuild(bundle)
        #expect(report.skipped == ["segment-002.mov"])
        #expect(report.project.segments.map(\.file) == ["segment-000.mov", "segment-003.mov"])
    }

    @Test func nothingUsableThrows() async throws {
        let bundle = try ProjectBundle.create(in: Synthetic.temporaryFolder())
        try bundle.write(RecoveryFixture.project(status: .recording))
        try Data("not a movie".utf8).write(to: bundle.segmentURL("segment-000.mov"))
        try bundle.writeSidecar(tracks: [.screen], for: "segment-000.mov")
        await #expect(throws: RecoveryError.nothingRecoverable) { try await RecoveryService.rebuild(bundle) }
    }

    @Test func aCrashBeforeAPausesCursorWriteLandedEndsCursorEffectsWhereItsDataEnds() async throws {
        let bundle = try ProjectBundle.create(in: Synthetic.temporaryFolder())
        var project = RecoveryFixture.project(status: .recording)
        project.segments = [
            .init(file: "segment-000.mov", duration: 1, tracks: [.screen]), .init(file: "segment-001.mov", duration: 1, tracks: [.screen]),
        ]
        try bundle.write(project)
        // The file the first pause wrote (covering 1 s); the second pause's write never landed.
        try bundle.write(CursorTrack(samples: [CursorSample(t: 0.5, x: 0.5, y: 0.5)], coveredUntil: 1))
        _ = try await RecoveryService.rebuild(bundle)
        #expect(try bundle.readCursor().coveredUntil == 1)
        #expect(try bundle.readProject().status == .finished)
    }

    @Test func finishedBundleIsLeftAlone() async throws {
        let bundle = try ProjectBundle.create(in: Synthetic.temporaryFolder())
        try bundle.write(RecoveryFixture.project(status: .finished))
        let written = try bundle.readProject()
        let report = try await RecoveryService.rebuild(bundle)
        #expect(report.project == written)
        #expect(report.skipped.isEmpty)
        #expect(try bundle.readProject() == written)
    }

    @Test func scanFindsCrashedAndUnexportedButNotExported() async throws {
        let folder = Synthetic.temporaryFolder()
        func make(_ status: Project.Status, at seconds: Double, segments: [Project.Segment] = []) throws -> ProjectBundle {
            let bundle = try ProjectBundle.create(in: folder, date: Date(timeIntervalSince1970: seconds))
            var project = RecoveryFixture.project(status: status)
            project.createdAt = Date(timeIntervalSince1970: seconds)
            project.segments = segments
            try bundle.write(project)
            return bundle
        }
        let unexported = try make(.finished, at: 2, segments: [Project.Segment(file: "segment-000.mov", duration: 1, tracks: [.screen])])
        let crashed = try make(.recording, at: 1)
        let exported = try make(.finished, at: 3, segments: [Project.Segment(file: "segment-000.mov", duration: 1, tracks: [.screen])])
        try Data().write(to: exported.exportURL)
        let empty = try make(.finished, at: 4)
        // Exported once, then its MP4 dragged out of the bundle: still done.
        let moved = try make(.finished, at: 5, segments: [Project.Segment(file: "segment-000.mov", duration: 1, tracks: [.screen])])
        var project = try moved.readProject()
        project.exportedAt = .now
        try moved.write(project)

        let found = RecoveryService.scan(folder)
        #expect(found.map(\.bundle) == [crashed, unexported, empty])  // oldest first
        #expect(found.map(\.kind) == [.crashed, .unexported, .empty])
    }
}
