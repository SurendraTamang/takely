import Testing

@testable import ProjectKit

@Suite struct CursorTrackTests {
    let track = CursorTrack(
        samples: [CursorSample(t: 0, x: 0, y: 0), CursorSample(t: 1, x: 1, y: 0.5)],
        clicks: [ClickEvent(t: 2, x: 0.5, y: 0.5)]
    )

    @Test func emptyTrackHasNoPosition() {
        #expect(CursorTrack().position(at: 1) == nil)
    }

    @Test func interpolatesBetweenSamples() {
        #expect(track.position(at: 0.5) == NormalizedPoint(x: 0.5, y: 0.25))
    }

    @Test func clampsOutsideRange() {
        #expect(track.position(at: -1) == NormalizedPoint(x: 0, y: 0))
        #expect(track.position(at: 5) == NormalizedPoint(x: 1, y: 0.5))
    }

    @Test func clickIsActiveOnlyInsideWindow() {
        #expect(track.clicks(activeAt: 1.99).isEmpty)
        let active = track.clicks(activeAt: 2.15)
        #expect(active.count == 1)
        #expect(abs((active.first?.progress ?? 0) - 0.5) < 1e-9)
        #expect(track.clicks(activeAt: 2.31).isEmpty)
    }

    @Test func noPositionAfterCoverageEnds() {
        var covered = track
        covered.coveredUntil = 0.5
        #expect(covered.position(at: 0.4) != nil)
        #expect(covered.position(at: 0.6) == nil)
    }
}

@Suite struct BubbleKeyframeTests {
    let camera = Project.Camera(
        enabled: true,
        keyframes: [
            BubbleKeyframe(t: 0, x: 0.8, y: 0.8),
            BubbleKeyframe(t: 10, x: 0.2, y: 0.8),
        ])

    @Test func holdsPositionBetweenKeyframes() {
        #expect(camera.bubbleCenter(at: 5) == NormalizedPoint(x: 0.8, y: 0.8))
    }

    @Test func movesOverTransition() throws {
        let mid = try #require(camera.bubbleCenter(at: 10.075))
        #expect(abs(mid.x - 0.5) < 1e-9)
        let end = try #require(camera.bubbleCenter(at: 10.2))
        #expect(abs(end.x - 0.2) < 1e-9)
    }

    @Test func noKeyframesMeansNoBubble() {
        #expect(Project.Camera(enabled: true, keyframes: []).bubbleCenter(at: 0) == nil)
    }
}
