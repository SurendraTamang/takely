import CoreImage
import CoreImage.CIFilterBuiltins
import ProjectKit
import Testing

@testable import RenderKit

@Suite(.serialized) struct FrameRendererTests {
    /// Unmanaged color so sampled bytes equal the input colors exactly.
    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    let canvas = CGRect(x: 0, y: 0, width: 400, height: 250)
    let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 250))
    let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))

    func project(camera: Bool, highlight: Bool = false, ripples: Bool = false, shape: BubbleShape = .circle) -> Project {
        Project(
            capture: .init(target: .display, pixelSize: PixelSize(width: 400, height: 250), fps: 30, codec: .h264),
            camera: .init(enabled: camera, shape: shape, size: 0.25, keyframes: [BubbleKeyframe(t: 0, x: 0.5, y: 0.5)]),
            effects: .init(cursorHighlight: highlight, clickRipples: ripples)
        )
    }

    /// RGBA of one pixel, addressed in Core Image coordinates (origin bottom-left).
    func pixel(_ image: CIImage, _ x: Double, _ y: Double) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return rgba
    }

    @Test func outputIsCroppedToCanvas() {
        let renderer = FrameRenderer(project: project(camera: true), cursor: CursorTrack(), context: context)
        #expect(renderer.compose(screen: red, camera: green, at: 0).extent == canvas)
    }

    @Test func bubbleShowsCameraAtKeyframeCenter() {
        let renderer = FrameRenderer(project: project(camera: true), cursor: CursorTrack(), context: context)
        let image = renderer.compose(screen: red, camera: green, at: 0)
        #expect(pixel(image, 200, 125) == [0, 255, 0, 255])
        #expect(pixel(image, 5, 5) == [255, 0, 0, 255])
    }

    @Test func circleBubbleLeavesItsCornersAlone() {
        // 100 px bubble centered at (200,125): its bounding-box corner (151,76) is outside the circle.
        let renderer = FrameRenderer(project: project(camera: true), cursor: CursorTrack(), context: context)
        let corner = pixel(renderer.compose(screen: red, camera: green, at: 0), 151, 76)
        #expect(corner[0] > 150 && corner[1] < 100)
        let square = FrameRenderer(project: project(camera: true, shape: .square), cursor: CursorTrack(), context: context)
        #expect(pixel(square.compose(screen: red, camera: green, at: 0), 152, 77) == [0, 255, 0, 255])
    }

    @Test func bubbleFollowsKeyframeVertically() {
        // Keyframe at normalized y = 0.2 (near the top) → Core Image y = (1 - 0.2) × 250 = 200.
        var p = project(camera: true)
        p.camera.keyframes = [BubbleKeyframe(t: 0, x: 0.5, y: 0.2)]
        let renderer = FrameRenderer(project: p, cursor: CursorTrack(), context: context)
        let image = renderer.compose(screen: red, camera: green, at: 0)
        #expect(pixel(image, 200, 200) == [0, 255, 0, 255])
        #expect(pixel(image, 200, 50) == [255, 0, 0, 255])
    }

    @Test func disabledCameraShowsScreenOnly() {
        let renderer = FrameRenderer(project: project(camera: false), cursor: CursorTrack(), context: context)
        #expect(pixel(renderer.compose(screen: red, camera: green, at: 0), 200, 125) == [255, 0, 0, 255])
    }

    @Test func cursorHighlightTintsAroundCursor() {
        // Cursor at normalized (0.1, 0.2) → CI pixel (40, 200).
        let cursor = CursorTrack(samples: [CursorSample(t: 0, x: 0.1, y: 0.2)])
        let renderer = FrameRenderer(project: project(camera: false, highlight: true), cursor: cursor, context: context)
        let image = renderer.compose(screen: red, camera: nil, at: 0)
        #expect(pixel(image, 40, 200)[1] > 50)  // yellow over red raises green
        #expect(pixel(image, 300, 50) == [255, 0, 0, 255])
    }

    @Test func burnedInCaptionsShowOnlyWhileTheirCueIsOn() {
        var p = project(camera: false)
        p.effects.burnInCaptions = true
        let renderer = FrameRenderer(
            project: p, cursor: CursorTrack(), captions: [CaptionCue(start: 1, end: 2, text: "Hello")], context: context)
        // The caption box sits in the bottom band; its dark backing changes pixels there while the cue is on.
        let during = renderer.compose(screen: red, camera: nil, at: 1.5)
        let before = renderer.compose(screen: red, camera: nil, at: 0.5)
        let changed = (0..<40).contains { i in pixel(during, 160 + Double(i) * 2, 20) != pixel(before, 160 + Double(i) * 2, 20) }
        #expect(changed)
        #expect(pixel(before, 200, 20) == [255, 0, 0, 255])
        #expect(pixel(during, 5, 240) == [255, 0, 0, 255], "only the bottom band is touched")
    }

    @Test func captionsAreOffUnlessBurnInIsOn() {
        let renderer = FrameRenderer(
            project: project(camera: false), cursor: CursorTrack(), captions: [CaptionCue(start: 0, end: 5, text: "Hello")],
            context: context)
        #expect(pixel(renderer.compose(screen: red, camera: nil, at: 1), 200, 20) == [255, 0, 0, 255])
    }

    @Test func redactionsBlurTheirBoxWhileActive() {
        // 1-px black/white stripes: blurred they turn mid-grey; untouched they stay pure black or white.
        let stripes = CIFilter.stripesGenerator()
        stripes.color0 = CIColor(red: 0, green: 0, blue: 0)
        stripes.color1 = CIColor(red: 1, green: 1, blue: 1)
        stripes.width = 1
        let screen = stripes.outputImage!.cropped(to: canvas)
        let redaction = Redaction(
            kind: .apiKey, preview: "sk-…", track: [.init(t: 0, rect: NormalizedRect(x: 0.25, y: 0.4, width: 0.5, height: 0.2))])
        let renderer = FrameRenderer(project: project(camera: false), cursor: CursorTrack(), redactions: [redaction], context: context)
        #expect(renderer.hasRedactions)
        // Box centre (200, 125) in CI coordinates.
        let inside = pixel(renderer.compose(screen: screen, camera: nil, at: 0.2), 200, 125)
        #expect(inside[0] > 60 && inside[0] < 195, "blurred to grey: \(inside)")
        let outside = pixel(renderer.compose(screen: screen, camera: nil, at: 0.2), 10, 10)
        #expect(outside[0] < 5 || outside[0] > 250, "untouched: \(outside)")
        let later = pixel(renderer.compose(screen: screen, camera: nil, at: 2), 200, 125)
        #expect(later[0] < 5 || later[0] > 250, "inactive after its time: \(later)")
    }

    @Test func clickPulseFadesOut() {
        let cursor = CursorTrack(clicks: [ClickEvent(t: 1, x: 0.5, y: 0.5)])
        let renderer = FrameRenderer(project: project(camera: false, ripples: true), cursor: cursor, context: context)
        let during = pixel(renderer.compose(screen: red, camera: nil, at: 1.05), 200, 125)
        let after = pixel(renderer.compose(screen: red, camera: nil, at: 1.5), 200, 125)
        #expect(during[1] > 50)
        #expect(after == [255, 0, 0, 255])
    }

    @Test func composesA1080pFrameWithinBudget() throws {
        let big = Project(
            capture: .init(target: .display, pixelSize: PixelSize(width: 1920, height: 1080), fps: 30, codec: .hevc),
            camera: .init(enabled: true)
        )
        let cursor = CursorTrack(samples: [CursorSample(t: 0, x: 0.5, y: 0.5)], clicks: [ClickEvent(t: 0, x: 0.5, y: 0.5)])
        let renderer = FrameRenderer(project: big, cursor: cursor)
        var output: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 1920, 1080, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output)
        let target = try #require(output)
        let screen = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let camera = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        // Wait for the GPU so the timing covers real rendering, not just command encoding.
        let destination = CIRenderDestination(pixelBuffer: target)
        func renderFrame(_ i: Int) throws {
            let image = renderer.compose(screen: screen, camera: camera, at: Double(i) / 30)
            try renderer.context.startTask(toRender: image, to: destination).waitUntilCompleted()
        }
        let frames = 30
        // Warm up every frame index so each filter graph is compiled before timing starts.
        for i in 0..<frames { try renderFrame(i) }
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for i in 0..<60 { samples.append(try clock.measure { try renderFrame(i % frames) }) }
        // Median, not mean: a rare scheduler stall under parallel tests shouldn't fail the gate.
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        #expect(median < .milliseconds(8), "median \(median) p90 \(sorted[sorted.count * 9 / 10]) max \(sorted.last!)")
    }
}
