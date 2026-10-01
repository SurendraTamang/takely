import AVFoundation
import OSLog
import ProjectKit

/// Turns a finished `.takely` bundle into `exports/<name>.mp4`.
public struct Exporter: Sendable {
    private let log = Logger(subsystem: "app.takely", category: "export")

    public init() {}

    public func export(_ bundle: ProjectBundle, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        // Unreadable edits or redactions fail the export: never export with cuts or blurs silently dropped.
        let built = try await Self.compose(bundle, edits: try bundle.readEdits())
        let preset =
            built.passthrough
            ? AVAssetExportPresetPassthrough
            : built.project.capture.codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            throw RenderError.exportUnavailable
        }
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        let project = built.project
        let map = built.map
        // Chapters and captions on the output timeline: dropped inside cuts, clipped across them.
        let markers = ((try? bundle.readMarkers()) ?? []).compactMap { m in map.outputTime(m.t).map { Marker(t: $0, title: m.title) } }
        let cues = built.cues.compactMap { cue in
            map.output(TimeRange(start: cue.start, end: cue.end)).map { CaptionCue(start: $0.start, end: $0.end, text: cue.text) }
        }
        let transcript = try? bundle.readTranscript()

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
            markers: markers, captions: cues, captionsLocale: transcript?.locale,
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

    /// A recording's composition with `edits` applied (only kept ranges, back to back), and what plays it: the
    /// compositor and audio mix, unless nothing needs them. Shared by the export and the editor's preview.
    public struct Built: @unchecked Sendable {
        public let composition: AVMutableComposition
        public let videoComposition: AVVideoComposition?
        public let audioMix: AVAudioMix?
        public let project: Project
        public let map: EditMap
        /// Captions on the recording timeline.
        let cues: [CaptionCue]
        let passthrough: Bool

        /// A player item for previewing: plays exactly what the export would write.
        public func playerItem() -> AVPlayerItem {
            let item = AVPlayerItem(asset: composition)
            item.videoComposition = videoComposition
            item.audioMix = audioMix
            return item
        }
    }

    /// A join between kept ranges fades out and back in over this long, so cutting mid-waveform doesn't click.
    static let fade = 0.015

    public static func compose(_ bundle: ProjectBundle, edits: Edits) async throws -> Built {
        let project = try bundle.readProject()
        guard !project.segments.isEmpty else { throw RenderError.emptyRecording }
        let cursorTrack = try bundle.readCursor()
        let cues = (try? bundle.readTranscript())?.cues() ?? []
        let renderer = FrameRenderer(
            project: project, cursor: cursorTrack, captions: cues, redactions: try bundle.readRedactions(), zooms: edits.zooms)
        let map = EditMap(cuts: edits.cuts, duration: project.duration)
        guard map.outputDuration > 0 else { throw RenderError.emptyRecording }
        let composition = AVMutableComposition()
        var tracks: [TrackKind: AVMutableCompositionTrack] = [:]
        var cameraCoverage: [CMTimeRange] = []
        var offset = 0.0

        for segment in project.segments {
            defer { offset += segment.duration }
            let asset = AVURLAsset(url: bundle.segmentURL(segment.file))
            let sources = try await asset.load(.tracks).sorted { $0.trackID < $1.trackID }
            guard sources.count == segment.tracks.count else {
                throw RenderError.trackMismatch("\(segment.file): \(sources.count) tracks, manifest lists \(segment.tracks.count)")
            }
            // What's kept of this segment, in its own time.
            let pieces = map.kept.compactMap { kept -> (start: CMTime, end: CMTime)? in
                let a = max(kept.start, offset) - offset
                let b = min(kept.end, offset + segment.duration) - offset
                return b > a ? (CMTime(seconds: a, preferredTimescale: 600), CMTime(seconds: b, preferredTimescale: 600)) : nil
            }
            for (kind, source) in zip(segment.tracks, sources) {
                let range = try await source.load(.timeRange)
                // The raw microphone is kept for re-processing only: exporting it would bring the echo back.
                guard kind != .micRaw, kind != .camera || project.camera.enabled else { continue }
                for piece in pieces {
                    let start = CMTimeMaximum(piece.start, range.start)
                    let end = CMTimeMinimum(piece.end, range.end)
                    guard end > start else { continue }
                    let track = try tracks[kind] ?? addTrack(kind, to: composition)
                    tracks[kind] = track
                    let at = CMTime(seconds: map.position(offset + start.seconds), preferredTimescale: 600)
                    try track.insertTimeRange(CMTimeRange(start: start, end: end), of: source, at: at)
                    if kind == .camera { cameraCoverage.append(CMTimeRange(start: at, duration: end - start)) }
                }
            }
        }
        guard let screenTrack = tracks[.screen] else { throw RenderError.trackMismatch("no screen track") }

        let presentAudioKinds = [TrackKind.system, .mic].filter { tracks[$0] != nil }
        let passthrough =
            !needsCompositing(project: project, cursor: cursorTrack, hasCameraTrack: tracks[.camera] != nil)
            && !renderer.hasCaptions && !renderer.hasRedactions && !renderer.hasZooms && !map.hasCuts
            && presentAudioKinds.count <= 1
            && !audioNeedsMixing(project: project, presentAudio: presentAudioKinds)
        guard !passthrough else {
            return Built(
                composition: composition, videoComposition: nil, audioMix: nil, project: project, map: map, cues: cues,
                passthrough: true)
        }
        let instruction = TakelyInstruction(
            timeRange: CMTimeRange(start: .zero, duration: composition.duration),
            screenTrackID: screenTrack.trackID,
            cameraTrackID: tracks[.camera]?.trackID,
            cameraCoverage: cameraCoverage,
            renderer: renderer,
            map: map
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

        // Joins on the output timeline (the end of each kept range but the last).
        var joins: [Double] = []
        var position = 0.0
        for kept in map.kept.dropLast() {
            position += kept.duration
            joins.append(position)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [TrackKind.system, .mic].compactMap { kind in
            tracks[kind].map {
                let parameters = AVMutableAudioMixInputParameters(track: $0)
                let volume = Exporter.volume(for: kind, in: project)
                parameters.setVolume(volume, at: .zero)
                for join in joins {
                    let out = CMTimeRange(
                        start: CMTime(seconds: max(0, join - fade), preferredTimescale: 48_000),
                        end: CMTime(seconds: join, preferredTimescale: 48_000))
                    let back = CMTimeRange(start: out.end, duration: CMTime(seconds: fade, preferredTimescale: 48_000))
                    parameters.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: out)
                    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: back)
                }
                return parameters
            }
        }
        return Built(
            composition: composition, videoComposition: AVVideoComposition(configuration: configuration), audioMix: mix,
            project: project, map: map, cues: cues, passthrough: false)
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

    private static func addTrack(_ kind: TrackKind, to composition: AVMutableComposition) throws -> AVMutableCompositionTrack {
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
