import CoreGraphics
import ProjectKit

public enum Resolution: String, Codable, Sendable, CaseIterable {
    case p720, p1080, native

    var targetHeight: Int? {
        switch self {
        case .p720: 720
        case .p1080: 1080
        case .native: nil
        }
    }
}

public struct RecordingConfig: Sendable, Equatable {
    public var target: CaptureTarget
    /// Captured area in global display coordinates (points, origin top-left). Used to normalize cursor positions.
    public var captureRect: CGRect
    /// Captured area in pixels (`captureRect.size × pointPixelScale`).
    public var sourcePixelSize: PixelSize
    public var resolution: Resolution
    public var fps: Int
    public var codec: VideoCodec
    public var camera: Bool
    public var systemAudio: Bool
    public var microphone: Bool
    /// Removes speaker playback from the microphone; only takes effect with both audio sources (`cancelsEcho`).
    public var echoCancellation: Bool
    /// `AVCaptureDevice.uniqueID` of the microphone; nil records the system default.
    public var microphoneDeviceID: String?

    public init(
        target: CaptureTarget, captureRect: CGRect, sourcePixelSize: PixelSize, resolution: Resolution = .p1080, fps: Int = 30,
        codec: VideoCodec = .hevc, camera: Bool = false, systemAudio: Bool = true, microphone: Bool = true,
        echoCancellation: Bool = false
    ) {
        self.target = target
        self.captureRect = captureRect
        self.sourcePixelSize = sourcePixelSize
        self.resolution = resolution
        self.fps = fps
        self.codec = codec
        self.camera = camera
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.echoCancellation = echoCancellation
    }

    /// The system audio is the echo reference, so cancellation needs both sources.
    public var cancelsEcho: Bool { echoCancellation && systemAudio && microphone }

    /// Writer tracks in the order their inputs are added (= track-ID order).
    public var tracks: [TrackKind] {
        [.screen] + (camera ? [.camera] : []) + (systemAudio ? [.system] : []) + (microphone ? [.mic] : []) + (cancelsEcho ? [.micRaw] : [])
    }

    /// Output size: scaled down to the preset height (aspect preserved), never up; both sides even.
    public var outputSize: PixelSize {
        let source = sourcePixelSize
        var width: Int
        var height: Int
        if let target = resolution.targetHeight, source.height > target {
            width = Int((Double(source.width) * Double(target) / Double(source.height)).rounded())
            height = target
        } else {
            width = source.width
            height = source.height
        }
        // Hardware H.264 tops out at 4096×2304; HEVC handles larger.
        if codec == .h264, width > 4096 || height > 2304 {
            let scale = min(4096.0 / Double(width), 2304.0 / Double(height))
            width = Int((Double(width) * scale).rounded())
            height = Int((Double(height) * scale).rounded())
        }
        return PixelSize(width: width.even, height: height.even)
    }

    /// Average video bitrate in bits per second (spec §5.6).
    public var videoBitrate: Int {
        let fpsFactor = fps >= 60 ? 1.5 : 1.0
        switch (resolution, codec) {
        case (.p720, .h264): return Int(5_000_000 * fpsFactor)
        case (.p720, .hevc): return Int(3_000_000 * fpsFactor)
        case (.p1080, .h264): return Int(8_000_000 * fpsFactor)
        case (.p1080, .hevc): return Int(5_000_000 * fpsFactor)
        case (.native, _):
            let bitsPerPixel = codec == .h264 ? 0.1 : 0.06
            let size = outputSize
            return Int(Double(size.width * size.height * fps) * bitsPerPixel)
        }
    }

    public var writerConfig: WriterConfig {
        WriterConfig(tracks: tracks, screenSize: outputSize, codec: codec, fps: fps, videoBitrate: videoBitrate)
    }
}

extension Int {
    /// Rounded down to even (encoder requirement), never below 2.
    var even: Int { Swift.max(2, self & ~1) }
}
