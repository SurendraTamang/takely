import ProjectKit

/// Something that ended or broke a recording without the user pressing Stop.
public struct CaptureEvent: Sendable {
    public enum Kind: Sendable, Equatable {
        /// The screen stream stopped: display unplugged, permission revoked, or the user clicked the
        /// system "Stop sharing" control (`userInitiated`).
        case streamStopped(userInitiated: Bool)
        /// A segment's writer failed (disk error, bad format); later buffers are rejected.
        case writerFailed
    }

    /// The recording this came from, so a late event can't stop a newer recording.
    public let recordingID: Int
    public let kind: Kind
    public let error: any Error

    public init(recordingID: Int, kind: Kind, error: any Error) {
        self.recordingID = recordingID
        self.kind = kind
        self.error = error
    }
}

/// What `CaptureSession.start` hands back for one recording.
public struct RecordingHandle: Sendable {
    public let id: Int
    public let bundle: ProjectBundle
    public let router: FrameRouter

    public init(id: Int, bundle: ProjectBundle, router: FrameRouter) {
        self.id = id
        self.bundle = bundle
        self.router = router
    }
}

/// What `CaptureSession.stop` saved. `failure` is set when the last segment couldn't be closed:
/// the bundle then holds the recording up to that segment.
public struct StoppedRecording: Sendable {
    public let bundle: ProjectBundle
    public let failure: (any Error)?

    public init(bundle: ProjectBundle, failure: (any Error)?) {
        self.bundle = bundle
        self.failure = failure
    }
}
