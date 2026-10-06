/// Finds pauses in the microphone for the oops-retake: 10 ms frames below −45 dBFS for at least 400 ms.
/// Times are on the edited timeline. Energy only, no speech recognition.
public struct SilenceDetector: Sendable {
    /// −45 dBFS as an RMS amplitude. ponytail: fixed threshold; adapt to the room's noise floor if rooms vary.
    static let threshold: Float = 0.005_623
    static let minimumGap = 0.4
    /// A retake never looks further back than this for a pause…
    static let lookback = 15.0
    /// …and without one it takes back only this much (e.g. the microphone is off, or speakers play throughout).
    static let fallback = 5.0
    static let frame = 480
    static let rate = 48_000.0

    /// Completed pauses (ended by speech), oldest first.
    public private(set) var gaps: [ClosedRange<Double>] = []
    private var pending: [Float] = []
    private var pendingStart = 0.0
    private var silentSince: Double?
    /// Where the last frame looked at ended: frames never go back before it (a buffer stamped early would otherwise
    /// move a pause's start back into the words before it).
    private var processedUntil = -Double.infinity

    public init() {}

    /// Adds mono 48 kHz samples whose first sample is at edited time `t`.
    public mutating func add(_ samples: [Float], at t: Double) {
        // Re-anchor to the timestamps (drift, dropped buffers), but never back in time.
        pendingStart = max(t - Double(pending.count) / Self.rate, processedUntil)
        pending += samples
        var offset = 0
        while pending.count - offset >= Self.frame {
            let frame = pending[offset..<offset + Self.frame]
            let start = pendingStart + Double(offset) / Self.rate
            let rms = (frame.reduce(0) { $0 + $1 * $1 } / Float(Self.frame)).squareRoot()
            if rms < Self.threshold {
                if silentSince == nil { silentSince = start }
            } else if let since = silentSince {
                if start - since >= Self.minimumGap - 1e-9 { gaps.append(since...start) }
                silentSince = nil
            }
            offset += Self.frame
        }
        pending.removeFirst(offset)
        pendingStart += Double(offset) / Self.rate
        if offset > 0 { processedUntil = pendingStart }
    }

    /// Where a retake requested at `now` should cut: inside the last completed pause in this segment and within
    /// the last `lookback` seconds, keeping up to 0.2 s of it; otherwise `fallback` seconds back. Never before
    /// `segmentStart`. A pause still going on (after the words being taken back) doesn't count.
    public func cutPoint(segmentStart: Double, now: Double) -> Double {
        let earliest = max(segmentStart, now - Self.lookback)
        guard let gap = gaps.last(where: { $0.lowerBound >= earliest }) else { return max(segmentStart, now - Self.fallback) }
        return gap.lowerBound + min(0.2, (gap.upperBound - gap.lowerBound) / 2)
    }

    /// Forgets everything after `t` (after a retake cut there) and restarts frame alignment.
    public mutating func discard(from t: Double) {
        gaps.removeAll { $0.upperBound > t }
        pending = []
        silentSince = nil
        processedUntil = -Double.infinity  // a new segment starts afresh
    }
}
