import AVFoundation
import CoreImage
import ProjectKit
import Synchronization
import TestSupport
import Testing

@testable import CaptureKit
@testable import RenderKit

@Suite struct ExporterTests {
    /// Writes a bundle with `screen`-colored screen (+ green camera, + both audio tracks) segments of `durations` seconds.
    /// `cameraEnabled` overrides `project.camera.enabled` independently of whether a camera track was written; nil means "same as `camera`".
    func makeBundle(
        durations: [Double], camera: Bool, audio: Bool, effects: Bool, screen: (UInt8, UInt8, UInt8) = (255, 0, 0),
        cameraEnabled: Bool? = nil
    ) async throws -> ProjectBundle {
        let bundle = try ProjectBundle.create(in: Synthetic.temporaryFolder())
        let tracks: [TrackKind] = [.screen] + (camera ? [.camera] : []) + (audio ? [.system, .mic] : [])
        let config = WriterConfig(
            tracks: tracks, screenSize: PixelSize(width: 320, height: 200), cameraSize: PixelSize(width: 160, height: 90), codec: .h264,
            fps: 30, videoBitrate: 1_000_000)
        var segments: [Project.Segment] = []
        for (index, seconds) in durations.enumerated() {
            let file = ProjectBundle.segmentFileName(index: index)
            let writer = try SegmentWriter(url: bundle.segmentURL(file), config: config)
            let base = 1000.0 * Double(index + 1)
            for i in 0..<Int(seconds * 30) {
                let pts = Synthetic.seconds(base + Double(i) / 30)
                writer.append(Synthetic.video(width: 320, height: 200, pts: pts, rgb: screen), as: .screen)
                if camera { writer.append(Synthetic.video(width: 160, height: 90, pts: pts, rgb: (0, 255, 0)), as: .camera) }
                try await Task.sleep(for: .milliseconds(2))
            }
            if audio {
                for i in 0..<Int(seconds * 48_000 / 1024) {
                    let pts = Synthetic.seconds(base + Double(i) * 1024 / 48_000)
                    writer.append(Synthetic.audio(pts: pts), as: .system)
                    writer.append(Synthetic.audio(pts: pts), as: .mic)
                }
            }
            let duration = try #require(try await writer.finish(at: Synthetic.seconds(base + seconds)))
            segments.append(.init(file: file, duration: duration, tracks: tracks))
        }
        try bundle.write(
            Project(
                status: .finished,
                capture: .init(target: .display, pixelSize: PixelSize(width: 320, height: 200), fps: 30, codec: .h264),
                segments: segments,
                camera: .init(enabled: cameraEnabled ?? camera, size: 0.3, keyframes: [BubbleKeyframe(t: 0, x: 0.5, y: 0.5)]),
                effects: .init(cursorHighlight: effects, clickRipples: effects)
            ))
        return bundle
    }

    struct SegSpec {
        var seconds: Double
        var tracks: [TrackKind]
        var cameraFrom: Double = 0
    }

