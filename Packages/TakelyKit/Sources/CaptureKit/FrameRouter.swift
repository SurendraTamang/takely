import CoreGraphics
import CoreMedia
import ProjectKit
import Synchronization

/// Hands buffers from capture queues to the current segment and records cursor data.
/// Called per frame from source queues, so it never hops actors.
public final class FrameRouter: Sendable {
    private struct State {
        var writer: SegmentWriter?
        /// Edited-timeline time at which the current segment starts.
        var offset: Double = 0
        var cursor = CursorTrack()
        var lastScreen: UncheckedBuffer?
    }

    private let state = Mutex(State())
    private let captureRect: CGRect
    private let cursorLocation: @Sendable () -> CGPoint?
    private let report: @Sendable (CaptureEvent.Kind, any Error) -> Void

    /// - Parameters:
    ///   - cursorLocation: global cursor position in points, origin top-left.
    ///   - report: forwards stream failures to the owning session's event stream.
    public init(
        captureRect: CGRect,
        cursorLocation: @escaping @Sendable () -> CGPoint? = { CGEvent(source: nil)?.location },
        report: @escaping @Sendable (CaptureEvent.Kind, any Error) -> Void = { _, _ in }
    ) {
        self.captureRect = captureRect
        self.cursorLocation = cursorLocation
        self.report = report
    }

    /// Called by a source whose stream stopped on its own.
    public func reportStreamStopped(_ error: any Error, userInitiated: Bool) {
        report(.streamStopped(userInitiated: userInitiated), error)
    }

    /// Drops cursor samples and clicks at or after `t`, used when a segment starting at `t` couldn't be saved.
    func discardCursor(from t: Double) {
        state.withLock { s in
            s.cursor.samples.removeAll { $0.t >= t }
            s.cursor.clicks.removeAll { $0.t >= t }
        }
    }

    func attach(_ writer: SegmentWriter?, offset: Double) {
        state.withLock {
            $0.writer = writer
            $0.offset = offset
        }
    }

    public var cursor: CursorTrack { state.withLock { $0.cursor } }

    public func receive(_ buffer: CMSampleBuffer, kind: TrackKind) {
        let (writer, offset) = state.withLock { s -> (SegmentWriter?, Double) in
            // Only keep the newest screen frame, so `prime`'s retimed copy can't clobber a newer live one.
            if kind == .screen, s.lastScreen.map({ buffer.presentationTimeStamp > $0.buffer.presentationTimeStamp }) ?? true {
                s.lastScreen = UncheckedBuffer(buffer: buffer)
            }
            return (s.writer, s.offset)
        }
        guard let writer, writer.append(buffer, as: kind), kind == .screen,
            let start = writer.startTime, let point = normalizedCursor()
        else { return }
        let t = offset + (buffer.presentationTimeStamp - start).seconds
        state.withLock { $0.cursor.samples.append(CursorSample(t: t, x: point.x, y: point.y)) }
    }

    /// Starts the attached segment at `hostTime` with the last screen frame, so a static screen doesn't delay it.
    func prime(at hostTime: CMTime) {
        guard let last = state.withLock({ $0.lastScreen })?.buffer, let retimed = last.retimed(to: hostTime) else { return }
        receive(retimed, kind: .screen)
    }

    /// Records a click at host time `hostTime` if a segment is running.
    public func recordClick(at hostTime: CMTime) {
        guard let point = normalizedCursor() else { return }
        state.withLock { s in
            guard let start = s.writer?.startTime, hostTime >= start else { return }
            let t = s.offset + (hostTime - start).seconds
            s.cursor.clicks.append(ClickEvent(t: t, x: point.x, y: point.y))
        }
    }

    /// Positions outside the capture area are kept (they render off-canvas).
    private func normalizedCursor() -> NormalizedPoint? {
        guard let p = cursorLocation(), captureRect.width > 0, captureRect.height > 0 else { return nil }
        return NormalizedPoint(
            x: (p.x - captureRect.minX) / captureRect.width,
            y: (p.y - captureRect.minY) / captureRect.height
        )
    }
}
