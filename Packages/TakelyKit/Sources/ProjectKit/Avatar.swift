import Foundation

/// A stylized portrait standing in for the camera (Demo Mode's narrated recordings): `avatar.png` in the bundle and
/// where its mouth and eyes are, so the export can make it talk, blink and breathe.
public struct AvatarFace: Codable, Sendable, Equatable {
    /// Normalized to the image, origin top-left.
    public var mouth: NormalizedRect
    public var leftEye: NormalizedRect
    public var rightEye: NormalizedRect
    /// The skin around the eyes (RGB 0–1): eyelids are drawn in it.
    public var skin: [Double]

    public init(mouth: NormalizedRect, leftEye: NormalizedRect, rightEye: NormalizedRect, skin: [Double]) {
        self.mouth = mouth
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.skin = skin
    }
}

/// How the avatar moves over time: blinks (varied, but the same on every export) and a gentle breathing bob.
public enum AvatarMotion {
    static let blinkLength = 0.16

    /// 0 (eyes open) … 1 (closed) at `t`: a blink every 3–6 s.
    public static func blink(at t: Double) -> Double {
        guard t >= 0 else { return 0 }
        var start = 1.5
        var k: UInt64 = 1
        while start <= t {
            if t < start + blinkLength { return sin((t - start) / blinkLength * .pi) }
            start += 3 + 3 * unit(k)
            k += 1
        }
        return 0
    }

    /// Vertical offset (fraction of the avatar's height): breathing, a little livelier while talking.
    public static func bob(at t: Double, level: Double) -> Double {
        0.012 * sin(t * 2 * .pi / 4) + 0.008 * level * sin(t * 2 * .pi * 1.7)
    }

    /// A repeatable value in 0..<1 for `k` (SplitMix64).
    static func unit(_ k: UInt64) -> Double {
        var z = k &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

/// Narration loudness over the recording timeline, sampled `rate` times a second, 0…1: how far the mouth opens.
public struct VoiceLevels: Sendable, Equatable {
    public static let rate = 30.0
    public var samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }

    public func level(at t: Double) -> Double {
        let i = Int((t * Self.rate).rounded(.down))
        return i >= 0 && i < samples.count ? Double(samples[i]) : 0
    }

    /// Per-clip loudness envelopes placed at their times, scaled so the loudest moment is 1, and smoothed like a
    /// mouth moves (opens fast, closes a little slower).
    public static func place(_ clips: [(t: Double, rms: [Float])], duration: Double) -> VoiceLevels {
        var samples = [Float](repeating: 0, count: max(0, Int((duration * rate).rounded(.up))))
        for clip in clips {
            let start = Int((clip.t * rate).rounded())
            for (i, value) in clip.rms.enumerated() where start + i >= 0 && start + i < samples.count {
                samples[start + i] = max(samples[start + i], value)
            }
        }
        let peak = samples.max() ?? 0
        guard peak > 0 else { return VoiceLevels(samples: samples) }
        var smoothed = samples
        var current: Float = 0
        for i in samples.indices {
            let target = min(1, samples[i] / peak * 1.4)  // speech rarely sits at its peak: open the mouth a bit more
            current += (target - current) * (target > current ? 0.7 : 0.35)
            smoothed[i] = current < 0.05 ? 0 : current
        }
        return VoiceLevels(samples: smoothed)
    }
}

extension ProjectBundle {
    public var avatarImageURL: URL { url.appending(path: "avatar.png") }
    public var avatarFaceURL: URL { url.appending(path: "avatar.json") }

    /// The avatar's face, when the recording has one.
    public func readAvatarFace() -> AvatarFace? {
        guard FileManager.default.fileExists(atPath: avatarImageURL.path) else { return nil }
        return (try? Data(contentsOf: avatarFaceURL)).flatMap { try? JSONDecoder().decode(AvatarFace.self, from: $0) }
    }
}
