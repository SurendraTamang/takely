@preconcurrency import AVFoundation
import CryptoKit
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

        // What's published: automation's snapshot as the person saw it, else a clone of the export now (instant, no
        // extra space; a re-export meanwhile can't mix two versions).
        let facts: ShareSnapshot
        if let snapshot {
            facts = snapshot
        } else {
            let folders = [bundle.url.deletingLastPathComponent()]
            facts = try await ShareSnapshot.make(of: bundle, inside: folders, strict: false)
        }

        var uploaded = ["index.html", "oembed.json", videoName]
        // The descriptor is only open while `facts` lives: kept alive until the upload is done.
        defer { withExtendedLifetime(facts) {} }
        try await client.upload(
            descriptor: facts.descriptor, sealed: facts.sealed, key: "\(prefix)/\(videoName)", contentType: "video/mp4",
            cacheControl: Self.mediaCache
        ) { progress($0 * 0.9) }
        var posterName: String?
        if let data = facts.poster {
            try await client.put("\(prefix)/\(poster)", data: data, contentType: "image/jpeg", cacheControl: Self.mediaCache)
            posterName = poster
            uploaded.append(poster)
        }
        var captionsName: String?
        if includeText, let captionsData = facts.captions {
            try await client.put(
                "\(prefix)/\(captions)", data: captionsData, contentType: "text/vtt; charset=utf-8", cacheControl: Self.mediaCache)
            captionsName = captions
            uploaded.append(captions)
        }
        let page = SharePage(
            title: includeText ? facts.title ?? "Recording" : "Recording", summary: includeText ? facts.summary : nil,
            chapters: includeText ? facts.chapters : [], duration: facts.duration, width: Int(facts.dimensions.width),
            height: Int(facts.dimensions.height), base: base, video: videoName, poster: posterName, captions: captionsName)
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
    case unreadableVideo
    case changedWhileReading
    case copyFailed

    public var errorDescription: String? {
        switch self {
        case .notExported: "This recording hasn't been exported yet."
        case .notConfigured: "Set up sharing first: Settings › Share."
        case .unreadableVideo: "The recording's video can't be read, so Takely can't show what would be shared."
        case .changedWhileReading: "The recording changed while Takely was preparing it, so it wasn't shared. Try again."
        case .copyFailed: "Takely couldn't make a private copy of the recording to share (is the disk full?)."
        case .unsafeFile:
            "This recording can't be shared safely: its files aren't where Takely saved them (a link or a linked file). Share it from Takely."
        case .otherBucket(let bucket):
            "This recording was shared to another bucket (\(bucket)). Switch back to it in Settings › Share to change or remove it."
        }
    }
}

/// What's shared, fixed before the person is asked: the video (a private copy no other process can open any more,
/// only through this descriptor), the preview and facts read from it, and the text published with it.
public final class ShareSnapshot: Sendable {
    let descriptor: Int32
    /// The copy's size and a SHA-256 per upload part (strict snapshots): each part is checked before it's sent.
    let sealed: (size: Int, parts: [SHA256.Digest])?
    public let poster: Data?
    public let duration: Double
    public let dimensions: CGSize
    public let chapters: [SharePage.Chapter]
    public let title: String?
    public let summary: String?
    public let captions: Data?

    init(
        descriptor: Int32, sealed: (size: Int, parts: [SHA256.Digest])?, poster: Data?, duration: Double, dimensions: CGSize,
        chapters: [SharePage.Chapter], title: String?, summary: String?, captions: Data?
    ) {
        self.descriptor = descriptor
        self.sealed = sealed
        self.poster = poster
        self.duration = duration
        self.dimensions = dimensions
        self.chapters = chapters
        self.title = title
        self.summary = summary
        self.captions = captions
    }

    deinit { close(descriptor) }

