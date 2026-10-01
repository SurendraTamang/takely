import Foundation

/// A rectangle in a frame, normalized to its size (0…1), origin top-left.
public struct NormalizedRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Linear blend towards `other`.
    func blended(with other: NormalizedRect, _ f: Double) -> NormalizedRect {
        NormalizedRect(
            x: x + (other.x - x) * f, y: y + (other.y - y) * f, width: width + (other.width - width) * f,
            height: height + (other.height - height) * f)
    }
}

/// Something blurred out of the export (`redactions.json`): a secret found on screen, or an area the user chose.
public struct Redaction: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case apiKey, email, card, manual
    }

    public struct Keyframe: Codable, Sendable, Equatable {
        public var t: Double
        public var rect: NormalizedRect

        public init(t: Double, rect: NormalizedRect) {
            self.t = t
            self.rect = rect
        }
    }

    /// Covered this long before the first sighting and after the last (text appears and goes between samples).
    public static let margin = 0.5

    public var id: UUID
    public var kind: Kind
    /// What was found, masked ("sk-…f3a9"); never the secret itself.
    public var preview: String
    public var enabled: Bool
    /// Where it is over time, on the edited timeline, sorted by `t`.
    public var track: [Keyframe]

    public init(id: UUID = UUID(), kind: Kind, preview: String, enabled: Bool = true, track: [Keyframe]) {
        self.id = id
        self.kind = kind
        self.preview = preview
        self.enabled = enabled
        self.track = track
    }

    /// The box to blur at `t`, interpolated between keyframes; nil when disabled or not on screen.
    public func rect(at t: Double) -> NormalizedRect? {
        guard enabled, let first = track.first, let last = track.last, t >= first.t - Self.margin, t <= last.t + Self.margin
        else { return nil }
        guard let next = track.firstIndex(where: { $0.t > t }) else { return last.rect }
        guard next > 0 else { return first.rect }
        let a = track[next - 1]
        let b = track[next]
        return a.rect.blended(with: b.rect, (t - a.t) / (b.t - a.t))
    }
}
