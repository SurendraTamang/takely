@preconcurrency import AVFoundation
import Foundation
import ImageIO
import ProjectKit
import UniformTypeIdentifiers

/// A recording's shared copy (`share.json`): where it is, and which files make it up, so it can be copied,
/// re-uploaded (same link) or deleted. Written before the first file goes up, so nothing is ever left unreachable.
public struct ShareRecord: Codable, Sendable, Equatable {
    public var id: String
    public var url: URL
    public var sharedAt: Date
    /// The bucket it went to (deleting it later must go there, even if settings changed since).
    public var endpoint: URL
    public var bucket: String
    /// The object keys uploaded (removed when re-uploading replaces them, or when sharing stops).
    public var keys: [String]
    /// False until the page is up.
    public var complete: Bool
}

extension ProjectBundle {
    public var shareRecordURL: URL { url.appending(path: "share.json") }

    public func readShareRecord() -> ShareRecord? {
        (try? Data(contentsOf: shareRecordURL)).flatMap { try? JSONDecoder().decode(ShareRecord.self, from: $0) }
    }

    func write(_ record: ShareRecord) throws {
        try JSONEncoder().encode(record).write(to: shareRecordURL, options: .atomic)
    }
}

/// Uploads a finished recording (its export) with a player page to the user's bucket, and removes it again.
public struct ShareService: Sendable {
    let client: S3Client
    static let folder = "takely"
    /// Media is named per upload (video-<version>.mp4…) and cached for good: a CDN can never keep serving an older
    /// version (say, before a secret was blurred). The page and oEmbed are never cached, and point at the latest.
    static let mediaCache = "public, max-age=31536000, immutable"
    static let pageCache = "no-cache"

    public init(client: S3Client) {
        self.client = client
    }

    /// Uploads the recording; returns its link. A recording shared before keeps its link: its previous files are
    /// replaced. `includeText` puts the captions, title and summary on the page (they come from what was said).
    /// `snapshot`: upload exactly these files (copied and checked beforehand — automation), not what's in the bundle now.
    public func share(
        _ bundle: ProjectBundle, includeText: Bool = true, snapshot: ShareSnapshot? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard snapshot != nil || FileManager.default.fileExists(atPath: bundle.exportURL.path) else { throw ShareError.notExported }
        let previous = bundle.readShareRecord()
        if let previous, !isTarget(previous) { throw ShareError.otherBucket(previous.bucket) }
        let id = previous?.id ?? Self.newID()
        let prefix = "\(Self.folder)/\(id)"
        let base = client.config.publicURL.appending(path: Self.folder).appending(path: id)
        let version = String(Self.newID().prefix(8))
        let videoName = "video-\(version).mp4"
        let poster = "poster-\(version).jpg"
        let captions = "captions-\(version).vtt"
        var record = ShareRecord(
            id: id, url: base.appending(path: "index.html"), sharedAt: .now, endpoint: client.config.endpoint,
            bucket: client.config.bucket, keys: (previous?.keys ?? []) + [videoName, poster, captions].map { "\(prefix)/\($0)" },
            complete: false)
        try bundle.write(record)

        // A snapshot (an APFS clone: instant, no extra space): a re-export meanwhile can't mix two versions.
        let video: URL
        if let given = snapshot {
            video = given.video
        } else {
            video = FileManager.default.temporaryDirectory.appending(path: "takely-share-\(UUID().uuidString).mp4")
            try FileManager.default.copyItem(at: bundle.exportURL, to: video)
        }
        defer { if snapshot == nil { try? FileManager.default.removeItem(at: video) } }
        let asset = AVURLAsset(url: video)
        let project = try? bundle.readProject()

        var uploaded = ["index.html", "oembed.json", videoName]
        try await client.upload(video, key: "\(prefix)/\(videoName)", contentType: "video/mp4", cacheControl: Self.mediaCache) {
            progress($0 * 0.9)
        }
        var posterName: String?
        if let data = await Self.poster(asset) {
            try await client.put("\(prefix)/\(poster)", data: data, contentType: "image/jpeg", cacheControl: Self.mediaCache)
            posterName = poster
            uploaded.append(poster)
        }
        var captionsName: String?
        let captionsData = snapshot.map { $0.captions } ?? (try? Data(contentsOf: bundle.captionsURL))
        if includeText, let captionsData {
            try await client.put(
                "\(prefix)/\(captions)", data: captionsData, contentType: "text/vtt; charset=utf-8", cacheControl: Self.mediaCache)
            captionsName = captions
            uploaded.append(captions)
        }
        let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        let page = SharePage(
            title: includeText ? project?.title ?? "Recording" : "Recording", summary: includeText ? project?.summary : nil,
            chapters: includeText ? await Self.chapters(asset) : [], duration: duration, width: Int(size.width), height: Int(size.height),
            base: base, video: videoName, poster: posterName, captions: captionsName)
        try await client.put(
            "\(prefix)/oembed.json", data: page.oEmbed, contentType: "application/json+oembed", cacheControl: Self.pageCache)
        // The page last: the link shows the new version only once everything it shows is there.
        try await client.put(
            "\(prefix)/index.html", data: Data(page.html.utf8), contentType: "text/html; charset=utf-8", cacheControl: Self.pageCache)
        // The previous version's files are gone from the bucket once the page no longer points at them.
        let current = Set(uploaded.map { "\(prefix)/\($0)" })
        for key in Set(record.keys).subtracting(current) { try? await client.delete(key) }
        record.keys = current.sorted()
        record.complete = true
        record.sharedAt = .now
        try bundle.write(record)
        progress(1)
        return record.url
    }

