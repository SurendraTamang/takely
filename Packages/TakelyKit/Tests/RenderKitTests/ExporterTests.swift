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
            for kind in spec.tracks where !kind.isVideo {
                for i in 0..<Int(spec.seconds * 48_000 / 1024) {
                    writer.append(Synthetic.audio(pts: Synthetic.seconds(base + Double(i) * 1024 / 48_000)), as: kind)
                }
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

    @Test func markersBecomeChapters() async throws {
        let bundle = try await makeBundle(segments: [SegSpec(seconds: 3, tracks: [.screen, .mic])], cameraEnabled: false)
        try bundle.write([Marker(t: 1), Marker(t: 2.2)])
        let url = try await Exporter().export(bundle)
        let asset = AVURLAsset(url: url)
        let chapters = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en"])
        let titles = try await chapters.asyncMap { group in
            try await group.items.first?.load(.stringValue)
        }
        #expect(titles == ["Start", "Chapter 1", "Chapter 2"])
        #expect(chapters.map { $0.timeRange.start.seconds.rounded() } == [0, 1, 2])
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) < 0.1, "duration \(duration)")
    }

    @Test func transcriptBecomesCaptionsTrackAndVTT() async throws {
        let bundle = try await makeBundle(segments: [SegSpec(seconds: 3, tracks: [.screen, .mic])], cameraEnabled: false)
        try bundle.write(
            Transcript(
                locale: "en_US",
                phrases: [
                    .init(start: 0.2, end: 1.1, text: "Hello there", words: []),
                    .init(start: 1.6, end: 2.8, text: "Second line", words: []),
                ]))
        let url = try await Exporter().export(bundle)
        let asset = AVURLAsset(url: url)
        let subtitles = try await asset.loadTracks(withMediaType: .subtitle)
        #expect(subtitles.count == 1)
        #expect(try await subtitles.first?.load(.languageCode) == "eng")
        let texts = try Self.subtitleTexts(subtitles[0], in: asset)
        #expect(texts == ["Hello there", "Second line"])
        let vtt = try String(contentsOf: bundle.captionsURL, encoding: .utf8)
        #expect(vtt.hasPrefix("WEBVTT") && vtt.contains("00:00:00.200 --> 00:00:01.100\nHello there"))
    }

    @Test func cutsAreLeftOutAndChaptersAndCaptionsFollow() async throws {
        let bundle = try await makeBundle(
            segments: [SegSpec(seconds: 2, tracks: [.screen, .mic]), SegSpec(seconds: 2, tracks: [.screen, .mic])], cameraEnabled: false)
        try bundle.write(Edits(cuts: [TimeRange(start: 0.5, end: 1.5), TimeRange(start: 2.5, end: 3)]))
        try bundle.write([Marker(t: 1), Marker(t: 3.2)])  // the first is inside a cut
        try bundle.write(
            Transcript(
                locale: "en_US",
                phrases: [.init(start: 0.2, end: 0.8, text: "Kept part", words: []), .init(start: 1, end: 1.4, text: "Cut", words: [])]))
        let asset = AVURLAsset(url: try await Exporter().export(bundle))
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2.5) < 0.1, "duration \(duration)")
        let chapters = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en"])
        #expect(chapters.map { ($0.timeRange.start.seconds * 10).rounded() / 10 } == [0, 1.7])
        let vtt = try String(contentsOf: bundle.captionsURL, encoding: .utf8)
        #expect(vtt.contains("00:00:00.200 --> 00:00:00.500\nKept part") && !vtt.contains("Cut"))
    }

    @Test func joinsFadeTheAudioOutAndBackIn() async throws {
        let bundle = try await makeBundle(segments: [SegSpec(seconds: 2, tracks: [.screen, .mic])], cameraEnabled: false)
        let built = try await Exporter.compose(bundle, edits: Edits(cuts: [TimeRange(start: 0.5, end: 1)]))
        let parameters = try #require(built.audioMix?.inputParameters.first)
        var start: Float = -1
        var end: Float = -1
        var range = CMTimeRange.zero
        #expect(
            parameters.getVolumeRamp(
                for: CMTime(seconds: 0.49, preferredTimescale: 600), startVolume: &start, endVolume: &end, timeRange: &range))
        #expect(start == 1 && end == 0 && abs(range.end.seconds - 0.5) < 0.001)
        #expect(built.map.outputDuration == 1.5 || abs(built.map.outputDuration - 1.5) < 0.05)
    }

    @Test func titleAndSummaryGoIntoTheMovieAndMarkersKeepTheirNames() async throws {
        let bundle = try await makeBundle(segments: [SegSpec(seconds: 3, tracks: [.screen])], cameraEnabled: false)
        var project = try bundle.readProject()
        project.title = "Fixing the login bug"
        project.summary = "A walkthrough of the fix."
        try bundle.write(project)
        try bundle.write([Marker(t: 1.5, title: "The cause")])
        let asset = AVURLAsset(url: try await Exporter().export(bundle))
        let metadata = try await asset.load(.commonMetadata)
        let title = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first
        let description = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierDescription).first
        #expect(try await title?.load(.stringValue) == "Fixing the login bug")
        #expect(try await description?.load(.stringValue) == "A walkthrough of the fix.")
        let chapters = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en"])
        let names = try await chapters.asyncMap { try await $0.items.first?.load(.stringValue) }
        #expect(names == ["Start", "The cause"])
    }

    /// The text of each non-empty sample of a `tx3g` subtitle track.
    static func subtitleTexts(_ track: AVAssetTrack, in asset: AVAsset) throws -> [String] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var texts: [String] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = sample.dataBuffer else { continue }
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            bytes.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard bytes.count >= 2 else { continue }
            let length = Int(bytes[0]) << 8 | Int(bytes[1])
            if length > 0 { texts.append(String(decoding: bytes[2..<2 + length], as: UTF8.self)) }
        }
        return texts
    }

    @Test func withoutMarkersThereAreNoChapters() async throws {
        let bundle = try await makeBundle(segments: [SegSpec(seconds: 1, tracks: [.screen])], cameraEnabled: false)
        let url = try await Exporter().export(bundle)
        #expect(try await AVURLAsset(url: url).loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en"]).isEmpty)
    }

    @Test func rawMicIsNotExported() async throws {
        let bundle = try await makeBundle(segments: [SegSpec(seconds: 1, tracks: [.screen, .mic, .micRaw])], cameraEnabled: false)
        let url = try await Exporter().export(bundle)
        let audio = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        #expect(audio.count == 1, "audio tracks in output: \(audio.count)")
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

    @Test func reExportReplacesThePreviousExport() async throws {
        let bundle = try await ExporterTests().makeBundle(durations: [1], camera: false, audio: false, effects: false)
        _ = try await Exporter().export(bundle)
        let url = try await Exporter().export(bundle)  // e.g. Retry, or recovery re-exporting
        #expect(url == bundle.exportURL)
        #expect(bundle.hasExport)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundle.exportsURL.path).filter { $0.contains("partial") }
        #expect(leftovers.isEmpty)
    }
}
