/// A capture source that pushes buffers into a `FrameRouter` it was created with.
public protocol FrameSource: Sendable {
    func start() async throws
    func stop() async
}
