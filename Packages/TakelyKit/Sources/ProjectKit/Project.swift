import Foundation

public enum TrackKind: String, Codable, Sendable, CaseIterable {
    /// `mic` is echo-cancelled when `micRaw` (the microphone exactly as captured) is present; only `mic` is exported.
    case screen, camera, system, mic, micRaw

    public var isVideo: Bool { self == .screen || self == .camera }
}

public enum CaptureTarget: String, Codable, Sendable {
    case display, window, region
}

public enum VideoCodec: String, Codable, Sendable {
    case h264, hevc
}

public enum BubbleShape: String, Codable, Sendable, CaseIterable {
    case circle, rounded, square
}

public struct PixelSize: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct BubbleKeyframe: Codable, Sendable, Equatable {
    public var t: Double
    public var x: Double
    public var y: Double
    /// False from here until the next visible keyframe: the user hid the bubble.
    public var visible: Bool

    public init(t: Double, x: Double, y: Double, visible: Bool = true) {
        self.t = t
        self.x = x
        self.y = y
        self.visible = visible
    }

    /// Manifests written before `visible` existed decode as visible.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
    }
}

public enum ProjectError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

public struct Project: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public enum Status: String, Codable, Sendable {
        case recording, finished
    }

    public struct Capture: Codable, Sendable, Equatable {
        public var target: CaptureTarget
        public var pixelSize: PixelSize
        public var fps: Int
        public var codec: VideoCodec

        public init(target: CaptureTarget, pixelSize: PixelSize, fps: Int, codec: VideoCodec) {
            self.target = target
            self.pixelSize = pixelSize
            self.fps = fps
            self.codec = codec
        }
    }

    public struct Segment: Codable, Sendable, Equatable {
        public var file: String
        public var duration: Double
        /// Track kinds actually written, in track-ID order (empty inputs are omitted from the file).
        public var tracks: [TrackKind]

        public init(file: String, duration: Double, tracks: [TrackKind]) {
            self.file = file
            self.duration = duration
            self.tracks = tracks
        }
    }

    public struct Camera: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var shape: BubbleShape
        /// Bubble diameter as a fraction of output width.
        public var size: Double
        public var keyframes: [BubbleKeyframe]

        public init(
            enabled: Bool, shape: BubbleShape = .circle, size: Double = 0.18,
            keyframes: [BubbleKeyframe] = [BubbleKeyframe(t: 0, x: 0.88, y: 0.82)]
        ) {
            self.enabled = enabled
            self.shape = shape
            self.size = size
            self.keyframes = keyframes
        }

        /// Read with the keyframes sorted by time (see `sortedByTime`).
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                enabled: try c.decode(Bool.self, forKey: .enabled), shape: try c.decode(BubbleShape.self, forKey: .shape),
                size: try c.decode(Double.self, forKey: .size),
                keyframes: sortedByTime(try c.decode([BubbleKeyframe].self, forKey: .keyframes), \.t))
        }
    }

    public struct Effects: Codable, Sendable, Equatable {
        public var cursorHighlight: Bool
        public var clickRipples: Bool
        /// Draw the transcript's captions into the video (optional: absent in older manifests).
        public var burnInCaptions: Bool?

        public init(cursorHighlight: Bool = true, clickRipples: Bool = true) {
            self.cursorHighlight = cursorHighlight
            self.clickRipples = clickRipples
        }
    }

    public struct Audio: Codable, Sendable, Equatable {
        public var systemVolume: Float
        public var micVolume: Float

        public init(systemVolume: Float = 1, micVolume: Float = 1) {
            self.systemVolume = systemVolume
            self.micVolume = micVolume
        }
    }

    public var schemaVersion: Int
    public var status: Status
    public var createdAt: Date
    public var capture: Capture
    public var segments: [Segment]
    public var camera: Camera
    public var effects: Effects
    public var audio: Audio
    /// Written by the AI summary (Pro) after a recording; absent in older manifests.
    public var title: String?
    public var summary: String?
    /// When the last export finished: the recording counts as done even if its MP4 was moved out of the bundle.
    public var exportedAt: Date?
    /// What the person should know about this recording (why there are no captions, echo removal failing…), each
    /// under its own key so one can be cleared without the others; shown with the Ready notification.
    public var notes: [String: String]?

    public mutating func setNote(_ key: String, _ text: String?) {
        var all = notes ?? [:]
        all[key] = text
        notes = all.isEmpty ? nil : all
    }

    public init(
        status: Status = .recording, createdAt: Date = .now, capture: Capture, segments: [Segment] = [], camera: Camera,
        effects: Effects = Effects(), audio: Audio = Audio()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.status = status
        self.createdAt = createdAt
        self.capture = capture
        self.segments = segments
        self.camera = camera
        self.effects = effects
        self.audio = audio
    }

    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    public static func decode(_ data: Data) throws -> Project {
        struct Header: Decodable { let schemaVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
        guard (1...currentSchemaVersion).contains(version) else { throw ProjectError.unsupportedSchemaVersion(version) }
        // ponytail: v1 is the only schema; add stepwise `migrate(from:)` cases when v2 lands.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Project.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