    /// Deletes the shared copy (the link stops working) and forgets it.
    public func unshare(_ bundle: ProjectBundle) async throws {
        guard let record = bundle.readShareRecord() else { return }
        guard isTarget(record) else { throw ShareError.otherBucket(record.bucket) }
        for key in record.keys { try await client.delete(key) }
        try? FileManager.default.removeItem(at: bundle.shareRecordURL)
    }

    /// Whether a record was shared to the bucket this service writes to.
    func isTarget(_ record: ShareRecord) -> Bool {
        record.endpoint == client.config.endpoint && record.bucket == client.config.bucket
    }

    /// Writes and deletes a small file: checks the keys, the bucket and write access.
    public func testConnection() async throws {
        let key = "\(Self.folder)/.connection-test"
        try await client.put(key, data: Data("ok".utf8), contentType: "text/plain")
        try await client.delete(key)
    }

    /// 128 random bits, base32 (26 characters): an unlisted link nobody can guess.
    static func newID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var generator = SystemRandomNumberGenerator()
        var bits = UInt128(generator.next()) << 64 | UInt128(generator.next())
        return String(
            (0..<26).map { _ in
                defer { bits >>= 5 }
                return alphabet[Int(bits & 31)]
            })
    }

    public static func poster(_ asset: AVURLAsset) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard let image = try? await generator.image(at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)).image else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The export's chapters (already on the edited timeline), without the implicit "Start".
    static func chapters(_ asset: AVURLAsset) async -> [SharePage.Chapter] {
        guard let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en"]) else { return [] }
        var chapters: [SharePage.Chapter] = []
        for group in groups where group.timeRange.start.seconds.isFinite {
            let title = (try? await group.items.first?.load(.stringValue)) ?? nil
            chapters.append(SharePage.Chapter(t: group.timeRange.start.seconds, title: title ?? ""))
        }
        return chapters.count > 1 ? chapters : []
    }
}

public enum ShareError: Error, LocalizedError {
    case notExported
    case notConfigured
    case otherBucket(String)
    case unsafeFile

    public var errorDescription: String? {
        switch self {
        case .notExported: "This recording hasn't been exported yet."
        case .notConfigured: "Set up sharing first: Settings › Share."
        case .unsafeFile:
            "This recording can't be shared safely: its files aren't where Takely saved them (a link or a linked file). Share it from Takely."
        case .otherBucket(let bucket):
            "This recording was shared to another bucket (\(bucket)). Switch back to it in Settings › Share to change or remove it."
        }
    }
}

/// Files to share exactly as they were checked: a private copy of the video (and the captions' bytes), made without
/// following symbolic links. Automation shares these, so what the person confirmed is what's uploaded.
public struct ShareSnapshot: Sendable {
    public let folder: URL
    public let video: URL
    public let captions: Data?

    /// Copies `bundle`'s export (and captions) into a new private folder. Refuses unless the bundle sits directly in
    /// one of `folders` (checked on what's actually opened), with no symbolic link under it, and each file is a
    /// regular file with no other hard link (else it could be any file on the volume). Captions that aren't WebVTT
    /// are left out.
    public static func make(of bundle: ProjectBundle, inside folders: [URL]) throws -> ShareSnapshot {
        let allowed = Set(folders.compactMap(realPath))
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "takely-share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let video = folder.appending(path: "video.mp4")
            try copyNoFollow(bundle.exportURL, under: bundle.url, inside: allowed, to: video)
            let captions = (try? readNoFollow(bundle.captionsURL, under: bundle.url, inside: allowed)).flatMap {
                $0.starts(with: Data("WEBVTT".utf8)) ? $0 : nil
            }
            return ShareSnapshot(folder: folder, video: video, captions: captions)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    public func discard() { try? FileManager.default.removeItem(at: folder) }

    /// `file` must lie under `root` with no symbolic link on the way (the folder, `exports/`, the file itself), and
    /// `root` directly in one of `allowed` (real paths).
    static func open(_ file: URL, under root: URL, inside allowed: Set<String>) throws -> Int32 {
        // realpath(3), not resolvingSymlinksInPath: that drops /private, which F_GETPATH keeps.
        let relative = file.path.hasPrefix(root.path + "/") ? String(file.path.dropFirst(root.path.count + 1)) : nil
        guard let relative, let real = realPath(root), allowed.contains((real as NSString).deletingLastPathComponent),
            realPath(file) == real + "/" + relative
        else { throw ShareError.unsafeFile }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ShareError.unsafeFile }
        // What was opened, not what the path pointed to a moment ago (a folder swapped for a link in between).
        var opened = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var info = stat()
        guard fcntl(fd, F_GETPATH, &opened) == 0,
            String(decoding: opened.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == real + "/" + relative,
            fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1
        else {
            close(fd)
            throw ShareError.unsafeFile
        }
        return fd
    }

    static func realPath(_ url: URL) -> String? {
        guard let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func readNoFollow(_ file: URL, under root: URL, inside allowed: Set<String>) throws -> Data {
        let fd = try open(file, under: root, inside: allowed)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
    }

    static func copyNoFollow(_ file: URL, under root: URL, inside allowed: Set<String>, to destination: URL) throws {
        let source = FileHandle(fileDescriptor: try open(file, under: root, inside: allowed), closeOnDealloc: true)
        // An APFS clone of the checked descriptor (instant, no extra space); a plain copy across volumes.
        if fclonefileat(source.fileDescriptor, AT_FDCWD, destination.path, 0) == 0 { return }
        let out = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else { throw ShareError.notExported }
        let sink = FileHandle(fileDescriptor: out, closeOnDealloc: true)
        while let chunk = try source.read(upToCount: 8 << 20), !chunk.isEmpty { try sink.write(contentsOf: chunk) }
    }
}
