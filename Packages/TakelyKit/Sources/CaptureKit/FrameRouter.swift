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
        var camera: Project.Camera
        var markers: [Marker] = []
        var lastScreen: UncheckedBuffer?

        /// `hostTime` on the edited timeline, in the running segment; nil before its first frame.
        func editedTime(at hostTime: CMTime) -> Double? {
            guard let start = writer?.startTime, hostTime >= start else { return nil }
            return offset + (hostTime - start).seconds
        }
    }

    private let state: Mutex<State>
    /// Nil when cancellation is off or AEC3 couldn't start: then `mic` gets the raw microphone.
    private let echo: Mutex<EchoCanceller?>
    /// Pauses in the microphone, for the oops-retake; fed from the audio queue.
    private let silence = Mutex<(detector: SilenceDetector, downmixer: Downmixer?)>((SilenceDetector(), nil))
    private let cancelsEcho: Bool
    private let captureRect: CGRect
    private let cursorLocation: @Sendable () -> CGPoint?
    private let report: @Sendable (CaptureEvent.Kind, any Error) -> Void

    /// - Parameters:
    ///   - cancelsEcho: write the echo-cancelled microphone to `mic` and the original to `micRaw`.
    ///   - camera: the bubble's starting shape, size and keyframes; moves are added by `recordBubble`.
    ///   - cursorLocation: global cursor position in points, origin top-left.
    ///   - report: forwards stream failures to the owning session's event stream.
    public init(
        captureRect: CGRect,
        cancelsEcho: Bool = false,
        camera: Project.Camera = Project.Camera(enabled: false),
        cursorLocation: @escaping @Sendable () -> CGPoint? = { CGEvent(source: nil)?.location },
        report: @escaping @Sendable (CaptureEvent.Kind, any Error) -> Void = { _, _ in }
    ) {
        self.state = Mutex(State(camera: camera))
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

    /// Drops everything recorded at or after edited time `t` (cursor, clicks, bubble moves, markers, pauses):
    /// a segment starting at `t` couldn't be saved, or a retake cut there.
    func discard(from t: Double) {
        state.withLock { s in
            s.cursor.samples.removeAll { $0.t >= t }
            s.cursor.clicks.removeAll { $0.t >= t }
            s.camera.keyframes.removeAll { $0.t > t }
            s.markers.removeAll { $0.t >= t }
        }
        silence.withLock { $0.detector.discard(from: t) }
    }

    public var markers: [Marker] { state.withLock { $0.markers } }

    /// Marks the current moment (host time) on the edited timeline; false before the segment's first frame.
    @discardableResult
    public func addMarker(at hostTime: CMTime) -> Bool {
        state.withLock { s in
            guard let t = s.editedTime(at: hostTime) else { return false }
            s.markers.append(Marker(t: t))
            return true
        }
    }

    /// Where an oops-retake requested at `hostTime` should cut (edited time): see `SilenceDetector.cutPoint`.
    func retakePoint(at hostTime: CMTime) -> Double {
        let (segmentStart, now) = state.withLock { ($0.offset, $0.editedTime(at: hostTime) ?? $0.offset) }
        return silence.withLock { $0.detector.cutPoint(segmentStart: segmentStart, now: now) }
    }

    /// Measures the microphone for pauses, on the edited timeline of the running segment.
    private func trackSilence(_ buffer: CMSampleBuffer) {
        guard let t = state.withLock({ $0.editedTime(at: buffer.presentationTimeStamp) }) else { return }
        silence.withLock { s in
            // A new format (e.g. a headset connected) gets a new converter instead of failing from then on.
            if let format = buffer.formatDescription, s.downmixer?.handles(format) == false { s.downmixer = nil }
            guard let samples = try? Downmixer.convert(buffer, with: &s.downmixer) else { return }
            s.detector.add(samples, at: t)
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
        // A new segment's audio starts fresh frame alignment (pauses found so far are kept).
        if writer != nil { silence.withLock { $0.detector.discard(from: offset) } }
    }

    public var cursor: CursorTrack { state.withLock { $0.cursor } }
    public var camera: Project.Camera { state.withLock { $0.camera } }

    /// Records where the camera bubble is (`center` in global points, origin top-left) on the edited timeline.
    /// Before the first frame of a segment (or while paused) it lands at the current edited time.
    public func recordBubble(center: CGPoint, visible: Bool, at hostTime: CMTime) {
        guard captureRect.width > 0, captureRect.height > 0 else { return }
        let x = (center.x - captureRect.minX) / captureRect.width
        let y = (center.y - captureRect.minY) / captureRect.height
        let aspect = captureRect.width / captureRect.height
        state.withLock { s in
            let t = s.writer?.startTime.map { hostTime >= $0 ? s.offset + (hostTime - $0).seconds : s.offset } ?? s.offset
            s.camera.record(BubbleKeyframe(t: t, x: x, y: y, visible: visible), aspect: aspect)
        }
    }

    /// The bubble's size (fraction of the output width) and shape apply to the whole recording.
    public func setBubble(size: Double, shape: BubbleShape) {
        state.withLock {
            $0.camera.size = size
            $0.camera.shape = shape
        }
    }

    public func receive(_ buffer: CMSampleBuffer, kind: TrackKind) {
        if kind == .mic { trackSilence(buffer) }
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