    /// Writes a bundle from heterogeneous per-segment track specs (red screen, green camera from `cameraFrom`).
    func makeBundle(segments specs: [SegSpec], cameraEnabled: Bool) async throws -> ProjectBundle {
        let bundle = try ProjectBundle.create(in: Synthetic.temporaryFolder())
        var segments: [Project.Segment] = []
        for (index, spec) in specs.enumerated() {
            let file = ProjectBundle.segmentFileName(index: index)
            let config = WriterConfig(
                tracks: spec.tracks, screenSize: PixelSize(width: 320, height: 200), cameraSize: PixelSize(width: 160, height: 90),
                codec: .h264, fps: 30, videoBitrate: 1_000_000)
            let writer = try SegmentWriter(url: bundle.segmentURL(file), config: config)
            let base = 1000.0 * Double(index + 1)
            for i in 0..<Int(spec.seconds * 30) {
                let t = Double(i) / 30
                let pts = Synthetic.seconds(base + t)
                writer.append(Synthetic.video(width: 320, height: 200, pts: pts, rgb: (255, 0, 0)), as: .screen)
                if spec.tracks.contains(.camera), t >= spec.cameraFrom {
                    writer.append(Synthetic.video(width: 160, height: 90, pts: pts, rgb: (0, 255, 0)), as: .camera)
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            let duration = try #require(try await writer.finish(at: Synthetic.seconds(base + spec.seconds)))
            segments.append(.init(file: file, duration: duration, tracks: writer.writtenTracks))
        }
        try bundle.write(
            Project(
                status: .finished,
                capture: .init(target: .display, pixelSize: PixelSize(width: 320, height: 200), fps: 30, codec: .h264),
                segments: segments,
                camera: .init(enabled: cameraEnabled, size: 0.3, keyframes: [BubbleKeyframe(t: 0, x: 0.5, y: 0.5)]),
                effects: .init(cursorHighlight: false, clickRipples: false)
            ))
        return bundle
    }

    func rgb(at seconds: Double, x: Int, y: Int, in url: URL) async throws -> (Int, Int, Int) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        var rgba = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    }

    @Test func compositesBubbleAndMixesAudioToOneTrack() async throws {
        let bundle = try await makeBundle(durations: [1], camera: true, audio: true, effects: false)
        let url = try await Exporter().export(bundle)
        #expect(url.pathExtension == "mp4")

        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)

        let center = try await rgb(at: 0.5, x: 160, y: 100, in: url)
        #expect(center.1 > 180 && center.0 < 80, "bubble center \(center)")
        let corner = try await rgb(at: 0.5, x: 5, y: 5, in: url)
        #expect(corner.0 > 180 && corner.1 < 80, "screen corner \(corner)")
    }

