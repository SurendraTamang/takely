import Foundation

public struct CursorSample: Codable, Sendable, Equatable {
    public var t: Double
    public var x: Double
    public var y: Double

    public init(t: Double, x: Double, y: Double) {
        self.t = t
        self.x = x
        self.y = y
    }
}

public struct ClickEvent: Codable, Sendable, Equatable {
    public var t: Double
    public var x: Double
    public var y: Double

    public init(t: Double, x: Double, y: Double) {
        self.t = t
        self.x = x
        self.y = y
    }
}

public struct NormalizedPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ActiveClick: Sendable, Equatable {
    public var click: ClickEvent
    /// 0 at the click, approaching 1 at the end of the effect window.
    public var progress: Double
}

/// Cursor positions and clicks on the edited timeline, normalized 0–1 with origin top-left.
public struct CursorTrack: Codable, Sendable, Equatable {
    public var samples: [CursorSample]
    public var clicks: [ClickEvent]
    /// Cursor data ends here (after a crash the recovered tail has none); nothing is reported after it.
    public var coveredUntil: Double?

    public init(samples: [CursorSample] = [], clicks: [ClickEvent] = [], coveredUntil: Double? = nil) {
        self.samples = samples
        self.clicks = clicks
        self.coveredUntil = coveredUntil
    }

    public func position(at t: Double) -> NormalizedPoint? {
        if let coveredUntil, t > coveredUntil { return nil }
        guard let first = samples.first, let last = samples.last else { return nil }
        var lo = 0
        var hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t <= t { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return NormalizedPoint(x: first.x, y: first.y) }
        if lo == samples.count { return NormalizedPoint(x: last.x, y: last.y) }
        let a = samples[lo - 1]
        let b = samples[lo]
        let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
        return NormalizedPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    public func clicks(activeAt t: Double, window: Double = 0.3) -> [ActiveClick] {
        // ponytail: linear scan; binary search if click counts reach the thousands.
        clicks.compactMap { click in
            let progress = (t - click.t) / window
            return (0..<1).contains(progress) ? ActiveClick(click: click, progress: progress) : nil
        }
    }
}

extension Project.Camera {
    /// Bubble center at time `t`. Each keyframe starts a move from the previous
    /// position that completes over `transition` seconds.
    public func bubbleCenter(at t: Double, transition: Double = 0.15) -> NormalizedPoint? {
        guard let first = keyframes.first else { return nil }
        guard let index = keyframes.lastIndex(where: { $0.t <= t }) else {
            return NormalizedPoint(x: first.x, y: first.y)
        }
        let target = keyframes[index]
        let from = index > 0 ? keyframes[index - 1] : target
        let f = min(1, (t - target.t) / transition)
        return NormalizedPoint(x: from.x + (target.x - from.x) * f, y: from.y + (target.y - from.y) * f)
    }
}
