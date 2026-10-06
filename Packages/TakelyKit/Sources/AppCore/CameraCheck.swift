import AVFoundation
import ProjectKit

/// Whether the camera kept recording: a camera that stopped mid-segment (unplugged, taken by another app) leaves a
/// camera track that ends early. The export hides the bubble from there; this says so in the Ready notification.
enum CameraCheck {
    /// More than this short of its segment counts as stopped (camera tracks start and end a frame or two off).
    static let tolerance = 1.0

    /// The time (on the recording timeline) where the camera stopped, if it did; nil when it ran throughout.
    static func stoppedAt(_ bundle: ProjectBundle) async -> Double? {
        guard let project = try? bundle.readProject(), project.camera.enabled else { return nil }
        var offset = 0.0
        for segment in project.segments {
            defer { offset += segment.duration }
            // No camera track in a segment (lost during a pause, or never delivered a frame): stopped as it began.
            guard let index = segment.tracks.firstIndex(of: .camera) else { return offset }
            let asset = AVURLAsset(url: bundle.segmentURL(segment.file))
            guard let tracks = try? await asset.load(.tracks).sorted(by: { $0.trackID < $1.trackID }), tracks.indices.contains(index),
                let range = try? await tracks[index].load(.timeRange)
            else { continue }
            let end = range.end.seconds
            if end.isFinite, segment.duration - end > tolerance { return offset + max(0, end) }
        }
        return nil
    }

    /// Notes (or clears) "The camera stopped at m:ss" on the recording, at that point in the video (after its cuts).
    static func note(_ bundle: ProjectBundle) async {
        let stopped = await stoppedAt(bundle)
        guard var project = try? bundle.readProject() else { return }
        let cuts = (try? bundle.readEdits())?.cuts ?? []
        let text = stopped.map { t in
            let at = EditMap(cuts: cuts, duration: project.duration).position(t)
            return "The camera stopped at \(Duration.seconds(at).formatted(.time(pattern: .minuteSecond))): "
                + "the bubble is hidden where it has no picture."
        }
        guard project.notes?["camera"] != text else { return }
        project.setNote("camera", text)
        try? bundle.write(project)
    }
}
