@preconcurrency import AVFoundation
import ProjectKit

/// Default camera at 720p30.
///
/// `@unchecked Sendable`: `session` is configured in `init` and only started/stopped on `sessionQueue`.
public final class CameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    private let router: FrameRouter
    private let outputQueue = DispatchQueue(label: "app.takely.capture.camera", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "app.takely.capture.camera-session")

    public init(router: FrameRouter, device: AVCaptureDevice? = .default(for: .video)) throws {
        self.router = router
        super.init()
        guard let device else { throw CaptureError.noCamera }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.noCamera }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else { throw CaptureError.noCamera }
        session.addOutput(output)
    }

    public func start() async throws {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.session.startRunning()
                continuation.resume()
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.session.stopRunning()
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
