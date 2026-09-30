import AVFoundation
import ProjectKit

/// Turns a finished `.takely` bundle into `exports/<name>.mp4`.
public struct Exporter: Sendable {
    public init() {}

    public func export(_ bundle: ProjectBundle, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let project = try bundle.readProject()
        guard !project.segments.isEmpty else { throw RenderError.emptyRecording }
        let cursorTrack = try bundle.readCursor()
        let renderer = FrameRenderer(project: project, cursor: cursorTrack)
        let composition = AVMutableComposition()
        var tracks: [TrackKind: AVMutableCompositionTrack] = [:]
        var cameraCoverage: [CMTimeRange] = []
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
                // The raw microphone is kept for re-processing only: exporting it would bring the echo back.
                guard kind != .micRaw, end > range.start, kind != .camera || project.camera.enabled else { continue }
                let track = try tracks[kind] ?? addTrack(kind, to: composition)
                tracks[kind] = track
                try track.insertTimeRange(CMTimeRange(start: range.start, end: end), of: source, at: cursor + range.start)
                if kind == .camera {
                    cameraCoverage.append(CMTimeRange(start: cursor + range.start, end: cursor + end))
                }
            }
            cursor = cursor + segmentEnd
        }
        guard let screenTrack = tracks[.screen] else { throw RenderError.trackMismatch("no screen track") }

        let presentAudioKinds = [TrackKind.system, .mic].filter { tracks[$0] != nil }
        let passthrough =
            !Exporter.needsCompositing(project: project, cursor: cursorTrack, hasCameraTrack: tracks[.camera] != nil)
            && presentAudioKinds.count <= 1
            && !Exporter.audioNeedsMixing(project: project, presentAudio: presentAudioKinds)
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
                cameraTrackID: tracks[.camera]?.trackID,
                cameraCoverage: cameraCoverage,
                renderer: renderer
            )
            var configuration = AVVideoComposition.Configuration(
                customVideoCompositorClass: TakelyCompositor.self,
                frameDuration: CMTime(value: 1, timescale: CMTimeScale(project.capture.fps)),
                instructions: [instruction],
                renderSize: CGSize(width: project.capture.pixelSize.width, height: project.capture.pixelSize.height)
            )
            // Match the capture path (Rec. 709) explicitly instead of relying on a default.
            configuration.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            configuration.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            configuration.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            session.videoComposition = AVVideoComposition(configuration: configuration)

            let mix = AVMutableAudioMix()
            mix.inputParameters = [TrackKind.system, .mic].compactMap { kind in
                tracks[kind].map {
                    let parameters = AVMutableAudioMixInputParameters(track: $0)
                    parameters.setVolume(Exporter.volume(for: kind, in: project), at: .zero)
                    return parameters
                }
            }
            session.audioMix = mix
        }

        // Export under a temporary name and move it into place only when complete, so a crash mid-export
        // never leaves a partial MP4 that looks finished (recovery keys on `hasExport`).
        let output = bundle.exportURL
        let partial = bundle.exportsURL.appending(path: ".\(bundle.name).partial.mp4")
        try? FileManager.default.removeItem(at: partial)
        let observed = ObservedSession(session: session)
        let observer = Task {
            for await state in observed.session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { observer.cancel() }
        do {
            try await session.export(to: partial, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: partial)  // don't leave hidden partial files behind
            throw error
        }
        let markers = (try? bundle.readMarkers()) ?? []
        if !markers.isEmpty {
            let chaptered = bundle.exportsURL.appending(path: ".\(bundle.name).chapters.mp4")
            try? FileManager.default.removeItem(at: chaptered)
            do {
                try await ChapterWriter.write(partial, to: chaptered, markers: markers)
                try FileManager.default.removeItem(at: partial)
                try FileManager.default.moveItem(at: chaptered, to: partial)
            } catch {
                // Chapters are a nicety: keep the export without them rather than failing it.
                try? FileManager.default.removeItem(at: chaptered)
            }
        }
        // Swaps atomically: a failed replace keeps the previous export.
        _ = try FileManager.default.replaceItemAt(output, withItemAt: partial)
        progress(1)
        return output
    }

    /// Whether frames must go through the compositor, judged by the data actually present.
    static func needsCompositing(project: Project, cursor: CursorTrack, hasCameraTrack: Bool) -> Bool {
        (project.camera.enabled && hasCameraTrack)
            || (project.effects.cursorHighlight && !cursor.samples.isEmpty)
            || (project.effects.clickRipples && !cursor.clicks.isEmpty)
    }

    /// The configured volume for an audio track kind; non-audio kinds are unaffected (1).
    static func volume(for kind: TrackKind, in project: Project) -> Float {
        switch kind {
        case .system: project.audio.systemVolume
        case .mic: project.audio.micVolume
        case .screen, .camera, .micRaw: 1
        }
    }

    /// Whether any audio track actually present has a non-default volume, forcing a re-encode even without overlays.
    static func audioNeedsMixing(project: Project, presentAudio: [TrackKind]) -> Bool {
        presentAudio.contains { volume(for: $0, in: project) != 1 }
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
