import CryptoKit
import Foundation

/// AWS Signature Version 4 for S3 requests (what S3, Cloudflare R2, Backblaze B2 and MinIO all accept): the request's
/// method, path, query, chosen headers and payload hash are signed with a key derived from the secret, the date,
/// the region and the service, so the secret itself never travels.
public struct SigV4: Sendable {
    public let accessKey: String
    let secretKey: String
    public let region: String
    let service = "s3"

    public init(accessKey: String, secretKey: String, region: String) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
    }

    public static let emptyPayloadHash = sha256Hex(Data())

    /// Adds `x-amz-date`, `x-amz-content-sha256` and `Authorization` to `request`. `payloadHash` is the hex SHA-256
    /// of the body.
    public func sign(_ request: inout URLRequest, payloadHash: String, date: Date = .now) {
        guard let url = request.url, let host = url.host() else { return }
        let amzDate = Self.amzFormat(date)
        let day = String(amzDate.prefix(8))
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        var headers: [String: String] = ["host": url.port.map { "\(host):\($0)" } ?? host]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if lower.hasPrefix("x-amz-") || lower == "content-type" || lower == "range" || lower == "content-md5" {
                headers[lower] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        let names = headers.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonical = [
            request.httpMethod ?? "GET",
            Self.canonicalPath(url),
            Self.canonicalQuery(url),
            names.map { "\($0):\(headers[$0]!)\n" }.joined(),
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.sha256Hex(Data(canonical.utf8))].joined(separator: "\n")
        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key).map { String(format: "%02x", $0) }
            .joined()
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func amzFormat(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// RFC 3986 unreserved characters stay; everything else is %-encoded (S3 encodes each path segment once).
    static func encode(_ s: String, keepSlash: Bool = false) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if keepSlash { allowed.insert("/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func canonicalPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return encode(path.isEmpty ? "/" : path, keepSlash: true)
    }

    static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pairs: [(name: String, value: String)] = items.map { item in (encode(item.name), encode(item.value ?? "")) }
        let sorted = pairs.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { pair in pair.name + "=" + pair.value }.joined(separator: "&")
    }
}
