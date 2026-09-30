import CoreGraphics
import ProjectKit
import Testing

@testable import CaptureKit

@Suite struct CaptureGeometryTests {
    let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// An external display to the left of the primary one, higher up: negative global origin.
    let external = CGRect(x: -2560, y: -300, width: 2560, height: 1440)

    @Test func sourceRectIsLocalToTheDisplay() {
        let region = CGRect(x: -2000, y: -100, width: 800, height: 600)
        #expect(CaptureGeometry.sourceRect(for: region, on: external) == CGRect(x: 560, y: 200, width: 800, height: 600))
        #expect(
            CaptureGeometry.sourceRect(for: CGRect(x: 10, y: 20, width: 100, height: 100), on: primary)
                == CGRect(x: 10, y: 20, width: 100, height: 100))
    }

    @Test func regionsAreClampedToTheirDisplayAndRounded() {
        let dragged = CGRect(x: 1400.4, y: 900.6, width: 300, height: 300)  // runs off the bottom-right corner
        #expect(CaptureGeometry.clamp(dragged, to: primary) == CGRect(x: 1400, y: 901, width: 112, height: 81))
    }

    @Test func regionsBelowTheMinimumAreRejected() {
        #expect(CaptureGeometry.clamp(CGRect(x: 10, y: 10, width: 63, height: 200), to: primary) == nil)
        #expect(CaptureGeometry.clamp(CGRect(x: 5000, y: 10, width: 200, height: 200), to: primary) == nil)
        #expect(CaptureGeometry.clamp(CGRect(x: 10, y: 10, width: 64, height: 64), to: primary) != nil)
    }

    @Test func draggingUpOrLeftStillMakesARegion() {
        let backwards = CGRect(x: 300, y: 300, width: -200, height: -150)
        #expect(CaptureGeometry.clamp(backwards, to: primary) == CGRect(x: 100, y: 150, width: 200, height: 150))
    }

    @Test func pixelSizeIsEven() {
        #expect(CaptureGeometry.pixelSize(of: CGRect(x: 0, y: 0, width: 101, height: 77), scale: 2) == PixelSize(width: 202, height: 154))
        #expect(CaptureGeometry.pixelSize(of: CGRect(x: 0, y: 0, width: 101, height: 77), scale: 1) == PixelSize(width: 100, height: 76))
    }

    @Test func windowsScaleIntoTheFrameAndMicrophoneDeviceIsPassed() {
        var config = RecordingConfig(
            target: .window, captureRect: .zero, sourcePixelSize: PixelSize(width: 1600, height: 1000), resolution: .native)
        config.microphoneDeviceID = "BuiltInMicrophoneDevice"
        let stream = ScreenSource.streamConfiguration(for: config, sourceRect: nil)
        #expect(stream.scalesToFit)
        #expect(stream.preservesAspectRatio)
        #expect(stream.microphoneCaptureDeviceID == "BuiltInMicrophoneDevice")
        config.target = .display
        #expect(!ScreenSource.streamConfiguration(for: config, sourceRect: nil).scalesToFit)
    }
}
