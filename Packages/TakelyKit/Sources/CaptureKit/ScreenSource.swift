import CoreMedia
import OSLog
import ProjectKit
@preconcurrency import ScreenCaptureKit

/// Screen, system audio and microphone from one `SCStream`.
///
/// `@unchecked Sendable`: `stream` is set once in `start()` before any callback and cleared in `stop()`.
public final class ScreenSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let router: FrameRouter
    private let videoQueue = DispatchQueue(label: "app.takely.capture.screen", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "app.takely.capture.audio", qos: .userInteractive)
    private var stream: SCStream?
    private let log = Logger(subsystem: "app.takely", category: "capture")

    public init(filter: SCContentFilter, config: RecordingConfig, sourceRect: CGRect?, router: FrameRouter) {
        self.filter = filter
        self.configuration = Self.streamConfiguration(for: config, sourceRect: sourceRect)
        self.router = router
    }

    public static func streamConfiguration(for config: RecordingConfig, sourceRect: CGRect?) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let size = config.outputSize
        c.width = size.width
        c.height = size.height
        if let sourceRect { c.sourceRect = sourceRect }
        // A window can be resized while recording: keep it inside the fixed output frame (letterboxed).
        c.scalesToFit = config.target == .window
        c.preservesAspectRatio = true
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // Pin sRGB + Rec. 709 so files look the same in every player (the display default is often Display P3).
        c.colorSpaceName = CGColorSpace.sRGB
        c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        c.showsCursor = true
        c.queueDepth = 6
        c.capturesAudio = config.systemAudio
        c.excludesCurrentProcessAudio = true
        c.sampleRate = 48_000
        c.channelCount = 2
        c.captureMicrophone = config.microphone
        if let id = config.microphoneDeviceID { c.microphoneCaptureDeviceID = id }
        return c
    }

    public func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if configuration.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if configuration.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        do {
            try await stream?.stopCapture()
        } catch {
            log.error("stopCapture failed: \(error.localizedDescription)")
        }
        stream = nil
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            router.receive(sampleBuffer, kind: .screen)
        case .audio:
            router.receive(sampleBuffer, kind: .system)
        case .microphone:
            router.receive(sampleBuffer, kind: .mic)
        @unknown default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("stream stopped: \(error.localizedDescription)")
        let userInitiated = (error as? SCStreamError)?.code == .userStopped
        router.reportStreamStopped(error, userInitiated: userInitiated)
    }

    /// Frames with pixels: `.complete`, and `.started` (the first frame). `.idle` etc. carry none.
    static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard buffer.imageBuffer != nil,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete || status == .started
    }
}
