import AVFoundation
import CoreImage
import ProjectKit
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
    /// Time ranges the camera track actually covers; outside these, AVFoundation would otherwise repeat its last frame.
    let cameraCoverage: [CMTimeRange]
    let renderer: FrameRenderer
    /// Output time → recording time, where the renderer's data lives.
    let map: EditMap

    init(
        timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?,
        cameraCoverage: [CMTimeRange], renderer: FrameRenderer, map: EditMap
    ) {
        self.map = map
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.cameraCoverage = cameraCoverage
        self.renderer = renderer
        requiredSourceTrackIDs = ([screenTrackID] + (cameraTrackID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

enum RenderError: Error, LocalizedError {
    case missingFrame
    case exportUnavailable
    case trackMismatch(String)
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .missingFrame: "A video frame was missing during export."
        case .exportUnavailable: "This Mac can't export with the chosen settings."
        case .trackMismatch(let detail): "The recording's files don't match its manifest (\(detail))."
        case .emptyRecording: "This recording has no video to export."
        }
    }
}

/// `AVVideoCompositing` that delegates to `FrameRenderer`.
final class TakelyCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    /// Last screen frame, reused across sub-frame rounding gaps between segments.
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
        let camera: CIImage?
        if let cameraTrackID = instruction.cameraTrackID,
            instruction.cameraCoverage.contains(where: { $0.containsTime(request.compositionTime) }),
            let frame = request.sourceFrame(byTrackID: cameraTrackID)
        {
            camera = CIImage(cvPixelBuffer: frame)
        } else {
            camera = nil
        }
        let image = instruction.renderer.compose(
            screen: CIImage(cvPixelBuffer: screen), camera: camera, at: instruction.map.sourceTime(request.compositionTime.seconds),
            outputTime: request.compositionTime.seconds)
        instruction.renderer.context.render(image, to: output)
        request.finish(withComposedVideoFrame: output)
    }
}

/// Decoded frames are read-only once handed to the compositor.
private struct UncheckedPixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
