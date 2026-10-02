import Foundation
import ProjectKit
import Synchronization
import Testing

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

    func exportedBundle() throws -> ProjectBundle {
        let bundle = try ProjectBundle.create(in: FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID())"))
        try FileManager.default.createDirectory(at: bundle.exportsURL, withIntermediateDirectories: true)
        try Data("not really a movie".utf8).write(to: bundle.exportURL)
        try "WEBVTT\n".write(to: bundle.captionsURL, atomically: true, encoding: .utf8)
        return bundle
    }

    @Test func sharingKeepsTheLinkAndReplacesTheOldVersionsFiles() async throws {
        let client = client()
        let bundle = try exportedBundle()
        let service = ShareService(client: client)
        let link = try await service.share(bundle)
        let first = try #require(bundle.readShareRecord())
        #expect(link == URL(string: "https://share.example.com/takely/\(first.id)/index.html") && first.complete && first.id.count == 26)
        let names = Set(FakeS3.state.withLock { $0.objects.keys }.map { $0.components(separatedBy: "/").last! })
        #expect(names.contains("index.html") && names.contains("oembed.json") && names.count == 4)  // + video-…, captions-…
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
        let bundle = try exportedBundle()
        FakeS3.state.withLock { $0.failNextPutOnce = true }  // the video goes up, the next file fails…
        await #expect(throws: (any Error).self) { try await ShareService(client: client).share(bundle) }
        let failed = try #require(bundle.readShareRecord())
        #expect(!failed.complete)
        _ = try await ShareService(client: client).share(bundle)  // …the retry reuses the id and cleans up
        #expect(bundle.readShareRecord()?.id == failed.id)
        #expect(Set(FakeS3.state.withLock { $0.objects.keys }) == Set(bundle.readShareRecord()!.keys.map { "videos/" + $0 }))
    }

    @Test func aRecordingSharedToAnotherBucketIsLeftAlone() async throws {
        let bundle = try exportedBundle()
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
