import CoreGraphics
import CoreMedia
import OSLog
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
    /// Nil when cancellation is off or AEC3 couldn't start: then `mic` gets the raw microphone.
    private let echo: Mutex<EchoCanceller?>
    private let cancelsEcho: Bool
    private let captureRect: CGRect
    private let cursorLocation: @Sendable () -> CGPoint?
    private let report: @Sendable (CaptureEvent.Kind, any Error) -> Void

    /// - Parameters:
    ///   - cancelsEcho: write the echo-cancelled microphone to `mic` and the original to `micRaw`.
    ///   - cursorLocation: global cursor position in points, origin top-left.
    ///   - report: forwards stream failures to the owning session's event stream.
    public init(
        captureRect: CGRect,
        cancelsEcho: Bool = false,
        cursorLocation: @escaping @Sendable () -> CGPoint? = { CGEvent(source: nil)?.location },
        report: @escaping @Sendable (CaptureEvent.Kind, any Error) -> Void = { _, _ in }
    ) {
        self.captureRect = captureRect
        self.cursorLocation = cursorLocation
        self.report = report
        self.cancelsEcho = cancelsEcho
        let canceller = cancelsEcho ? EchoCanceller() : nil
        if cancelsEcho && canceller == nil { Self.log.error("echo cancellation unavailable; recording the raw microphone") }
        self.echo = Mutex(canceller)
    }

    private static let log = Logger(subsystem: "app.takely", category: "capture")

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
        // Cleaned microphone audio still waiting for its reference belongs to the segment being detached.
        if let detached = state.withLock({ $0.writer }) {
            withCanceller(writing: nil, to: detached) { $0.flush() }
        }
        state.withLock {
            $0.writer = writer
            $0.offset = offset
        }
    }

    public var cursor: CursorTrack { state.withLock { $0.cursor } }

    public func receive(_ buffer: CMSampleBuffer, kind: TrackKind) {
        if cancelsEcho, kind == .system || kind == .mic { return receiveWithEchoCancellation(buffer, kind: kind) }
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

    /// System audio is written and becomes the echo reference; the microphone goes to `micRaw` as captured and to
    /// `mic` cleaned. Both streams arrive on one ScreenCaptureKit queue, so the canceller's lock isn't contended.
    private func receiveWithEchoCancellation(_ buffer: CMSampleBuffer, kind: TrackKind) {
        let writer = state.withLock { $0.writer }
        writer?.append(buffer, as: kind == .mic ? .micRaw : .system)
        withCanceller(writing: kind == .mic ? buffer : nil, to: writer) { canceller in
            guard kind == .mic else {
                canceller.addReference(buffer)
                return []
            }
            return canceller.clean(buffer)
        }
    }

    /// Runs `body` on the canceller and writes its output to `mic`, under the canceller's lock so cleaned audio
    /// reaches the writer in order. Without a canceller (AEC3 couldn't start), `raw` goes to `mic` as captured.
    private func withCanceller(
        writing raw: CMSampleBuffer?, to writer: SegmentWriter?, _ body: (EchoCanceller) -> [CMSampleBuffer]
    ) {
        echo.withLock { canceller in
            guard let canceller else {
                if let raw { writer?.append(raw, as: .mic) }
                return
            }
            for cleaned in body(canceller) { writer?.append(cleaned, as: .mic) }
        }
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
