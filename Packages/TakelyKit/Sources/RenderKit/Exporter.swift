import AVFoundation
import OSLog
import ProjectKit

/// Turns a finished `.takely` bundle into `exports/<name>.mp4`.
public struct Exporter: Sendable {
    private let log = Logger(subsystem: "app.takely", category: "export")

    public init() {}

    public func export(_ bundle: ProjectBundle, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let project = try bundle.readProject()
        guard !project.segments.isEmpty else { throw RenderError.emptyRecording }
        let cursorTrack = try bundle.readCursor()
        let transcript = try? bundle.readTranscript()
        let cues = transcript?.cues() ?? []
        // An unreadable redactions file fails the export: never export with the blurs silently dropped.
        let renderer = FrameRenderer(
            project: project, cursor: cursorTrack, captions: cues, redactions: try bundle.readRedactions())
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
            && !renderer.hasCaptions && !renderer.hasRedactions
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
        let extras = MovieExtras(
            markers: (try? bundle.readMarkers()) ?? [], captions: cues, captionsLocale: transcript?.locale,
            title: project.title, summary: project.summary)
        if !extras.isEmpty {
            let finished = bundle.exportsURL.appending(path: ".\(bundle.name).finished.mp4")
            try? FileManager.default.removeItem(at: finished)
            // Captions are the most complex part: if the pass fails, retry without them so chapters and metadata stay.
            var attempts = [extras]
            if !extras.captions.isEmpty {
                var withoutCaptions = extras
                withoutCaptions.captions = []
                if !withoutCaptions.isEmpty { attempts.append(withoutCaptions) }
            }
            for attempt in attempts {
                do {
                    try? FileManager.default.removeItem(at: finished)
                    try await MovieFinisher.write(partial, to: finished, extras: attempt)
                    _ = try FileManager.default.replaceItemAt(partial, withItemAt: finished)  // the export survives a failed swap
                    break
                } catch {
                    // Niceties: keep the export without them rather than failing it.
                    log.error("finishing the export failed: \(String(describing: error))")
                    try? FileManager.default.removeItem(at: finished)
                }
            }
        }
        if cues.isEmpty {
            try? FileManager.default.removeItem(at: bundle.captionsURL)  // no stale captions from an earlier export
        } else {
            try? WebVTT.render(cues).write(to: bundle.captionsURL, atomically: true, encoding: .utf8)
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
