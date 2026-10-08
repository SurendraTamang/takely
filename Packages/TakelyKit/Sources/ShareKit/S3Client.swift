import Foundation
import Synchronization

/// Where uploads go: an S3-compatible bucket and the public address its objects are served from.
public struct BucketConfig: Codable, Sendable, Equatable {
    public enum Provider: String, Codable, Sendable, CaseIterable {
        case r2, s3, b2, other

        public var name: String {
            switch self {
            case .r2: "Cloudflare R2"
            case .s3: "Amazon S3"
            case .b2: "Backblaze B2"
            case .other: "Other (S3-compatible)"
            }
        }
    }

    public var provider: Provider
    /// The S3 API endpoint, e.g. https://<account>.r2.cloudflarestorage.com.
    public var endpoint: URL
    public var region: String
    public var bucket: String
    /// Where the uploaded files are publicly readable, e.g. https://share.example.com (R2 custom domain).
    public var publicURL: URL

    public init(provider: Provider, endpoint: URL, region: String, bucket: String, publicURL: URL) {
        self.provider = provider
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.publicURL = publicURL
    }

    /// The endpoint for a provider from its usual inputs (R2: account ID; S3/B2: region).
    public static func endpoint(for provider: Provider, accountOrRegion: String) -> URL? {
        let value = accountOrRegion.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        switch provider {
        case .r2: return URL(string: "https://\(value).r2.cloudflarestorage.com")
        case .s3: return URL(string: "https://s3.\(value).amazonaws.com")
        case .b2: return URL(string: "https://s3.\(value).backblazeb2.com")
        case .other:
            guard let url = URL(string: value), ["https", "http"].contains(url.scheme ?? ""), url.host() != nil else { return nil }
            return url
        }
    }
}

public struct S3Error: Error, LocalizedError, Equatable {
    public let status: Int
    public let code: String
    public let message: String

    public var errorDescription: String? {
        switch code {
        case "InvalidAccessKeyId", "SignatureDoesNotMatch": "The access key or secret is wrong (\(code))."
        case "NoSuchBucket": "There's no bucket with that name at this endpoint."
        case "AccessDenied": "The key isn't allowed to write to this bucket."
        default: message.isEmpty ? "The storage service answered \(status) \(code)." : "\(message) (\(code))"
        }
    }
}

/// The few S3 calls sharing needs, over URLSession with Signature V4. Objects are addressed path-style
/// (`endpoint/bucket/key`), which R2, B2, MinIO and S3 all accept.
public struct S3Client: Sendable {
    public let config: BucketConfig
    let signer: SigV4
    let session: URLSession
    /// Files above this go up in parts.
    static let multipartThreshold = 16 << 20
    /// S3's minimum part size is 5 MB; 8 MB keeps the part count low and retries cheap.
    static let partSize = 8 << 20
    static let parallelParts = 4
    static let attempts = 3

    public init(config: BucketConfig, accessKey: String, secretKey: String, session: URLSession = .shared) {
        self.config = config
        signer = SigV4(accessKey: accessKey, secretKey: secretKey, region: config.region)
        self.session = session
    }

    func url(_ key: String, query: [URLQueryItem] = []) -> URL {
        let url = config.endpoint.appending(path: config.bucket).appending(path: key)
        guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        // Encoded exactly as signed: a `+` in an upload ID must travel as %2B, not be read as a space.
        components.percentEncodedQuery = query.map { "\(SigV4.encode($0.name))=\(SigV4.encode($0.value ?? ""))" }.joined(separator: "&")
        return components.url ?? url
    }

    @discardableResult
    func send(_ method: String, _ url: URL, body: Data = Data(), headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        signer.sign(&request, payloadHash: SigV4.sha256Hex(body))
        let (data, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(data, status: http.statusCode) }
        return (data, http)
    }

    public func put(_ key: String, data: Data, contentType: String, cacheControl: String? = nil) async throws {
        var headers = ["Content-Type": contentType]
        if let cacheControl { headers["Cache-Control"] = cacheControl }
        let fixed = headers
        _ = try await retrying { try await send("PUT", url(key), body: data, headers: fixed) }
    }

    public func delete(_ key: String) async throws {
        do {
            try await send("DELETE", url(key))
        } catch let error as S3Error where error.status == 404 {
            return  // already gone
        }
    }

