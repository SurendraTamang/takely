import AVFoundation
import ProjectKit

/// A recording that wasn't finished or exported, found at launch.
public struct RecoveryCandidate: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The app stopped mid-recording; the manifest still says `recording`.
        case crashed
        /// The recording finished (e.g. system quit) but no export exists.
        case unexported
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
                    return bundle.hasExport ? nil : RecoveryCandidate(bundle: bundle, kind: .unexported, createdAt: project.createdAt)
                }
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Rebuilds a crashed bundle's segment list from the segment files and their sidecars, then marks it finished.
    ///
    /// Track kinds come from each sidecar by track ID: the writer numbers tracks 1…n in configured order and
    /// keeps those IDs when it leaves out empty inputs, so sidecar entry `i` is track ID `i + 1`.
    public static func rebuild(_ bundle: ProjectBundle) async throws -> RebuildReport {
        var project = try bundle.readProject()
        let files = try FileManager.default.contentsOfDirectory(atPath: bundle.segmentsURL.path)
            .filter { $0.hasPrefix("segment-") && $0.hasSuffix(".mov") }
            .sorted()
        var segments: [Project.Segment] = []
        var skipped: [String] = []
        for file in files {
            if let segment = await readSegment(file, in: bundle) {
                segments.append(segment)
            } else {
                skipped.append(file)
            }
        }
        guard !segments.isEmpty else { throw RecoveryError.nothingRecoverable }
        project.segments = segments
        project.status = .finished
        try bundle.write(project)
        return RebuildReport(project: project, skipped: skipped)
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
        guard kinds.count == tracks.count, kinds.contains(.screen) else { return nil }
        return Project.Segment(file: file, duration: duration, tracks: kinds)
    }
}
