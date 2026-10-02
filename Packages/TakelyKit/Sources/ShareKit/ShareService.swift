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
    public func share(
        _ bundle: ProjectBundle, includeText: Bool = true, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: bundle.exportURL.path) else { throw ShareError.notExported }
        let previous = bundle.readShareRecord()
        if let previous, !isTarget(previous) { throw ShareError.otherBucket(previous.bucket) }
        let id = previous?.id ?? Self.newID()
        let prefix = "\(Self.folder)/\(id)"
        let base = client.config.publicURL.appending(path: Self.folder).appending(path: id)
        let version = String(Self.newID().prefix(8))
        let video = "video-\(version).mp4"
        let poster = "poster-\(version).jpg"
        let captions = "captions-\(version).vtt"
        var record = ShareRecord(
            id: id, url: base.appending(path: "index.html"), sharedAt: .now, endpoint: client.config.endpoint,
            bucket: client.config.bucket, keys: (previous?.keys ?? []) + [video, poster, captions].map { "\(prefix)/\($0)" },
            complete: false)
        try bundle.write(record)

        // A snapshot (an APFS clone: instant, no extra space): a re-export meanwhile can't mix two versions.
        let snapshot = FileManager.default.temporaryDirectory.appending(path: "takely-share-\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: bundle.exportURL, to: snapshot)
        defer { try? FileManager.default.removeItem(at: snapshot) }
        let asset = AVURLAsset(url: snapshot)
        let project = try? bundle.readProject()

        var uploaded = ["index.html", "oembed.json", video]
        try await client.upload(snapshot, key: "\(prefix)/\(video)", contentType: "video/mp4", cacheControl: Self.mediaCache) {
            progress($0 * 0.9)
        }
        var posterName: String?
        if let data = await Self.poster(asset) {
            try await client.put("\(prefix)/\(poster)", data: data, contentType: "image/jpeg", cacheControl: Self.mediaCache)
            posterName = poster
            uploaded.append(poster)
        }
        var captionsName: String?
        if includeText, FileManager.default.fileExists(atPath: bundle.captionsURL.path) {
            try await client.put(
                "\(prefix)/\(captions)", data: try Data(contentsOf: bundle.captionsURL), contentType: "text/vtt; charset=utf-8",
                cacheControl: Self.mediaCache)
            captionsName = captions
            uploaded.append(captions)
        }
        let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        let page = SharePage(
            title: includeText ? project?.title ?? "Recording" : "Recording", summary: includeText ? project?.summary : nil,
            chapters: includeText ? await Self.chapters(asset) : [], duration: duration, width: Int(size.width), height: Int(size.height),
            base: base, video: video, poster: posterName, captions: captionsName)
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

    static func poster(_ asset: AVURLAsset) async -> Data? {
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

    public var errorDescription: String? {
        switch self {
        case .notExported: "This recording hasn't been exported yet."
        case .notConfigured: "Set up sharing first: Settings › Share."
        case .otherBucket(let bucket):
            "This recording was shared to another bucket (\(bucket)). Switch back to it in Settings › Share to change or remove it."
        }
    }
}
