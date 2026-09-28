import AVFoundation
import CoreImage
import Synchronization

/// Carries the renderer and track IDs to the compositor.
final class TakelyInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let renderer: FrameRenderer

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, renderer: FrameRenderer) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.renderer = renderer
        requiredSourceTrackIDs = ([screenTrackID] + (cameraTrackID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

enum RenderError: Error {
    case missingFrame
    case exportUnavailable
    case trackMismatch(String)
}

/// `AVVideoCompositing` that delegates to `FrameRenderer`.
final class TakelyCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    /// Last screen frame, reused when the screen track has a gap (static screen at a segment end).
    private let lastScreen = Mutex<UncheckedPixelBuffer?>(nil)

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? TakelyInstruction,
            let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: RenderError.missingFrame)
            return
        }
        let screen: CVPixelBuffer
        if let frame = request.sourceFrame(byTrackID: instruction.screenTrackID) {
            lastScreen.withLock { $0 = UncheckedPixelBuffer(buffer: frame) }
            screen = frame
        } else if let cached = lastScreen.withLock({ $0 }) {
            screen = cached.buffer
        } else {
            request.finish(with: RenderError.missingFrame)
            return
        }
        let camera = instruction.cameraTrackID
            .flatMap { request.sourceFrame(byTrackID: $0) }
            .map { CIImage(cvPixelBuffer: $0) }
        let image = instruction.renderer.compose(
            screen: CIImage(cvPixelBuffer: screen), camera: camera, at: request.compositionTime.seconds)
        instruction.renderer.context.render(image, to: output)
        request.finish(withComposedVideoFrame: output)
    }
}

/// Decoded frames are read-only once handed to the compositor.
private struct UncheckedPixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
