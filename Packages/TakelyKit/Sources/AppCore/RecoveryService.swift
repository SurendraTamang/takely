import AVFoundation
import ProjectKit

/// A recording that wasn't finished or exported, found at launch.
public struct RecoveryCandidate: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The app stopped mid-recording; the manifest still says `recording`.
        case crashed
        /// The recording finished (e.g. system quit) but no export exists.
        case unexported
        /// Finished but holds no video (no screen frame ever arrived); it can only be deleted.
        case empty
    }

    public let bundle: ProjectBundle
    public let kind: Kind
    public let createdAt: Date
}

public struct RebuildReport: Sendable, Equatable {
    public let project: Project
    /// Segment files that couldn't be used (no sidecar, unreadable, or no screen track).
    public let skipped: [String]
}

public enum RecoveryError: Error, Equatable {
    case nothingRecoverable
}

extension RecoveryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nothingRecoverable: "No usable video was found in this recording."
        }
    }
}

public enum RecoveryService {
    /// Bundles in `folder` that crashed mid-recording or were never exported, oldest first.
    public static func scan(_ folder: URL) -> [RecoveryCandidate] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return
            names
            .filter { $0.hasSuffix(".\(ProjectBundle.pathExtension)") }
            .compactMap { name -> RecoveryCandidate? in
                let bundle = ProjectBundle(url: folder.appending(path: name, directoryHint: .isDirectory))
                guard let project = try? bundle.readProject() else { return nil }
                switch project.status {
                case .recording: return RecoveryCandidate(bundle: bundle, kind: .crashed, createdAt: project.createdAt)
                case .finished:
                    if bundle.hasExport || project.exportedAt != nil { return nil }
                    return RecoveryCandidate(
                        bundle: bundle, kind: project.segments.isEmpty ? .empty : .unexported, createdAt: project.createdAt)
                }
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Recovers a crashed bundle. Segments already in the manifest were closed normally and match `cursor.json`,
    /// so they're kept as they are; only segment files after the last listed one (the segment open at the crash)
    /// are rebuilt, from each file and its sidecar by track ID. Marks the bundle finished. Non-crashed bundles are left alone.
    public static func rebuild(_ bundle: ProjectBundle) async throws -> RebuildReport {
        var project = try bundle.readProject()
        guard project.status == .recording else { return RebuildReport(project: project, skipped: []) }
        let lastListed = project.segments.compactMap { segmentIndex($0.file) }.max() ?? -1
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bundle.segmentsURL.path)) ?? []
        let tail = names.compactMap { name in segmentIndex(name).map { (name: name, index: $0) } }
            .filter { $0.index > lastListed }
            .sorted { $0.index < $1.index }
            .map(\.name)
        var recovered: [Project.Segment] = []
        var skipped: [String] = []
        for file in tail {
            if let segment = await readSegment(file, in: bundle) { recovered.append(segment) } else { skipped.append(file) }
        }
        let closedDuration = project.duration
        project.segments += recovered
        guard !project.segments.isEmpty else { throw RecoveryError.nothingRecoverable }
        project.status = .finished
        if !recovered.isEmpty {
            // The recovered tail has no cursor data (it's written when a segment closes): end cursor effects where it stops.
            var cursor = try bundle.readCursor()
            cursor.coveredUntil = closedDuration
            try bundle.write(cursor)
        }
        try bundle.write(project)
        return RebuildReport(project: project, skipped: skipped)
    }

    /// `segment-012.mov` → 12 (numeric, so `segment-1000` sorts after `segment-101`); nil for other files.
    static func segmentIndex(_ file: String) -> Int? {
        guard file.hasPrefix("segment-"), file.hasSuffix(".mov") else { return nil }
        return Int(file.dropFirst("segment-".count).dropLast(".mov".count))
    }

    private static func readSegment(_ file: String, in bundle: ProjectBundle) async -> Project.Segment? {
        // No sidecar means no reliable way to tell the tracks apart, so don't guess.
        guard let configured = try? bundle.readSidecar(for: file) else { return nil }
        let asset = AVURLAsset(url: bundle.segmentURL(file))
        guard let tracks = try? await asset.load(.tracks).sorted(by: { $0.trackID < $1.trackID }),
            let duration = try? await asset.load(.duration).seconds, duration > 0
        else { return nil }
        let kinds = tracks.compactMap { track -> TrackKind? in
            let index = Int(track.trackID) - 1
            return configured.indices.contains(index) ? configured[index] : nil
        }
        guard kinds.count == tracks.count, let screenIndex = kinds.firstIndex(of: .screen) else { return nil }
        guard let screenRange = try? await tracks[screenIndex].load(.timeRange), screenRange.duration.seconds > 0 else { return nil }
        return Project.Segment(file: file, duration: duration, tracks: kinds)
    }
}
