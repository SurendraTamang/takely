import Foundation

/// A `.takely` package directory on disk.
public struct ProjectBundle: Sendable, Hashable {
    public static let pathExtension = "takely"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var manifestURL: URL { url.appending(path: "project.json") }
    public var cursorURL: URL { url.appending(path: "cursor.json") }
    public var markersURL: URL { url.appending(path: "markers.json") }
    public var transcriptURL: URL { url.appending(path: "transcript.json") }
    /// Captions for the export, next to it: `exports/<name>.vtt`.
    public var captionsURL: URL { exportURL.deletingPathExtension().appendingPathExtension("vtt") }
    public var segmentsURL: URL { url.appending(path: "segments", directoryHint: .isDirectory) }
    public var exportsURL: URL { url.appending(path: "exports", directoryHint: .isDirectory) }

    public func segmentURL(_ file: String) -> URL { segmentsURL.appending(path: file) }

    /// `segment-NNN.json` next to `segment-NNN.mov`: the configured track kinds, written when the segment opens.
    public func sidecarURL(for file: String) -> URL {
        segmentURL(file).deletingPathExtension().appendingPathExtension("json")
    }

    /// Where the finished export lives. Only a completed export is ever moved here.
    public var exportURL: URL { exportsURL.appending(path: "\(name).mp4") }

    public var hasExport: Bool { FileManager.default.fileExists(atPath: exportURL.path) }

    public static func segmentFileName(index: Int) -> String {
        "segment-" + String(format: "%03d", index) + ".mov"
    }

    /// Creates `Recording-yyyy-MM-dd-HH-mm-ss.takely` (local time; `-2`, `-3`, … if taken) with `segments/` and `exports/` inside `folder`.
    public static func create(in folder: URL, date: Date = .now) throws -> ProjectBundle {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Local time on purpose: the name matches the wall clock the user saw; createdAt in project.json stays UTC.
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let base = "Recording-\(formatter.string(from: date))"
        let fm = FileManager.default
        // Same-second starts get "-2", "-3", … like Finder, instead of reusing an existing bundle.
        var name = base
        var suffix = 2
        while fm.fileExists(atPath: folder.appending(path: "\(name).\(pathExtension)").path) {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        let bundle = ProjectBundle(url: folder.appending(path: "\(name).\(pathExtension)", directoryHint: .isDirectory))
        try fm.createDirectory(at: bundle.segmentsURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.exportsURL, withIntermediateDirectories: true)
        return bundle
    }

    public func readProject() throws -> Project {
        try Project.decode(Data(contentsOf: manifestURL))
    }

    public func write(_ project: Project) throws {
        try project.encoded().write(to: manifestURL, options: .atomic)
    }

    /// Missing `cursor.json` reads as an empty track.
    public func readCursor() throws -> CursorTrack {
        guard FileManager.default.fileExists(atPath: cursorURL.path) else { return CursorTrack() }
        return try JSONDecoder().decode(CursorTrack.self, from: Data(contentsOf: cursorURL))
    }

    public func writeSidecar(tracks: [TrackKind], for file: String) throws {
        try JSONEncoder().encode(SegmentSidecar(tracks: tracks)).write(to: sidecarURL(for: file), options: .atomic)
    }

    /// Track kinds in track-ID order (entry `i` is track ID `i + 1`), or `nil` if the sidecar is missing.
    public func readSidecar(for file: String) throws -> [TrackKind]? {
        let url = sidecarURL(for: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SegmentSidecar.self, from: Data(contentsOf: url)).tracks
    }

    public func readTranscript() throws -> Transcript? {
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else { return nil }
        return try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: transcriptURL))
    }

    public func write(_ transcript: Transcript) throws {
        try JSONEncoder().encode(transcript).write(to: transcriptURL, options: .atomic)
    }

    public func readMarkers() throws -> [Marker] {
        guard FileManager.default.fileExists(atPath: markersURL.path) else { return [] }
        return try JSONDecoder().decode([Marker].self, from: Data(contentsOf: markersURL))
    }

    public func write(_ markers: [Marker]) throws {
        try JSONEncoder().encode(markers).write(to: markersURL, options: .atomic)
    }

    public func write(_ cursor: CursorTrack) throws {
        try JSONEncoder().encode(cursor).write(to: cursorURL, options: .atomic)
    }
}

/// What a segment was configured to record, saved before any media so a crashed segment can be recovered.
struct SegmentSidecar: Codable {
    var tracks: [TrackKind]
}
