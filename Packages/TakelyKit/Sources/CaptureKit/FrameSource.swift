/// A capture source that pushes buffers into a `FrameRouter` it was created with.
///
/// `stop()` must be idempotent and safe to call even if `start()` never ran or threw.
public protocol FrameSource: Sendable {
    func start() async throws
    func stop() async
}
