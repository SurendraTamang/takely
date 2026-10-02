import Foundation
import ProjectKit
import Testing

@testable import ShareKit

/// Against a real S3-compatible server, when `TAKELY_S3_ENDPOINT` (with `TAKELY_S3_KEY`, `TAKELY_S3_SECRET`) is set,
/// e.g. a local Versity gateway: `docker run -p 7070:7070 -e ROOT_ACCESS_KEY=… -e ROOT_SECRET_KEY=… versity/versitygw --port :7070 posix /tmp`.
@Suite struct LiveS3Tests {
    static let environment = ProcessInfo.processInfo.environment
    static let endpoint = environment["TAKELY_S3_ENDPOINT"].flatMap(URL.init(string:))

    func client(secret: String? = nil) -> S3Client {
        let config = BucketConfig(
            provider: .other, endpoint: Self.endpoint!, region: "us-east-1", bucket: "takely-live-\(Int.random(in: 1000...9999))",
            publicURL: URL(string: "https://share.example.com")!)
        return S3Client(
            config: config, accessKey: Self.environment["TAKELY_S3_KEY"] ?? "",
            secretKey: secret ?? Self.environment["TAKELY_S3_SECRET"] ?? "")
    }

    @Test(.enabled(if: endpoint != nil)) func uploadsInPartsAndReadsBackTheSameBytes() async throws {
        let client = client()
        try await client.send("PUT", client.config.endpoint.appending(path: client.config.bucket))  // create the bucket
        let source = FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID()).bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<(20 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: source)
        try await client.upload(source, key: "takely/live/video.mp4", contentType: "video/mp4")
        let (data, _) = try await client.send("GET", client.url("takely/live/video.mp4"))
        #expect(data == (try Data(contentsOf: source)))
        try await client.put("takely/live/index.html", data: Data("<p>hi</p>".utf8), contentType: "text/html; charset=utf-8")
        try await client.delete("takely/live/index.html")
        try await client.delete("takely/live/video.mp4")
    }

    @Test(.enabled(if: endpoint != nil)) func aWrongSecretIsRefused() async throws {
        await #expect(throws: S3Error.self) {
            try await client(secret: "wrong").send("PUT", Self.endpoint!.appending(path: "takely-refused"))
        }
    }
}
