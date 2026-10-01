import Foundation

/// A span of time in seconds, `[start, end)`.
public struct TimeRange: Codable, Sendable, Equatable, Hashable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
}

/// A zoom into the screen (Pro's editor and auto-zoom make these; the export renders them).
public struct Zoom: Codable, Sendable, Equatable, Identifiable {
    public enum Focus: Codable, Sendable, Equatable {
        /// Follows the cursor (smoothed).
        case cursor
        /// Stays on one point (normalized, origin top-left).
        case point(NormalizedPoint)
    }

    public static let scales = 1.2...3.0
    /// Easing in at the start and out at the end.
    public static let ease = 0.4

    public var id: UUID
    /// Recording timeline.
    public var start: Double
    public var end: Double
    public var scale: Double
    public var focus: Focus

    public init(id: UUID = UUID(), start: Double, end: Double, scale: Double = 1.8, focus: Focus = .cursor) {
        self.id = id
        self.start = start
        self.end = end
        self.scale = min(max(scale, Self.scales.lowerBound), Self.scales.upperBound)
        self.focus = focus
    }

    /// How far zoomed in at `t`: 1 outside, `scale` in the middle, eased (smoothstep) over `ease` at each end.
    public func scale(at t: Double) -> Double {
        guard t > start, t < end else { return 1 }
        let ramp = min(Self.ease, (end - start) / 2)
        let f = min(1, (t - start) / ramp, (end - t) / ramp)
        return 1 + (scale - 1) * f * f * (3 - 2 * f)
    }
}

/// Non-destructive edits (`edits.json`): what's cut out and where it zooms, on the recording timeline (segments back to
/// back). The recorded media is never changed, so every edit can be undone.
public struct Edits: Codable, Sendable, Equatable {
    /// Removed ranges, sorted and merged.
    public private(set) var cuts: [TimeRange]
    public var zooms: [Zoom]

    public init(cuts: [TimeRange] = [], zooms: [Zoom] = []) {
        self.cuts = []
        self.zooms = zooms
        cuts.forEach { cut($0) }
    }

    public var isEmpty: Bool { cuts.isEmpty && zooms.isEmpty }

    /// Removes `range` (merging with the cuts it touches).
    public mutating func cut(_ range: TimeRange) {
        guard range.duration > 0 else { return }
        var merged = range
        cuts.removeAll { other in
            guard other.start <= merged.end, other.end >= merged.start else { return false }
            merged = TimeRange(start: min(merged.start, other.start), end: max(merged.end, other.end))
            return true
        }
        cuts.append(merged)
        cuts.sort { $0.start < $1.start }
    }

    /// Puts `range` back (splitting cuts that extend beyond it).
    public mutating func restore(_ range: TimeRange) {
        cuts = cuts.flatMap { cut -> [TimeRange] in
            guard cut.start < range.end, cut.end > range.start else { return [cut] }
            return [TimeRange(start: cut.start, end: range.start), TimeRange(start: range.end, end: cut.end)].filter { $0.duration > 0 }
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(cuts: try c.decode([TimeRange].self, forKey: .cuts), zooms: try c.decode([Zoom].self, forKey: .zooms))
    }
}

/// Recording time ↔ output time, for a recording `duration` long with `cuts` removed.
public struct EditMap: Sendable, Equatable {
    /// What's kept, in order (recording time).
    public let kept: [TimeRange]
    public let outputDuration: Double
    public let duration: Double

    public init(cuts: [TimeRange], duration: Double) {
        self.duration = duration
        var kept: [TimeRange] = []
        var from = 0.0
        for cut in cuts where cut.end > from && cut.start < duration {
            if cut.start > from { kept.append(TimeRange(start: from, end: cut.start)) }
            from = max(from, cut.end)
        }
        if from < duration { kept.append(TimeRange(start: from, end: duration)) }
        self.kept = kept
        outputDuration = kept.reduce(0) { $0 + $1.duration }
    }

    public var hasCuts: Bool { outputDuration < duration }

    /// Where recording time `t` lands in the output; a time inside a cut lands where the cut is joined.
    public func position(_ t: Double) -> Double {
        var output = 0.0
        for range in kept {
            if t < range.start { return output }
            if t < range.end { return output + t - range.start }
            output += range.duration
        }
        return output
    }

    /// Output time of recording time `t`; nil when `t` was cut.
    public func outputTime(_ t: Double) -> Double? {
        kept.contains { $0.start <= t && t < $0.end } || t == kept.last?.end ? position(t) : nil
    }

    /// Recording time shown at output time `t`.
    public func sourceTime(_ t: Double) -> Double {
        var output = 0.0
        for range in kept {
            if t < output + range.duration { return range.start + max(0, t - output) }
            output += range.duration
        }
        return kept.last?.end ?? t
    }

    /// `range` in output time, clipped where it crosses cuts; nil when it was cut entirely.
    public func output(_ range: TimeRange) -> TimeRange? {
        let mapped = TimeRange(start: position(range.start), end: position(range.end))
        return mapped.duration > 0 ? mapped : nil
    }
}
