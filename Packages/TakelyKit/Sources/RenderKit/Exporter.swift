import AVFoundation
import CoreImage
import ImageIO
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
        let markers = Self.outputMarkers((try? bundle.readMarkers()) ?? [], map: map)
        let cues = built.cues.compactMap { cue in
            map.output(TimeRange(start: cue.start, end: cue.end)).map { CaptionCue(start: $0.start, end: $0.end, text: cue.text) }
        }
        let transcript = bundle.captionTranscript()

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
        // Done: recovery won't offer it again even if the MP4 is moved out of the bundle later.
        if var finished = try? bundle.readProject() {
            finished.exportedAt = .now
            try? bundle.write(finished)
        }
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
        let renderer: FrameRenderer

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
        // Captions: the transcript, or else the narration's own text (exact, nothing to recognize).
        let transcript = bundle.captionTranscript()
        let cues = transcript?.cues() ?? []
        let narration = (try? bundle.readNarration()) ?? []
        let redactions = try bundle.readRedactions()
        let map = EditMap(cuts: edits.cuts, duration: project.duration)
        guard map.outputDuration > 0 else { throw RenderError.emptyRecording }
        let composition = AVMutableComposition()
        var tracks: [TrackKind: AVMutableCompositionTrack] = [:]
        var cameraCoverage: [CMTimeRange] = []
        typealias Source = (kind: TrackKind, track: AVAssetTrack, range: CMTimeRange)
        // The assets stay referenced until everything is inserted: a track only weakly references its asset.
        var loaded: [(asset: AVURLAsset, offset: Double, duration: Double, sources: [Source])] = []
        var offset = 0.0
        for segment in project.segments {
            let asset = AVURLAsset(url: bundle.segmentURL(segment.file))
            let sources = try await asset.load(.tracks).sorted { $0.trackID < $1.trackID }
            guard sources.count == segment.tracks.count else {
                throw RenderError.trackMismatch("\(segment.file): \(sources.count) tracks, manifest lists \(segment.tracks.count)")
            }
            var kept: [Source] = []
            for (kind, source) in zip(segment.tracks, sources) {
                // The raw microphone is kept for re-processing only: exporting it would bring the echo back.
                guard kind != .micRaw, kind != .camera || project.camera.enabled else { continue }
                kept.append((kind, source, try await source.load(.timeRange)))
            }
            loaded.append((asset, offset, segment.duration, kept))
            offset += segment.duration
        }
        // Each kept piece is placed right where the previous one ended (in exact ticks, not re-rounded seconds),
        // so the tracks have no gaps or overlaps at the joins and every track joins at the same instant.
        var out = CMTime.zero
        var joins: [CMTime] = []
        for (index, kept) in map.kept.enumerated() {
            for segment in loaded {
                let a = CMTime(seconds: max(kept.start, segment.offset) - segment.offset, preferredTimescale: 600)
                let b = CMTime(seconds: min(kept.end, segment.offset + segment.duration) - segment.offset, preferredTimescale: 600)
                guard b > a else { continue }
                for source in segment.sources {
                    let start = CMTimeMaximum(a, source.range.start)
                    let end = CMTimeMinimum(b, source.range.end)
                    guard end > start else { continue }
                    let track = try tracks[source.kind] ?? addTrack(source.kind, to: composition)
                    tracks[source.kind] = track
                    let at = out + (start - a)
                    try track.insertTimeRange(CMTimeRange(start: start, end: end), of: source.track, at: at)
                    if source.kind == .camera { cameraCoverage.append(CMTimeRange(start: at, duration: end - start)) }
                }
                out = out + (b - a)
            }
            if index < map.kept.count - 1 { joins.append(out) }
        }
        guard let screenTrack = tracks[.screen] else { throw RenderError.trackMismatch("no screen track") }

        // Narration: each clip where its line was spoken (one whose moment was cut starts at the join), never past the
        // end of the video.
        var narrationTrack: AVMutableCompositionTrack?
        var narrationAssets: [AVURLAsset] = []  // referenced until inserted (tracks hold their asset weakly)
        var spokenLines: [(t: Double, rms: [Float])] = []  // where each line plays in the output (moves the avatar's mouth)
        var spoken = CMTime.zero
        for clip in narration {
            let t = map.position(clip.t)
            let asset = AVURLAsset(url: bundle.narrationURL.appending(path: clip.file))
            narrationAssets.append(asset)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first, let range = try? await source.load(.timeRange)
            else { continue }
            let track = try narrationTrack ?? addTrack(.mic, to: composition)
            narrationTrack = track
            let at = CMTimeMaximum(CMTime(seconds: t, preferredTimescale: 48_000), spoken)
            let room = CMTime(seconds: map.outputDuration, preferredTimescale: 48_000) - at
            guard room > .zero else { continue }
            let length = CMTimeMinimum(range.duration, room)
            try track.insertTimeRange(CMTimeRange(start: range.start, duration: length), of: source, at: at)
            spoken = at + length
            if let rms = Self.loudness(of: asset.url) {
                spokenLines.append((at.seconds, Array(rms.prefix(Int((length.seconds * VoiceLevels.rate).rounded(.up))))))
            }
        }
        _ = narrationAssets
        // The avatar stands in for a camera that wasn't recorded, and talks when the narration does (output time).
        let avatar = tracks[.camera] == nil && !spokenLines.isEmpty ? Self.avatarImage(bundle) : nil
        let renderer = FrameRenderer(
            project: project, cursor: cursorTrack, captions: cues, redactions: redactions, zooms: edits.zooms,
            avatar: avatar.map { ($0.image, $0.face, VoiceLevels.place(spokenLines, duration: map.outputDuration)) })

        let presentAudioKinds = [TrackKind.system, .mic].filter { tracks[$0] != nil }
        let passthrough =
            !needsCompositing(project: project, cursor: cursorTrack, hasCameraTrack: tracks[.camera] != nil)
            && !renderer.hasCaptions && !renderer.hasRedactions && !renderer.hasZooms && !map.hasCuts && narrationTrack == nil
            && !renderer.hasAvatar
            && presentAudioKinds.count <= 1
            && !audioNeedsMixing(project: project, presentAudio: presentAudioKinds)
        guard !passthrough else {
            return Built(
                composition: composition, videoComposition: nil, audioMix: nil, project: project, map: map, cues: cues,
                passthrough: true, renderer: renderer)
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

        let mix = AVMutableAudioMix()
        mix.inputParameters = [TrackKind.system, .mic].compactMap { kind in
            tracks[kind].map {
                let parameters = AVMutableAudioMixInputParameters(track: $0)
                let volume = Exporter.volume(for: kind, in: project)
                parameters.setVolume(volume, at: .zero)
                // Kept ranges are at least `EditMap.minimumKept` (> 2 fades) long, so the ramps never overlap.
                let length = CMTime(seconds: fade, preferredTimescale: 48_000)
                for join in joins {
                    parameters.setVolumeRamp(
                        fromStartVolume: volume, toEndVolume: 0, timeRange: CMTimeRange(start: join - length, end: join))
                    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: join, duration: length))
                }
                return parameters
            }
        }
        return Built(
            composition: composition, videoComposition: AVVideoComposition(configuration: configuration), audioMix: mix,
            project: project, map: map, cues: cues, passthrough: false, renderer: renderer)
    }

    /// Chapters on the output timeline: one whose start was cut begins where the cut joins; one cut entirely (or
    /// pushed onto the start, or onto the next chapter) is dropped.
    static func outputMarkers(_ markers: [Marker], map: EditMap) -> [Marker] {
        let sorted = markers.sorted { $0.t < $1.t }
        var result: [Marker] = []
        for (i, marker) in sorted.enumerated() {
            let end = i + 1 < sorted.count ? sorted[i + 1].t : map.duration
            guard let span = map.output(TimeRange(start: marker.t, end: end)), span.start > 0.001 else { continue }
            result.append(Marker(t: span.start, title: marker.title))
        }
        return result
    }

    /// The bundle's avatar portrait and face, decoded once.
    static func avatarImage(_ bundle: ProjectBundle) -> (image: CIImage, face: AvatarFace)? {
        guard let face = bundle.readAvatarFace(), let source = CGImageSourceCreateWithURL(bundle.avatarImageURL as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (CIImage(cgImage: image), face)
    }

    /// RMS loudness of an audio file, `VoiceLevels.rate` values a second.
    static func loudness(of url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0]
        else { return nil }
        let window = max(1, Int(file.processingFormat.sampleRate / VoiceLevels.rate))
        let frames = Int(buffer.frameLength)
        return stride(from: 0, to: frames, by: window).map { start in
            let end = min(frames, start + window)
            var sum: Float = 0
            for i in start..<end { sum += channel[i] * channel[i] }
            return (sum / Float(max(1, end - start))).squareRoot()
        }
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
