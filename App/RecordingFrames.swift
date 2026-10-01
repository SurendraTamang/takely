import AVFoundation
import ProjectKit

/// Stills from a recording's screen, by time on the recording timeline (segments back to back).
struct RecordingFrames {
    let bundle: ProjectBundle
    let segments: [Project.Segment]

    func frame(at t: Double, size: CGSize) async -> CGImage? {
        var offset = 0.0
        for segment in segments {
            defer { offset += segment.duration }
            guard t < offset + segment.duration || segment == segments.last else { continue }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: bundle.segmentURL(segment.file)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = size
            let local = min(max(0, t - offset), max(0, segment.duration - 0.05))
            return try? await generator.image(at: CMTime(seconds: local, preferredTimescale: 600)).image
        }
        return nil
    }
}
