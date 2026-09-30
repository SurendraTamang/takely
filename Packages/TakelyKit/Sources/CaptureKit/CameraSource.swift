@preconcurrency import AVFoundation
import ProjectKit

/// Camera frames from a capture session the app owns (it also feeds the bubble's live preview, so the camera is
/// already warm when recording starts). `start` adds a video output to the session and starts it if needed;
/// `stop` removes the output and leaves the session to its owner.
///
/// `@unchecked Sendable`: the session is only configured on `queue`, the owner's session queue.
public final class CameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session: AVCaptureSession
    private let queue: DispatchQueue
    private let router: FrameRouter
    private let output = AVCaptureVideoDataOutput()
    private let outputQueue = DispatchQueue(label: "app.takely.capture.camera", qos: .userInteractive)

    /// - Parameters:
    ///   - session: a session with a camera input.
    ///   - queue: the serial queue the session is configured and started on.
    public init(router: FrameRouter, session: AVCaptureSession, queue: DispatchQueue) {
        self.router = router
        self.session = session
        self.queue = queue
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
    }

    public func start() async throws {
        let running = await withCheckedContinuation { continuation in
            queue.async {
                self.session.beginConfiguration()
                let added = !self.session.inputs.isEmpty && self.session.canAddOutput(self.output)
                if added { self.session.addOutput(self.output) }
                self.session.commitConfiguration()
                if added, !self.session.isRunning { self.session.startRunning() }
                continuation.resume(returning: added && self.session.isRunning)
            }
        }
        guard running else { throw CaptureError.noCamera }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.session.outputs.contains(self.output) { self.session.removeOutput(self.output) }
                continuation.resume()
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let host = CMClockGetHostTimeClock()
        let pts = sampleBuffer.presentationTimeStamp
        let hostPTS = CMSyncConvertTime(pts, from: session.synchronizationClock ?? host, to: host)
        let buffer = hostPTS == pts ? sampleBuffer : (sampleBuffer.retimed(to: hostPTS) ?? sampleBuffer)
        router.receive(buffer, kind: .camera)
    }
}
