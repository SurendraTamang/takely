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
        #expect(FakeS3.state.withLock { $0.aborted } == ["up-1"])
    }

    @Test func sharingUploadsThePageLastAndKeepsTheLink() async throws {
        let client = client()
        let bundle = try ProjectBundle.create(in: FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID())"))
        try FileManager.default.createDirectory(at: bundle.exportsURL, withIntermediateDirectories: true)
        try Data("not really a movie".utf8).write(to: bundle.exportURL)
        try "WEBVTT\n".write(to: bundle.captionsURL, atomically: true, encoding: .utf8)
        let service = ShareService(client: client)
        let link = try await service.share(bundle)
        let record = try #require(bundle.readShareRecord())
        #expect(link == URL(string: "https://share.example.com/takely/\(record.id)/index.html"))
        #expect(record.id.count == 26)
        let objects = FakeS3.state.withLock { $0.objects }
        #expect(
            Set(objects.keys) == Set(["video.mp4", "captions.vtt", "oembed.json", "index.html"].map { "videos/takely/\(record.id)/\($0)" }))
        #expect(FakeS3.state.withLock { $0.contentTypes["videos/takely/\(record.id)/index.html"] } == "text/html; charset=utf-8")
        // Sharing again replaces the files under the same link; unsharing removes them.
        #expect(try await service.share(bundle) == link)
        try await service.unshare(bundle)
        #expect(FakeS3.state.withLock { $0.objects.isEmpty } && bundle.readShareRecord() == nil)
    }

    @Test func thePageUnfurlsAndEscapesWhatItShows() {
        let page = SharePage(
            title: "Fix <script>alert(1)</script> & ship", summary: "How \"we\" did it",
            chapters: [.init(t: 0, title: "Start"), .init(t: 75, title: "The fix")],
            duration: 125, width: 1920, height: 1080, hasCaptions: true, base: URL(string: "https://share.example.com/takely/abc")!)
        let html = page.html
        #expect(html.contains("<meta property=\"og:video\" content=\"https://share.example.com/takely/abc/video.mp4\">"))
        #expect(html.contains("<meta property=\"og:image\" content=\"https://share.example.com/takely/abc/poster.jpg\">"))
        #expect(html.contains("Fix &lt;script&gt;alert(1)&lt;/script&gt; &amp; ship") && !html.contains("<script>alert"))
        #expect(html.contains("data-t=\"75.0\">1:15</a> The fix") && html.contains("captions.vtt"))
        let oembed = try? JSONSerialization.jsonObject(with: page.oEmbed) as? [String: Any]
        #expect(oembed?["type"] as? String == "video" && oembed?["height"] as? Int == 720)
    }

    @Test func endpointsForEachProvider() {
        #expect(BucketConfig.endpoint(for: .r2, accountOrRegion: "abc123")?.absoluteString == "https://abc123.r2.cloudflarestorage.com")
        #expect(BucketConfig.endpoint(for: .b2, accountOrRegion: "us-west-004")?.absoluteString == "https://s3.us-west-004.backblazeb2.com")
    }
}