    /// Uploads a file, in parts when it's large; `progress` gets the fraction sent. A failed or cancelled upload
    /// is aborted, so no unfinished parts stay billed in the bucket.
    public func upload(
        _ file: URL, key: String, contentType: String, cacheControl: String? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        // One open file for every part: if the file is replaced meanwhile, all parts still come from one version.
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(descriptor) }
        try await upload(descriptor: descriptor, key: key, contentType: contentType, cacheControl: cacheControl, progress: progress)
    }

    /// Uploads what an open file holds (read with pread, so the descriptor's offset doesn't matter). The caller
    /// keeps it open until this returns.
    public func upload(
        descriptor: Int32, key: String, contentType: String, cacheControl: String? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let size = Int(info.st_size)
        let reader = PartReader(descriptor)
        guard size > Self.multipartThreshold else {
            try await put(key, data: try reader.read(offset: 0, length: size), contentType: contentType, cacheControl: cacheControl)
            return progress(1)
        }
        var initial = ["Content-Type": contentType]
        if let cacheControl { initial["Cache-Control"] = cacheControl }
        let headers = initial
        let (created, _) = try await retrying {
            try await send("POST", url(key, query: [URLQueryItem(name: "uploads", value: nil)]), headers: headers)
        }
        guard let uploadID = Self.tag("UploadId", in: created) else { throw URLError(.cannotParseResponse) }
        // S3 allows at most 10,000 parts: very large files get bigger parts.
        let partSize = max(Self.partSize, (size + 9_999) / 10_000)
        let parts = (size + partSize - 1) / partSize
        let sent = SentCounter(total: size, progress: progress)
        do {
            var etags = [String](repeating: "", count: parts)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var next = 0
                func add() {
                    let number = next + 1
                    next += 1
                    group.addTask {
                        let data = try reader.read(offset: (number - 1) * partSize, length: partSize)
                        let query = [
                            URLQueryItem(name: "partNumber", value: String(number)), URLQueryItem(name: "uploadId", value: uploadID),
                        ]
                        let (_, response) = try await retrying { try await send("PUT", url(key, query: query), body: data) }
                        sent.add(data.count)
                        return (number, response.value(forHTTPHeaderField: "ETag") ?? "")
                    }
                }
                for _ in 0..<min(Self.parallelParts, parts) { add() }
                while let (number, etag) = try await group.next() {
                    etags[number - 1] = etag
                    if next < parts { add() }
                }
            }
            let body =
                "<CompleteMultipartUpload>"
                + etags.enumerated().map { "<Part><PartNumber>\($0.offset + 1)</PartNumber><ETag>\($0.element)</ETag></Part>" }.joined()
                + "</CompleteMultipartUpload>"
            let completion = url(key, query: [URLQueryItem(name: "uploadId", value: uploadID)])
            let attempt = Mutex(0)
            let completed: Data
            do {
                (completed, _) = try await retrying {
                    attempt.withLock { $0 += 1 }
                    return try await send("POST", completion, body: Data(body.utf8))
                }
            } catch let error as S3Error where error.code == "NoSuchUpload" && attempt.withLock({ $0 }) > 1 {
                return progress(1)  // an earlier attempt completed it; only its answer was lost
            }
            // S3 can report a failed completion inside a 200 response.
            if let code = Self.tag("Code", in: completed) {
                throw S3Error(status: 200, code: code, message: Self.tag("Message", in: completed) ?? "")
            }
        } catch {
            // Detached, so it still runs when the upload was cancelled: unfinished parts would stay billed.
            let abort = url(key, query: [URLQueryItem(name: "uploadId", value: uploadID)])
            Task.detached { [self] in _ = try? await send("DELETE", abort) }
            throw error
        }
        progress(1)
    }

    /// Retries network failures and 5xx/429 answers with backoff (1 s, 2 s); other errors at once.
    func retrying<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await work()
            } catch let error as S3Error where (error.status >= 500 || error.status == 429) && attempt < Self.attempts {
            } catch let error as URLError where error.code != .cancelled && attempt < Self.attempts {
            }
            try await Task.sleep(for: .seconds(1 << (attempt - 1)))
            attempt += 1
        }
    }

    static func error(_ data: Data, status: Int) -> S3Error {
        S3Error(status: status, code: tag("Code", in: data) ?? "HTTP\(status)", message: tag("Message", in: data) ?? "")
    }

    /// The text of the first `<name>` element (S3's XML answers are small and flat).
    static func tag(_ name: String, in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }
}

/// Bytes sent so far, from parallel parts.
private final class SentCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    let total: Int
    let progress: @Sendable (Double) -> Void

    init(total: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.progress = progress
    }

    func add(_ bytes: Int) {
        let fraction = lock.withLock {
            sent += bytes
            return Double(sent) / Double(max(total, 1))
        }
        progress(min(1, fraction))
    }
}

/// Reads parts of one open file (positioned reads, safe from several tasks at once).
private final class PartReader: Sendable {
    let descriptor: Int32

    /// Not owned: whoever opened it closes it.
    init(_ descriptor: Int32) { self.descriptor = descriptor }

    func read(offset: Int, length: Int) throws -> Data {
        var data = Data(count: length)
        let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, length, off_t(offset)) }
        guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
        return data.prefix(count)
    }
}
