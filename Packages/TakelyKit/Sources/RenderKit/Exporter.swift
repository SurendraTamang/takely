import AVFoundation
import ProjectKit

/// Turns a finished `.takely` bundle into `exports/<name>.mp4`.
public struct Exporter: Sendable {
    public init() {}

    public func export(_ bundle: ProjectBundle, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let project = try bundle.readProject()
        let renderer = FrameRenderer(project: project, cursor: try bundle.readCursor())
        let composition = AVMutableComposition()
        var tracks: [TrackKind: AVMutableCompositionTrack] = [:]
        var cursor = CMTime.zero

        for segment in project.segments {
            let asset = AVURLAsset(url: bundle.segmentURL(segment.file))
            let sources = try await asset.load(.tracks).sorted { $0.trackID < $1.trackID }
            guard sources.count == segment.tracks.count else {
                throw RenderError.trackMismatch("\(segment.file): \(sources.count) tracks, manifest lists \(segment.tracks.count)")
            }
            let segmentEnd = CMTime(seconds: segment.duration, preferredTimescale: 600)
            for (kind, source) in zip(segment.tracks, sources) {
                let range = try await source.load(.timeRange)
                let end = CMTimeMinimum(range.end, segmentEnd)
                guard end > range.start else { continue }
                let track = try tracks[kind] ?? addTrack(kind, to: composition)
                tracks[kind] = track
                try track.insertTimeRange(CMTimeRange(start: range.start, end: end), of: source, at: cursor + range.start)
            }
            cursor = cursor + segmentEnd
        }
        guard let screenTrack = tracks[.screen] else { throw RenderError.trackMismatch("no screen track") }

        let audioTracks = [TrackKind.system, .mic].compactMap { tracks[$0] }
        let passthrough = !renderer.hasOverlays && audioTracks.count <= 1
        let preset =
            passthrough
            ? AVAssetExportPresetPassthrough
            : project.capture.codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw RenderError.exportUnavailable
        }
        session.shouldOptimizeForNetworkUse = true

        if !passthrough {
            let instruction = TakelyInstruction(
                timeRange: CMTimeRange(start: .zero, duration: composition.duration),
                screenTrackID: screenTrack.trackID,
                cameraTrackID: project.camera.enabled ? tracks[.camera]?.trackID : nil,
                renderer: renderer
            )
            session.videoComposition = AVVideoComposition(
                configuration: .init(
                    customVideoCompositorClass: TakelyCompositor.self,
                    frameDuration: CMTime(value: 1, timescale: CMTimeScale(project.capture.fps)),
                    instructions: [instruction],
                    renderSize: CGSize(width: project.capture.pixelSize.width, height: project.capture.pixelSize.height)
                ))

            let mix = AVMutableAudioMix()
            mix.inputParameters = [(TrackKind.system, project.audio.systemVolume), (.mic, project.audio.micVolume)]
                .compactMap { kind, volume in
                    tracks[kind].map {
                        let parameters = AVMutableAudioMixInputParameters(track: $0)
                        parameters.setVolume(volume, at: .zero)
                        return parameters
                    }
                }
            session.audioMix = mix
        }

        let output = bundle.exportsURL.appending(path: "\(bundle.name).mp4")
        try? FileManager.default.removeItem(at: output)
        let observed = ObservedSession(session: session)
        let observer = Task {
            for await state in observed.session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { observer.cancel() }
        try await session.export(to: output, as: .mp4)
        progress(1)
        return output
    }

    private func addTrack(_ kind: TrackKind, to composition: AVMutableComposition) throws -> AVMutableCompositionTrack {
        guard
            let track = composition.addMutableTrack(
                withMediaType: kind.isVideo ? .video : .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw RenderError.trackMismatch("cannot add \(kind) track")
        }
        return track
    }
}

/// `states(updateInterval:)` is meant to be observed while `export` runs on another task.
private struct ObservedSession: @unchecked Sendable {
    let session: AVAssetExportSession
}
