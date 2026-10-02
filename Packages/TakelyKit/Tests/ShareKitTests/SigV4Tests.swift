import Foundation
import Testing

@testable import ShareKit

@Suite struct SigV4Tests {
    /// AWS's published example ("GET Object" with header authentication, S3 Signature V4 documentation).
    @Test func matchesAWSsGetObjectExample() throws {
        let signer = SigV4(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let date = try #require(ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z"))
        signer.sign(&request, payloadHash: SigV4.emptyPayloadHash, date: date)
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        )
    }

    @Test func encodesPathsAndQueriesTheS3Way() {
        #expect(SigV4.canonicalPath(URL(string: "https://h/b/takely/a%20b/video.mp4")!) == "/b/takely/a%20b/video.mp4")
        #expect(SigV4.canonicalQuery(URL(string: "https://h/k?uploadId=a/b&partNumber=2")!) == "partNumber=2&uploadId=a%2Fb")
        #expect(SigV4.canonicalQuery(URL(string: "https://h/k?uploads")!) == "uploads=")
    }
}
