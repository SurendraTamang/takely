import AVFoundation
import CryptoKit
import Foundation
import ProjectKit
import Synchronization
import TestSupport
import Testing

@testable import RenderKit
@testable import ShareKit

/// An in-memory S3: objects, multipart uploads, and injected failures.
final class FakeS3: URLProtocol, @unchecked Sendable {
    struct State {
        var objects: [String: Data] = [:]
        var contentTypes: [String: String] = [:]
        var uploads: [String: [Int: Data]] = [:]
        var aborted: [String] = []
        var failNextPartOnce = Set<Int>()
        var failCompletion = false
        var failNextPutOnce = false
        var puts = 0
        var unsigned = 0
    }
    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let key = String(url.path(percentEncoded: false).dropFirst())  // bucket/key
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let (status, reply, headers) = Self.state.withLock { s -> (Int, String, [String: String]) in
            if request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=") != true { s.unsigned += 1 }
            switch (request.httpMethod ?? "GET", query["uploads"] != nil, query["uploadId"]) {
            case ("POST", true, _):
                let id = "up-\(s.uploads.count + 1)"
                s.uploads[id] = [:]
                return (200, "<InitiateMultipartUploadResult><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>", [:])
            case ("PUT", _, let id?):
                let number = Int(query["partNumber"] ?? "0") ?? 0
                if s.failNextPartOnce.remove(number) != nil { return (500, "<Error><Code>InternalError</Code></Error>", [:]) }
                s.uploads[id]?[number] = body
                return (200, "", ["ETag": "\"etag-\(number)\""])
            case ("POST", _, let id?):
                if s.failCompletion { return (400, "<Error><Code>InvalidPart</Code><Message>bad part</Message></Error>", [:]) }
                let parts = s.uploads[id] ?? [:]
                s.objects[key] = parts.keys.sorted().reduce(into: Data()) { $0.append(parts[$1]!) }
                s.uploads[id] = nil
                return (200, "<CompleteMultipartUploadResult/>", [:])
            case ("DELETE", _, let id?):
                s.aborted.append(id)
                s.uploads[id] = nil
                return (204, "", [:])
            case ("PUT", _, nil):
                s.puts += 1
                if s.failNextPutOnce, s.puts == 2 {
                    s.failNextPutOnce = false
                    return (403, "<Error><Code>AccessDenied</Code></Error>", [:])
                }
                s.objects[key] = body
                s.contentTypes[key] = request.value(forHTTPHeaderField: "Content-Type")
                return (200, "", [:])
            case ("DELETE", _, nil):
                s.objects[key] = nil
                return (204, "", [:])
            default:
                return (400, "", [:])
            }
        }
        client?.urlProtocol(
            self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

@Suite(.serialized) struct ShareTests {
    let config = BucketConfig(
        provider: .r2, endpoint: URL(string: "https://acct.r2.cloudflarestorage.com")!, region: "auto", bucket: "videos",
        publicURL: URL(string: "https://share.example.com")!)

    func client() -> S3Client {
        FakeS3.state.withLock { $0 = .init() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeS3.self]
        return S3Client(config: config, accessKey: "AK", secretKey: "SK", session: URLSession(configuration: configuration))
    }

    func file(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID()).bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    @Test func largeFilesGoUpInPartsAndAFailedPartIsRetried() async throws {
        let client = client()
        let source = try file(bytes: 20 << 20)  // 3 parts of 8 MB
        FakeS3.state.withLock { $0.failNextPartOnce = [2] }
        let progress = Mutex<[Double]>([])
        try await client.upload(source, key: "takely/x/video.mp4", contentType: "video/mp4") { p in progress.withLock { $0.append(p) } }
        let stored = FakeS3.state.withLock { $0.objects["videos/takely/x/video.mp4"] }
        #expect(stored == (try Data(contentsOf: source)))
        #expect(progress.withLock { $0.last } == 1)
        #expect(FakeS3.state.withLock { $0.unsigned } == 0)  // every request signed
    }

    @Test func aFailedMultipartUploadIsAborted() async throws {
        let client = client()
        FakeS3.state.withLock { $0.failCompletion = true }
        await #expect(throws: S3Error.self) { try await client.upload(try file(bytes: 17 << 20), key: "k", contentType: "video/mp4") }
        // Aborted in the background.
        for _ in 0..<40 where FakeS3.state.withLock({ $0.aborted.isEmpty }) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(FakeS3.state.withLock { $0.aborted } == ["up-1"])
    }

    func exportedBundle() async throws -> ProjectBundle {
        let bundle = try ProjectBundle.create(in: FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID())"))
        try FileManager.default.createDirectory(at: bundle.exportsURL, withIntermediateDirectories: true)
        try await writeVideo(to: bundle.exportURL)
        try "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello\n".write(to: bundle.captionsURL, atomically: true, encoding: .utf8)
        return bundle
    }

    @Test func sharingKeepsTheLinkAndReplacesTheOldVersionsFiles() async throws {
        let client = client()
        let bundle = try await exportedBundle()
        let service = ShareService(client: client)
        let link = try await service.share(bundle)
        let first = try #require(bundle.readShareRecord())
        #expect(link == URL(string: "https://share.example.com/takely/\(first.id)/index.html") && first.complete && first.id.count == 26)
        let names = Set(FakeS3.state.withLock { $0.objects.keys }.map { $0.components(separatedBy: "/").last! })
        #expect(names.contains("index.html") && names.contains("oembed.json") && names.count == 5)  // + video-…, poster-…, captions-…
        #expect(FakeS3.state.withLock { $0.contentTypes["videos/takely/\(first.id)/index.html"] } == "text/html; charset=utf-8")
        // Re-sharing (after an edit): same link, new media names, the old ones deleted (a CDN can't serve them).
        #expect(try await service.share(bundle) == link)
        let second = try #require(bundle.readShareRecord())
        #expect(
            Set(second.keys).isDisjoint(
                with: Set(first.keys).subtracting(["takely/\(first.id)/index.html", "takely/\(first.id)/oembed.json"])))
        #expect(Set(FakeS3.state.withLock { $0.objects.keys }) == Set(second.keys.map { "videos/" + $0 }))
        // Without captions/summary: no captions file.
        _ = try await service.share(bundle, includeText: false)
        #expect(!(bundle.readShareRecord()!.keys.contains { $0.contains("captions") }))
        try await service.unshare(bundle)
        #expect(FakeS3.state.withLock { $0.objects.isEmpty } && bundle.readShareRecord() == nil)
    }

    @Test func aFailedFirstShareKeepsItsIDSoNothingIsOrphaned() async throws {
        let client = client()
        let bundle = try await exportedBundle()
        FakeS3.state.withLock { $0.failNextPutOnce = true }  // the video goes up, the next file fails…
        await #expect(throws: (any Error).self) { try await ShareService(client: client).share(bundle) }
        let failed = try #require(bundle.readShareRecord())
        #expect(!failed.complete)
        _ = try await ShareService(client: client).share(bundle)  // …the retry reuses the id and cleans up
        #expect(bundle.readShareRecord()?.id == failed.id)
        #expect(Set(FakeS3.state.withLock { $0.objects.keys }) == Set(bundle.readShareRecord()!.keys.map { "videos/" + $0 }))
    }

    /// What's uploaded is the sealed copy, not whatever the export holds by then.
    @Test func theSealedCopyIsWhatsUploaded() async throws {
        let bundle = try await exportedBundle()
        let snapshot = try await ShareSnapshot.make(of: bundle, inside: [bundle.url.deletingLastPathComponent()])
        try Data("changed".utf8).write(to: bundle.exportURL)
        let client = client()
        _ = try await ShareService(client: client).share(bundle, snapshot: snapshot)
        let video = FakeS3.state.withLock { $0.objects.first { $0.key.contains("/video-") }?.value }
        #expect(video == (try readFully(snapshot.descriptor, 0..<(snapshot.sealed?.size ?? 0))))
    }

    /// A process that opened the copy in the instant it had a name, writing after the person was asked: the changed
    /// part is caught before it's sent, and no page is published.
    @Test func aCopyChangedAfterItWasShownIsntPublished() async throws {
        let bundle = try await exportedBundle()
        let file = FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID()).mp4")
        try FileManager.default.copyItem(at: bundle.exportURL, to: file)
        let descriptor = open(file.path, O_RDWR)
        let snapshot = ShareSnapshot(
            descriptor: descriptor, sealed: try ShareSnapshot.partDigests(descriptor), poster: Data([0xFF, 0xD8]), duration: 1,
            dimensions: CGSize(width: 64, height: 64), chapters: [], title: nil, summary: nil, captions: nil)
        _ = Data("evil".utf8).withUnsafeBytes { pwrite(descriptor, $0.baseAddress, 4, 100) }
        await #expect(throws: ShareError.changedWhileReading) {
            try await ShareService(client: client()).share(bundle, snapshot: snapshot)
        }
        #expect(FakeS3.state.withLock { $0.objects.keys.filter { $0.hasSuffix("index.html") || $0.contains("/video-") } }.isEmpty)
    }

    /// The same in parts: the changed part stops the upload, which is aborted.
    @Test func aChangedPartStopsAMultipartUpload() async throws {
        let client = client()
        let file = try file(bytes: 17 << 20)
        let descriptor = open(file.path, O_RDWR)
        defer { close(descriptor) }
        let sealed = try ShareSnapshot.partDigests(descriptor)
        #expect(sealed.parts.count == 3)
        _ = Data("evil".utf8).withUnsafeBytes { pwrite(descriptor, $0.baseAddress, 4, off_t(16 << 20)) }
        await #expect(throws: ShareError.changedWhileReading) {
            try await client.upload(descriptor: descriptor, sealed: sealed, key: "k", contentType: "video/mp4")
        }
        for _ in 0..<40 where FakeS3.state.withLock({ $0.aborted.isEmpty }) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(FakeS3.state.withLock { $0.aborted.count } == 1 && FakeS3.state.withLock { $0.objects["videos/k"] } == nil)
    }

    /// The page's text is what the person was shown, even if project.json changes afterwards.
    @Test func thePageTextComesFromTheSnapshot() async throws {
        let bundle = try await exportedBundle()
        var project = Project(
            capture: .init(target: .display, pixelSize: PixelSize(width: 64, height: 64), fps: 10, codec: .h264),
            camera: .init(enabled: false))
        project.title = "Shown title"
        try bundle.write(project)
        let snapshot = try await ShareSnapshot.make(of: bundle, inside: [bundle.url.deletingLastPathComponent()])
        project.title = "Swapped title"
        try bundle.write(project)
        _ = try await ShareService(client: client()).share(bundle, snapshot: snapshot)
        let page = FakeS3.state.withLock { $0.objects.first { $0.key.hasSuffix("index.html") }?.value }.map {
            String(decoding: $0, as: UTF8.self)
        }
        #expect(page?.contains("Shown title") == true && page?.contains("Swapped") == false)
        let uploaded = FakeS3.state.withLock { $0.objects.first { $0.key.contains("/captions-") }?.value }
        #expect(uploaded != nil && uploaded == snapshot.captions?.vtt)
    }

    @Test func theFallbackCopyStopsAtTheSizeItStartedWith() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100).write(to: folder.appending(path: "a"))
        let source = open(folder.appending(path: "a").path, O_RDONLY)
        let destination = open(folder.appending(path: "b").path, O_RDWR | O_CREAT, 0o600)
        defer { close(source); close(destination) }
        try ShareSnapshot.copy(from: source, to: destination)
        #expect(try Data(contentsOf: folder.appending(path: "b")) == Data(repeating: 7, count: 100))
    }

    @Test func aFileCutShortWhileReadingThrows() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID())")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10).write(to: file)
        let descriptor = open(file.path, O_RDONLY)
        defer { close(descriptor) }
        #expect(try readFully(descriptor, 0..<10).count == 10)
        #expect(throws: ShareError.self) { try readFully(descriptor, 0..<20) }
        #expect(try readFully(descriptor, 5..<20, exact: false).count == 5)
    }

    /// An agent's share publishes a video with no text inside it: what's published as text is only the page's, shown
    /// to the person first.
    @Test func automatedSharesPublishAVideoWithoutText() async throws {
        let bundle = try await exportedBundle()
        try await writeVideo(to: bundle.exportURL, title: "Secret project name")
        #expect(try Data(contentsOf: bundle.exportURL).range(of: Data("Secret project name".utf8)) != nil)
        let snapshot = try await ShareSnapshot.make(of: bundle, inside: [bundle.url.deletingLastPathComponent()])
        _ = try await ShareService(client: client()).share(bundle, includeText: false, snapshot: snapshot)
        let video = try #require(FakeS3.state.withLock { $0.objects.first { $0.key.contains("/video-") }?.value })
        #expect(video.range(of: Data("Secret project name".utf8)) == nil)
        let file = FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID()).mp4")
        try video.write(to: file)
        let asset = AVURLAsset(url: file)
        #expect(try await asset.load(.tracks).map(\.mediaType) == [.video])
        #expect(try await asset.load(.commonMetadata).isEmpty)
    }

    /// A real Takely export (title, summary, AI-named chapters in French, a caption track, audio): an agent's share
    /// uploads only its video and audio, the index first; the page's chapters come from the export.
    @Test func aTakelyExportIsSharedWithoutItsText() async throws {
        let bundle = try await exportedBundle()
        let plain = bundle.exportsURL.appending(path: "plain.mp4")
        try await writeVideo(to: plain, frames: 20, audio: true)
        try FileManager.default.removeItem(at: bundle.exportURL)
        try await MovieFinisher.write(
            plain, to: bundle.exportURL,
            extras: MovieExtras(
                markers: [Marker(t: 1, title: "Démarrage secret")], captions: [CaptionCue(start: 0, end: 2, text: "secret transcript")],
                captionsLocale: "fr_FR", title: "Secret title", summary: "Secret summary"))
        try FileManager.default.removeItem(at: plain)
        let export = try Data(contentsOf: bundle.exportURL)
        #expect(["secret transcript", "Secret title", "Démarrage secret"].allSatisfy { export.range(of: Data($0.utf8)) != nil })

        let snapshot = try await ShareSnapshot.make(of: bundle, inside: [bundle.url.deletingLastPathComponent()])
        #expect(snapshot.chapters.map(\.title).contains("Démarrage secret") && snapshot.textFree)
        _ = try await ShareService(client: client()).share(bundle, includeText: false, snapshot: snapshot)
        let video = try #require(FakeS3.state.withLock { $0.objects.first { $0.key.contains("/video-") }?.value })
        for secret in ["secret transcript", "Secret title", "Secret summary", "Démarrage secret"] {
            #expect(video.range(of: Data(secret.utf8)) == nil, "\(secret)")
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID()).mp4")
        try video.write(to: file)
        #expect(Set(try await AVURLAsset(url: file).load(.tracks).map(\.mediaType)) == [.video, .audio])
        let moov = try #require(video.range(of: Data("moov".utf8)))
        let mdat = try #require(video.range(of: Data("mdat".utf8)))
        #expect(moov.lowerBound < mdat.lowerBound)  // fast start
    }

    /// Sharing from Takely with text off cleans the video first; progress covers that too, and never goes back.
    @Test func progressCoversCleaningTheVideo() async throws {
        let bundle = try await exportedBundle()
        let seen = Mutex<[Double]>([])
        _ = try await ShareService(client: client()).share(bundle, includeText: false) { value in seen.withLock { $0.append(value) } }
        let values = seen.withLock { $0 }
        #expect(values.last == 1 && values == values.sorted() && values.contains { $0 > 0 && $0 <= 0.1 })
    }

    @Test func aRecordingSharedToAnotherBucketIsLeftAlone() async throws {
        let bundle = try await exportedBundle()
        _ = try await ShareService(client: client()).share(bundle)
        var other = config
        other.bucket = "elsewhere"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeS3.self]
        let moved = ShareService(
            client: S3Client(config: other, accessKey: "AK", secretKey: "SK", session: URLSession(configuration: configuration)))
        await #expect(throws: ShareError.self) { try await moved.unshare(bundle) }
        #expect(bundle.readShareRecord() != nil)
    }

    @Test func uploadIDsTravelEncodedExactlyAsSigned() {
        let url = client().url("k", query: [URLQueryItem(name: "uploadId", value: "ab+c/d=e~f")])
        #expect(url.absoluteString.hasSuffix("?uploadId=ab%2Bc%2Fd%3De~f"))
    }

    @Test func thePageUnfurlsAndEscapesWhatItShows() {
        let page = SharePage(
            title: "Fix <script>alert(1)</script> & ship", summary: "How \"we\" did it",
            chapters: [.init(t: 0, title: "Start"), .init(t: 75, title: "The fix"), .init(t: .nan, title: "Broken")],
            duration: 125, width: 1920, height: 1080, base: URL(string: "https://share.example.com/takely/abc")!, video: "video-1.mp4",
            poster: "poster-1.jpg", captions: "captions-1.vtt")
        let html = page.html
        #expect(html.contains("<meta property=\"og:video\" content=\"https://share.example.com/takely/abc/video-1.mp4\">"))
        #expect(html.contains("<meta property=\"og:image\" content=\"https://share.example.com/takely/abc/poster-1.jpg\">"))
        #expect(html.contains("Fix &lt;script&gt;alert(1)&lt;/script&gt; &amp; ship") && !html.contains("<script>alert"))
        #expect(html.contains("data-t=\"75.0\">1:15</a> The fix") && html.contains("captions-1.vtt") && !html.contains("Broken"))
        let oembed = try? JSONSerialization.jsonObject(with: page.oEmbed) as? [String: Any]
        #expect(oembed?["type"] as? String == "video" && oembed?["height"] as? Int == 720)
    }

    @Test func endpointsForEachProvider() {
        #expect(BucketConfig.endpoint(for: .r2, accountOrRegion: "abc123")?.absoluteString == "https://abc123.r2.cloudflarestorage.com")
        #expect(BucketConfig.endpoint(for: .b2, accountOrRegion: "us-west-004")?.absoluteString == "https://s3.us-west-004.backblazeb2.com")
    }
}

