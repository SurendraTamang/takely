import CoreGraphics
import ProjectKit
import Testing

@testable import CaptureKit

@Suite struct RecordingConfigTests {
    func config(_ w: Int, _ h: Int, _ resolution: Resolution, fps: Int = 30, codec: VideoCodec = .hevc) -> RecordingConfig {
        RecordingConfig(
            target: .display, captureRect: .zero, sourcePixelSize: PixelSize(width: w, height: h), resolution: resolution, fps: fps,
            codec: codec)
    }

    @Test func scalesRetinaDisplayTo1080p() {
        #expect(config(2880, 1800, .p1080).outputSize == PixelSize(width: 1728, height: 1080))
    }

    @Test func neverUpscales() {
        #expect(config(1280, 800, .p1080).outputSize == PixelSize(width: 1280, height: 800))
    }

    @Test func nativeRoundsToEvenDimensions() {
        #expect(config(1001, 777, .native).outputSize == PixelSize(width: 1000, height: 776))
    }

    @Test func tinySourcesStayEncodable() {
        #expect(config(1, 1, .native).outputSize == PixelSize(width: 2, height: 2))
    }

    @Test func bitrateFollowsPresetTable() {
        #expect(config(2880, 1800, .p1080, codec: .h264).videoBitrate == 8_000_000)
        #expect(config(2880, 1800, .p1080, fps: 60, codec: .hevc).videoBitrate == 7_500_000)
        #expect(config(2880, 1800, .p720, codec: .hevc).videoBitrate == 3_000_000)
    }

    @Test func tracksFollowToggles() {
        var c = config(100, 100, .native)
        c.camera = true
        c.systemAudio = false
        #expect(c.tracks == [.screen, .camera, .mic])
    }

    @Test func h264NativeFitsEncoderLimits() {
        let size = config(5120, 2880, .native, codec: .h264).outputSize
        #expect(size.width <= 4096 && size.height <= 2304)
        #expect(size == PixelSize(width: 4096, height: 2304))
    }

    @Test func hevcNativeKeepsFullSize() {
        #expect(config(5120, 2880, .native, codec: .hevc).outputSize == PixelSize(width: 5120, height: 2880))
    }
}