    /// Strict (automation): the bundle must sit directly in one of `folders` (checked on what's actually opened),
    /// with no symbolic link under it, and each file must be a regular file with no other hard link (else it could be
    /// any file on the volume); captions that aren't WebVTT are left out; there must be a preview; and the copy is
    /// hashed before and after the preview is read, and checked again part by part as it's uploaded.
    /// Not strict (the person shares it from Takely): the export as it is, links and all.
    public static func make(of bundle: ProjectBundle, inside folders: [URL], strict: Bool = true) async throws -> ShareSnapshot {
        let allowed = Set(folders.compactMap(realPath))
        let source =
            strict
            ? try open(bundle.exportURL, under: bundle.url, inside: allowed) : Darwin.open(bundle.exportURL.path, O_RDONLY | O_CLOEXEC)
        guard source >= 0 else { throw ShareError.notExported }
        let descriptor: Int32
        do {
            defer { close(source) }
            descriptor = try privateCopy(of: source)
        }
        var kept = false
        defer { if !kept { close(descriptor) } }
        let before = strict ? try partDigests(descriptor) : nil

        // Read through this process's own descriptor: no path another process could swap meanwhile.
        let asset = AVURLAsset(url: URL(filePath: "/dev/fd/\(descriptor)"), options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        guard (try? await asset.loadTracks(withMediaType: .video).isEmpty) == false else { throw ShareError.unreadableVideo }
        let poster = await ShareService.poster(asset)
        if strict, poster == nil { throw ShareError.unreadableVideo }
        let duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        let dimensions =
            (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let chapters = await ShareService.chapters(asset)

        // Only a handle opened in the instant the copy had a name could still write to it: a change while the
        // preview was read shows here, a later one when its part is uploaded.
        let after = strict ? try partDigests(descriptor) : nil
        if let before, let after, before.parts != after.parts || before.size != after.size {
            throw ShareError.changedWhileReading
        }
        func read(_ file: URL) -> Data? {
            strict ? try? readNoFollow(file, under: bundle.url, inside: allowed) : try? Data(contentsOf: file)
        }
        let captions = read(bundle.captionsURL).flatMap { $0.starts(with: Data("WEBVTT".utf8)) ? $0 : nil }
        let project = read(bundle.manifestURL).flatMap { try? Project.decode($0) }
        kept = true
        return ShareSnapshot(
            descriptor: descriptor, sealed: after, poster: poster, duration: duration, dimensions: dimensions, chapters: chapters,
            title: project?.title, summary: project?.summary, captions: captions)
    }

    /// A copy of `source` in a new private folder (an APFS clone: instant, no extra space; else copied), opened and
    /// deleted at once. Refused unless it then has no name left (another hard link, or the folder swapped for a link
    /// so the delete missed it).
    static func privateCopy(of source: Int32) throws -> Int32 {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "takely-share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { rmdir(folder.path) }
        let path = folder.appending(path: "video.mp4").path
        var descriptor: Int32
        if fclonefileat(source, AT_FDCWD, path, 0) == 0 {
            descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        } else {
            descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if descriptor >= 0, (try? copy(from: source, to: descriptor)) == nil {
                close(descriptor)
                descriptor = -1
            }
        }
        unlink(path)
        guard descriptor >= 0 else { throw ShareError.copyFailed }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_nlink == 0 else {
            close(descriptor)
            throw ShareError.unsafeFile
        }
        return descriptor
    }

    static func copy(from source: Int32, to destination: Int32) throws {
        var offset = 0
        while true {
            let chunk = try readFully(source, offset..<(offset + (8 << 20)), exact: false)
            if chunk.isEmpty { return }
            let written = chunk.withUnsafeBytes { pwrite(destination, $0.baseAddress, chunk.count, off_t(offset)) }
            guard written == chunk.count else { throw ShareError.copyFailed }
            offset += chunk.count
        }
    }

    /// The size and a SHA-256 of each part, as `S3Client` will upload it.
    static func partDigests(_ descriptor: Int32) throws -> (size: Int, parts: [SHA256.Digest]) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ShareError.copyFailed }
        let size = Int(info.st_size)
        return (size, try S3Client.partRanges(size: size).map { SHA256.hash(data: try readFully(descriptor, $0)) })
    }

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

}
