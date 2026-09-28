import Testing

@testable import CaptureKit

@Suite struct CaptureErrorTests {
    @Test func noCameraDescriptionMentionsTheCamera() {
        #expect(CaptureError.noCamera.localizedDescription.contains("camera"))
    }
}
