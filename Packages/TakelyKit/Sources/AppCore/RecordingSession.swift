import CaptureKit
import Foundation
import ProjectKit
import RenderKit

/// One recording at a time: the app's adapter does the ScreenCaptureKit/camera setup; tests use a fake.
@MainActor
public protocol RecordingSession: AnyObject {
    /// Failures from any recording, tagged with the recording's ID.
    var events: AsyncStream<CaptureEvent> { get }
    /// Starts recording into a new bundle in `folder`, using the current settings.
    func start(in folder: URL) async throws -> RecordingHandle
    func pause() async throws
    func resume() async throws
    func stop() async throws -> ProjectBundle
    /// The engine's actual state, for resyncing after a failed pause or resume.
    func state() async -> CaptureSession.State
}

public protocol Exporting: Sendable {
    func export(_ bundle: ProjectBundle, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

extension Exporter: Exporting {}

/// How the controller tells the user what happened: the Ready notification and VoiceOver announcements.
@MainActor
public protocol RecordingFeedback: AnyObject {
    func recordingReady(_ url: URL, duration: Double)
    func announce(_ message: String)
}
