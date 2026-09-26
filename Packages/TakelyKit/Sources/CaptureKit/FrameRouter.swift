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

    /// - Parameter cursorLocation: global cursor position in points, origin top-left.
    public init(captureRect: CGRect, cursorLocation: @escaping @Sendable () -> CGPoint? = { CGEvent(source: nil)?.location }) {
        self.captureRect = captureRect
        self.cursorLocation = cursorLocation
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
            if kind == .screen { s.lastScreen = UncheckedBuffer(buffer: buffer) }
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