/// A short real MP4 (a preview must be made from it).
func writeVideo(to url: URL, frames: Int = 10, title: String? = nil, audio: Bool = false) async throws {
    if let title {  // as Takely's exporter adds it: a passthrough export with metadata
        let plain = url.deletingLastPathComponent().appending(path: "\(UUID()).mp4")
        try await writeVideo(to: plain, frames: frames)
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        item.extendedLanguageTag = "und"
        let export = try #require(AVAssetExportSession(asset: AVURLAsset(url: plain), presetName: AVAssetExportPresetPassthrough))
        export.metadata = [item]
        try? FileManager.default.removeItem(at: url)
        try await export.export(to: url, as: .mp4)
        return
    }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    let sound = AVAssetWriterInput(
        mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
    if audio { writer.add(sound) }
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    if audio {
        for index in 0..<(frames * 4800 / 1024) {
            while !sound.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            sound.append(Synthetic.audio(pts: CMTime(value: CMTimeValue(index * 1024), timescale: 48_000)))
        }
        sound.markAsFinished()
    }
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

/// Automation shares a sealed copy: made without following links, then deleted while held open, so what the person
/// was shown is what's uploaded.
@Suite struct ShareSnapshotTests {
    func bundle(video: Bool = true) async throws -> ProjectBundle {
        let bundle = try ProjectBundle.create(in: FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID())"))
        try FileManager.default.createDirectory(at: bundle.exportsURL, withIntermediateDirectories: true)
        if video { try await writeVideo(to: bundle.exportURL) }
        return bundle
    }

    func make(_ bundle: ProjectBundle, inside folders: [URL]? = nil) async throws -> ShareSnapshot {
        try await ShareSnapshot.make(of: bundle, inside: folders ?? [bundle.url.deletingLastPathComponent()])
    }

    @Test func sealsTheExportWithItsPreviewAndText() async throws {
        let bundle = try await bundle()
        try Data("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello\n".utf8).write(to: bundle.captionsURL)
        var project = Project(
            capture: .init(target: .display, pixelSize: PixelSize(width: 64, height: 64), fps: 10, codec: .h264),
            camera: .init(enabled: false))
        project.title = "Fix login"
        try bundle.write(project)
        let snapshot = try await make(bundle)
        let sealed = try #require(snapshot.sealed)
        #expect(snapshot.poster?.starts(with: [0xFF, 0xD8]) == true && snapshot.duration > 0.5 && snapshot.dimensions.width == 64)
        #expect(snapshot.captions?.cues.map(\.text) == ["Hello"] && snapshot.title == "Fix login")
        // Deleted while held open: nothing can reach it by path; changing the export changes nothing.
        var info = stat()
        #expect(fstat(snapshot.descriptor, &info) == 0 && info.st_nlink == 0)
        try Data("changed".utf8).write(to: bundle.exportURL)
        #expect(try ShareSnapshot.partDigests(snapshot.descriptor).parts == sealed.parts)
    }

    @Test func refusesALinkedExportOrExportsFolder() async throws {
        let secret = FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID())-secret")
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try await writeVideo(to: secret.appending(path: "x.mp4"))

        let linkedFile = try await bundle(video: false)
        try FileManager.default.createSymbolicLink(at: linkedFile.exportURL, withDestinationURL: secret.appending(path: "x.mp4"))
        await #expect(throws: ShareError.self) { try await make(linkedFile) }

        let linkedFolder = try await bundle(video: false)
        try FileManager.default.removeItem(at: linkedFolder.exportsURL)
        try FileManager.default.copyItem(at: secret.appending(path: "x.mp4"), to: secret.appending(path: "\(linkedFolder.name).mp4"))
        try FileManager.default.createSymbolicLink(at: linkedFolder.exportsURL, withDestinationURL: secret)
        await #expect(throws: ShareError.self) { try await make(linkedFolder) }
    }

    /// Captions linked elsewhere (symbolic or hard link) or not WebVTT: left out.
    @Test func captionsThatArentTheRecordingsAreLeftOut() async throws {
        let secret = FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID()).txt")
        try Data("WEBVTT\naws_secret_access_key = x".utf8).write(to: secret)
        let symbolic = try await bundle()
        try FileManager.default.createSymbolicLink(at: symbolic.captionsURL, withDestinationURL: secret)
        #expect(try await make(symbolic).captions == nil)
        let hard = try await bundle()
        try FileManager.default.linkItem(at: secret, to: hard.captionsURL)
        #expect(try await make(hard).captions == nil)
        let notVTT = try await bundle()
        try Data("aws_secret_access_key = x".utf8).write(to: notVTT.captionsURL)
        #expect(try await make(notVTT).captions == nil)
    }

    /// A hard link has no symbolic link in its path, but it's another file's bytes: refused (automation only).
    @Test func refusesAHardLinkedExportUnlessThePersonShares() async throws {
        let bundle = try await bundle(video: false)
        let other = FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID()).mp4")
        try await writeVideo(to: other)
        try FileManager.default.linkItem(at: other, to: bundle.exportURL)
        await #expect(throws: ShareError.self) { try await make(bundle) }
        _ = try await ShareSnapshot.make(of: bundle, inside: [bundle.url.deletingLastPathComponent()], strict: false)
    }

    /// A recording reached through a link to a folder Takely doesn't save in: refused, whatever the path says.
    @Test func refusesABundleOutsideTheSaveFolders() async throws {
        let real = try await bundle()
        let saveFolder = FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let linked = ProjectBundle(url: saveFolder.appending(path: real.url.lastPathComponent))
        try FileManager.default.createSymbolicLink(at: linked.url, withDestinationURL: real.url)
        await #expect(throws: ShareError.self) { try await make(linked, inside: [saveFolder]) }
    }

    /// The preview is read only through bytes that match the seal, in parts: after a change, the poster is either
    /// made from bytes AVFoundation already had (checked when served) or the read fails and the change is reported.
    @Test func thePreviewIsMadeOnlyFromSealedBytes() async throws {
        let bundle = try await bundle()
        let descriptor = open(bundle.exportURL.path, O_RDWR)
        defer { close(descriptor) }
        let small: (Int) -> [Range<Int>] = { S3Client.partRanges(size: $0, partSize: 128, threshold: 0) }
        let sealed = try ShareSnapshot.partDigests(descriptor, ranges: small)
        #expect(sealed.parts.count > 4)

        let intact = SealedLoader(descriptor: descriptor, sealed: sealed, ranges: small)
        let good = intact.asset()
        #expect(try await good.loadTracks(withMediaType: .video).count == 1)
        let original = await ShareService.poster(good)
        #expect(original != nil && !intact.changed)

        let loader = SealedLoader(descriptor: descriptor, sealed: sealed, ranges: small)
        let asset = loader.asset()
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        // The sample data, in the middle of the file (the movie's index is at its end).
        _ = Data(repeating: 0xEE, count: 64).withUnsafeBytes { pwrite(descriptor, $0.baseAddress, 64, off_t(sealed.size / 3)) }
        let poster = await ShareService.poster(asset)
        #expect(poster == original || (poster == nil && loader.changed))
        // Read afresh, the change is caught.
        let fresh = SealedLoader(descriptor: descriptor, sealed: sealed, ranges: small)
        let freshAsset = fresh.asset()
        if (try? await freshAsset.loadTracks(withMediaType: .video)) != nil { _ = await ShareService.poster(freshAsset) }
        #expect(fresh.changed)
    }

    /// Opt-in: TAKELY_REAL_SHARE_FILE=<an exported MP4> — a real recording, big enough for the 4 MB cap and parts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TAKELY_REAL_SHARE_FILE"] != nil))
    func aRealRecordingPreviewsThroughTheSeal() async throws {
        let descriptor = open(ProcessInfo.processInfo.environment["TAKELY_REAL_SHARE_FILE"]!, O_RDONLY)
        defer { close(descriptor) }
        let sealed = try ShareSnapshot.partDigests(descriptor)
        let loader = SealedLoader(descriptor: descriptor, sealed: sealed)
        let asset = loader.asset()
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(await ShareService.poster(asset) != nil && !loader.changed)
    }

    @Test func aFileThatIsntAVideoIsRefused() async throws {
        let bundle = try await bundle(video: false)
        try Data("not a movie".utf8).write(to: bundle.exportURL)
        await #expect(throws: ShareError.self) { try await make(bundle) }
    }

    /// What the person reads before sharing: all of it, only what's there, nothing that can reorder or fake lines.
    @Test func thePublishedTextIsShownInFull() throws {
        let captions = try #require(
            Captions(
                Data(
                    "WEBVTT\n\nNOTE made by Takely\n\n1\n00:00.000 --> 00:02.000\nHello there\n\n00:02.000 --> 00:04.000\nsecond\nline\n"
                        .utf8)))
        let long = String(repeating: "word ", count: 200)
        let snapshot = ShareSnapshot(
            descriptor: -1, sealed: nil, poster: nil, duration: 4, dimensions: .zero,
            chapters: [.init(t: 0, title: "Intro"), .init(t: 3700, title: "Demo")], title: "Fix \u{202E}lo\u{200B}gin\u{0007}",
            summary: long, captions: captions)
        let shown = snapshot.publishedText(includeText: true)
        #expect(shown.map(\.heading) == ["Title", "Summary", "Chapters", "Captions"])
        #expect(shown[0].text == "Fix  lo gin ")
        #expect(shown[1].text == long)
        #expect(shown[2].text == "\(SharePage.time(0))  Intro\n\(SharePage.time(3700))  Demo")
        #expect(shown[3].text == "Hello there\nsecond\nline")
        // Text off: nothing but the (text-free) video is published.
        #expect(snapshot.publishedText(includeText: false).isEmpty)
    }

    /// Captions are published as rebuilt from their cues, so nothing else in the file goes public unseen.
    @Test func captionsArePublishedAsShown() throws {
        // Takely's own captions come back byte for byte.
        let own = Data("WEBVTT\n\n00:00:00.000 --> 00:00:05.036\nHi everyone\ntwo lines\n\n00:00:05.036 --> 00:00:07.000\nBye\n".utf8)
        #expect(Captions(own)?.vtt == own)
        // Old Mac line endings, a header, notes, styles, cue settings, cue IDs: only cues remain.
        let odd = Data(
            "WEBVTT hidden header\r\rNOTE hidden note\r\rSTYLE\r::cue { color: red }\r\rid-1\r00:01.000 --> 00:02.000 line:0 align:start\rShown\r"
                .utf8)
        let parsed = try #require(Captions(odd))
        #expect(parsed.cues == [.init(start: "00:01.000", end: "00:02.000", text: "Shown")])
        #expect(String(decoding: parsed.vtt, as: UTF8.self) == "WEBVTT\n\n00:01.000 --> 00:02.000\nShown\n")
        #expect(Captions(Data("WEBVTT\n\nNOTE only a note\n".utf8)) == nil)
        // A byte-order mark (some editors add one) is fine.
        #expect(Captions(Data([0xEF, 0xBB, 0xBF]) + Data("WEBVTT\n\n00:01.000 --> 00:02.000\nHi\n".utf8))?.cues.count == 1)
        #expect(Captions(Data("WEBVTT\n\nnot a time --> 00:01.000\nx\n".utf8)) == nil)
        #expect(Captions(Data(("WEBVTT\n\n" + String(repeating: "x", count: 1 << 20)).utf8)) == nil)
    }
}
