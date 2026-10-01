import Foundation
import Testing

@testable import ProjectKit

@Suite struct RedactionTests {
    let redaction = Redaction(
        kind: .apiKey, preview: "sk-…f3a9",
        track: [
            .init(t: 10, rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)),
            .init(t: 12, rect: NormalizedRect(x: 0.1, y: 0.4, width: 0.3, height: 0.05)),
        ])

    @Test func coversItsTrackWithHalfASecondEitherSide() {
        #expect(redaction.rect(at: 9.4) == nil)
        #expect(redaction.rect(at: 9.6) == NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05))
        #expect(redaction.rect(at: 12.4) == NormalizedRect(x: 0.1, y: 0.4, width: 0.3, height: 0.05))
        #expect(redaction.rect(at: 12.6) == nil)
    }

    @Test func followsMovingTextBetweenKeyframes() throws {
        let mid = try #require(redaction.rect(at: 11))
        #expect(abs(mid.y - 0.3) < 1e-9)
    }

    @Test func disabledRedactionsCoverNothing() {
        var off = redaction
        off.enabled = false
        #expect(off.rect(at: 11) == nil)
    }

    @Test func roundTripsThroughTheBundle() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try ProjectBundle.create(in: folder)
        #expect(try bundle.readRedactions().isEmpty)
        try bundle.write([redaction])
        #expect(try bundle.readRedactions() == [redaction])
    }
}