    @Test func concatenatesSegments() async throws {
        let bundle = try await makeBundle(durations: [1, 0.5], camera: true, audio: false, effects: true)
        let url = try await Exporter().export(bundle)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 1.5) < 0.1, "duration \(duration)")
    }

    @Test func passthroughWhenNothingToComposite() async throws {
        let bundle = try await makeBundle(durations: [1, 1], camera: false, audio: false, effects: false)
        let progress = ProgressLog()
        let url = try await Exporter().export(bundle) { progress.record($0) }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 2) < 0.1, "duration \(duration)")
        #expect(progress.last == 1)
    }

    @Test func exportPreservesMidtones() async throws {
        let bundle = try await makeBundle(durations: [1], camera: true, audio: false, effects: false, screen: (200, 128, 60))
        let sourceURL = bundle.segmentURL(ProjectBundle.segmentFileName(index: 0))
        let exportedURL = try await Exporter().export(bundle)

        let source = try await rgb(at: 0.5, x: 5, y: 5, in: sourceURL)
        let exported = try await rgb(at: 0.5, x: 5, y: 5, in: exportedURL)
        #expect(abs(source.0 - exported.0) <= 3, "R source \(source) export \(exported)")
        #expect(abs(source.1 - exported.1) <= 3, "G source \(source) export \(exported)")
        #expect(abs(source.2 - exported.2) <= 3, "B source \(source) export \(exported)")
    }

    @Test func cameraEnabledWithoutCameraTrackExports() async throws {
        let bundle = try await makeBundle(durations: [1], camera: false, audio: false, effects: false, cameraEnabled: true)
        let url = try await Exporter().export(bundle)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 1) < 0.1, "duration \(duration)")
    }

    @Test func needsCompositingFalseWhenDataAbsent() {
        let project = Project(
            capture: .init(target: .display, pixelSize: PixelSize(width: 1, height: 1), fps: 30, codec: .h264),
            camera: .init(enabled: true),
            effects: .init(cursorHighlight: true, clickRipples: true)
        )
        #expect(!Exporter.needsCompositing(project: project, cursor: CursorTrack(), hasCameraTrack: false))
    }

    @Test func needsCompositingTrueWithCameraTrack() {
        let project = Project(
            capture: .init(target: .display, pixelSize: PixelSize(width: 1, height: 1), fps: 30, codec: .h264),
            camera: .init(enabled: true),
            effects: .init(cursorHighlight: false, clickRipples: false)
        )
        #expect(Exporter.needsCompositing(project: project, cursor: CursorTrack(), hasCameraTrack: true))
    }

    @Test func needsCompositingTrueWithCursorSample() {
        let project = Project(
            capture: .init(target: .display, pixelSize: PixelSize(width: 1, height: 1), fps: 30, codec: .h264),
            camera: .init(enabled: false),
            effects: .init(cursorHighlight: true, clickRipples: false)
        )
        let cursor = CursorTrack(samples: [CursorSample(t: 0, x: 0.5, y: 0.5)])
        #expect(Exporter.needsCompositing(project: project, cursor: cursor, hasCameraTrack: false))
    }

    @Test func needsCompositingTrueWithClicks() {
        let project = Project(
            capture: .init(target: .display, pixelSize: PixelSize(width: 1, height: 1), fps: 30, codec: .h264),
            camera: .init(enabled: false),
            effects: .init(cursorHighlight: false, clickRipples: true)
        )
        let cursor = CursorTrack(clicks: [ClickEvent(t: 0, x: 0.5, y: 0.5)])
        #expect(Exporter.needsCompositing(project: project, cursor: cursor, hasCameraTrack: false))
    }

    @Test func hiddenCameraIsNotExported() async throws {
        let bundle = try await makeBundle(segments: [SegSpec(seconds: 1, tracks: [.screen, .camera])], cameraEnabled: false)
        let url = try await Exporter().export(bundle)
        let videos = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        #expect(videos.count == 1, "video tracks in output: \(videos.count)")
    }

    @Test func bubbleDisappearsWhenCameraTrackEnds() async throws {
        let bundle = try await makeBundle(
            segments: [SegSpec(seconds: 1, tracks: [.screen, .camera]), SegSpec(seconds: 1, tracks: [.screen])], cameraEnabled: true)
        let url = try await Exporter().export(bundle)
        let after = try await rgb(at: 1.5, x: 160, y: 100, in: url)
        #expect(after.0 > 180 && after.1 < 80, "bubble center after camera track ends \(after)")
    }

    @Test func emptyRecordingThrowsReadableError() async throws {
        let bundle = try await makeBundle(segments: [], cameraEnabled: false)
        do {
            _ = try await Exporter().export(bundle)
            Issue.record("expected throw")
        } catch {
            #expect(error.localizedDescription.contains("no video"), "description: \(error.localizedDescription)")
        }
    }

    @Test func audioNeedsMixingWhenMicVolumeAdjusted() {
        let project = Project(
            capture: .init(target: .display, pixelSize: PixelSize(width: 1, height: 1), fps: 30, codec: .h264),
            camera: .init(enabled: false),
            audio: .init(systemVolume: 1, micVolume: 0.5)
        )
        #expect(Exporter.audioNeedsMixing(project: project, presentAudio: [.mic]))
    }

    @Test func audioNeedsMixingIgnoresAbsentTracks() {
        let project = Project(
            capture: .init(target: .display, pixelSize: PixelSize(width: 1, height: 1), fps: 30, codec: .h264),
            camera: .init(enabled: false),
            audio: .init(systemVolume: 0.5, micVolume: 1)
        )
        #expect(!Exporter.audioNeedsMixing(project: project, presentAudio: [.mic]))
    }

    @Test func audioNeedsMixingFalseAtDefaultVolumes() {
        let project = Project(
            capture: .init(target: .display, pixelSize: PixelSize(width: 1, height: 1), fps: 30, codec: .h264),
            camera: .init(enabled: false)
        )
        #expect(!Exporter.audioNeedsMixing(project: project, presentAudio: [.system, .mic]))
    }
}

final class ProgressLog: Sendable {
    private let values = Mutex<[Double]>([])
    func record(_ value: Double) { values.withLock { $0.append(value) } }
    var last: Double? { values.withLock { $0.last } }
}

@Suite struct ExportPlacementTests {
    @Test func exportLandsAtBundleExportURLWithNoPartialLeft() async throws {
        let bundle = try await ExporterTests().makeBundle(durations: [1], camera: false, audio: false, effects: false)
        let url = try await Exporter().export(bundle)
        #expect(url == bundle.exportURL)
        #expect(bundle.hasExport)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundle.exportsURL.path).filter { $0.contains("partial") }
        #expect(leftovers.isEmpty)
    }
}
