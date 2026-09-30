import Foundation
import Testing
import WebRTCAEC

@Suite struct WebRTCAECTests {
    /// Deterministic noise-like far-end signal in [-0.5, 0.5].
    static func farEnd(count: Int) -> [Float] {
        var state: UInt32 = 12345
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24) - 0.5
        }
    }

    static func power(_ x: ArraySlice<Float>) -> Double {
        x.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))
    }

    @Test func rejectsUnsupportedSampleRates() {
        #expect(webrtc_aec_create(44100) == nil)
    }

    @Test func removesADelayedEchoOfTheFarEnd() throws {
        let rate = 48000, frame = 480, delay = 1440  // 30 ms
        let far = Self.farEnd(count: rate * 8)
        // Mic hears the far end 30 ms late at half amplitude (−6 dB).
        let mic = (0..<far.count).map { $0 >= delay ? far[$0 - delay] * 0.5 : 0 }
        let aec = try #require(webrtc_aec_create(Int32(rate)))
        defer { webrtc_aec_destroy(aec) }
        var out = [Float](repeating: 0, count: mic.count)
        for start in stride(from: 0, to: far.count, by: frame) {
            var near = Array(mic[start..<start + frame])
            far[start..<start + frame].withContiguousStorageIfAvailable { #expect(webrtc_aec_analyze_render(aec, $0.baseAddress) == 0) }
            #expect(webrtc_aec_process_capture(aec, &near) == 0)
            out.replaceSubrange(start..<start + frame, with: near)
        }
        // After 3 s of convergence, the echo must be at least 25 dB down.
        let tail = rate * 3..<far.count
        let erle = 10 * log10(Self.power(mic[tail]) / max(Self.power(out[tail]), 1e-20))
        #expect(erle >= 25, "ERLE \(erle) dB")
    }
}
