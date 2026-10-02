@preconcurrency import AVFoundation
import Foundation
import ImageIO
import ProjectKit
import UniformTypeIdentifiers

/// A recording's shared copy (`share.json`): where it is, so it can be copied, re-uploaded (same link) or deleted.
public struct ShareRecord: Codable, Sendable, Equatable {
    public var id: String
    public var url: URL
    public var sharedAt: Date
}

extension ProjectBundle {
    public var shareRecordURL: URL { url.appending(path: "share.json") }

    public func readShareRecord() -> ShareRecord? {
        (try? Data(contentsOf: shareRecordURL)).flatMap { try? JSONDecoder().decode(ShareRecord.self, from: $0) }
    }
}

/// Uploads a finished recording (its export) with a player page to the user's bucket, and removes it again.
public struct ShareService: Sendable {
    let client: S3Client
    static let folder = "takely"
    static let files = ["index.html", "video.mp4", "poster.jpg", "captions.vtt", "oembed.json"]

    public init(client: S3Client) {
        self.client = client
    }

    /// Uploads the recording; returns its link. A recording shared before keeps its link (the files are replaced).
    public func share(_ bundle: ProjectBundle, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let export = bundle.exportURL
        guard FileManager.default.fileExists(atPath: export.path) else { throw ShareError.notExported }
        let id = bundle.readShareRecord()?.id ?? Self.newID()
        let prefix = "\(Self.folder)/\(id)"
        let base = client.config.publicURL.appending(path: Self.folder).appending(path: id)
        let asset = AVURLAsset(url: export)
        let project = try? bundle.readProject()

        try await client.upload(export, key: "\(prefix)/video.mp4", contentType: "video/mp4") { progress($0 * 0.9) }
        if let poster = await Self.poster(asset) {
            try await client.put("\(prefix)/poster.jpg", data: poster, contentType: "image/jpeg")
        }
        let hasCaptions = FileManager.default.fileExists(atPath: bundle.captionsURL.path)
        if hasCaptions {
            try await client.put(
                "\(prefix)/captions.vtt", data: try Data(contentsOf: bundle.captionsURL), contentType: "text/vtt; charset=utf-8")
        }
        let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let page = SharePage(
            title: project?.title ?? bundle.name, summary: project?.summary, chapters: await Self.chapters(asset),
            duration: (try? await asset.load(.duration).seconds) ?? 0, width: Int(size.width), height: Int(size.height),
            hasCaptions: hasCaptions, base: base)
        try await client.put("\(prefix)/oembed.json", data: page.oEmbed, contentType: "application/json+oembed")
        // The page last: the link works only once everything it shows is there.
        try await client.put(
            "\(prefix)/index.html", data: Data(page.html.utf8), contentType: "text/html; charset=utf-8", cacheControl: "no-cache")
        let link = page.pageURL
        try JSONEncoder().encode(ShareRecord(id: id, url: link, sharedAt: .now)).write(to: bundle.shareRecordURL, options: .atomic)
        progress(1)
        return link
    }

    /// Deletes the shared copy (the link stops working) and forgets it.
    public func unshare(_ bundle: ProjectBundle) async throws {
        guard let record = bundle.readShareRecord() else { return }
        for file in Self.files { try await client.delete("\(Self.folder)/\(record.id)/\(file)") }
        try? FileManager.default.removeItem(at: bundle.shareRecordURL)
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
        for group in groups {
            let title = (try? await group.items.first?.load(.stringValue)) ?? nil
            chapters.append(SharePage.Chapter(t: group.timeRange.start.seconds, title: title ?? ""))
        }
        return chapters.count > 1 ? chapters : []
    }
}

public enum ShareError: Error, LocalizedError {
    case notExported
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .notExported: "This recording hasn't been exported yet."
        case .notConfigured: "Set up sharing first: Settings › Share."
        }
    }
}
