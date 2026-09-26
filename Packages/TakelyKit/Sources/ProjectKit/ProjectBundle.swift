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
    public var segmentsURL: URL { url.appending(path: "segments", directoryHint: .isDirectory) }
    public var exportsURL: URL { url.appending(path: "exports", directoryHint: .isDirectory) }

    public func segmentURL(_ file: String) -> URL { segmentsURL.appending(path: file) }

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

    public func write(_ cursor: CursorTrack) throws {
        try JSONEncoder().encode(cursor).write(to: cursorURL, options: .atomic)
    }
}
