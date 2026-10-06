import AVFoundation
import ProjectKit
import VideoToolbox

/// Encoder settings for one segment's tracks.
public struct WriterConfig: Sendable, Equatable {
    public var tracks: [TrackKind]
    public var screenSize: PixelSize
    public var cameraSize: PixelSize
    public var codec: VideoCodec
    public var fps: Int
    public var videoBitrate: Int

    public init(
        tracks: [TrackKind], screenSize: PixelSize, cameraSize: PixelSize = PixelSize(width: 1280, height: 720), codec: VideoCodec,
        fps: Int, videoBitrate: Int
    ) {
        self.tracks = tracks
        self.screenSize = screenSize
        self.cameraSize = cameraSize
        self.codec = codec
        self.fps = fps
        self.videoBitrate = videoBitrate
    }

    func outputSettings(for kind: TrackKind) -> [String: Any] {
        switch kind {
        case .screen:
            videoSettings(size: screenSize, bitrate: videoBitrate, fps: fps)
        // CameraSource captures at a fixed 30 fps regardless of the screen preset.
        case .camera:
            videoSettings(size: cameraSize, bitrate: 2_500_000, fps: 30)
                .merging([AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill]) { $1 }
        case .system:
            audioSettings(channels: 2)
        case .mic, .micRaw:
            audioSettings(channels: 1)
        }
    }

    private func videoSettings(size: PixelSize, bitrate: Int, fps: Int) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            // No B-frames: live capture written in fragments, where reordering only adds latency.
            AVVideoAllowFrameReorderingKey: false,
        ]
        // Explicit profiles: H.264 High, HEVC Main (8-bit, what every HEVC player decodes).
        compression[AVVideoProfileLevelKey] =
            codec == .h264 ? AVVideoProfileLevelH264HighAutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel as String
        return [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    private func audioSettings(channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 128_000,
        ]
    }
}
