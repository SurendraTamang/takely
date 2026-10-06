import Foundation
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

    @Test func threeKeyframesAndTimesBeforeTheFirst() throws {
        let moved = Project.Camera(
            enabled: true,
            keyframes: [BubbleKeyframe(t: 1, x: 0.8, y: 0.8), BubbleKeyframe(t: 5, x: 0.2, y: 0.8), BubbleKeyframe(t: 9, x: 0.2, y: 0.2)])
        let near = { (p: NormalizedPoint?, x: Double, y: Double) in p.map { abs($0.x - x) < 1e-9 && abs($0.y - y) < 1e-9 } == true }
        #expect(near(moved.bubbleCenter(at: 0), 0.8, 0.8))  // before the first: where it starts
        #expect(near(moved.bubbleCenter(at: 7), 0.2, 0.8))
        let sliding = try #require(moved.bubbleCenter(at: 9.075))
        #expect(abs(sliding.y - 0.5) < 1e-9 && abs(sliding.x - 0.2) < 1e-9)  // from the second, not the first
        #expect(near(moved.bubbleCenter(at: 100), 0.2, 0.2))
    }

    @Test func noKeyframesMeansNoBubble() {
        #expect(Project.Camera(enabled: true, keyframes: []).bubbleCenter(at: 0) == nil)
    }

    @Test func hiddenKeyframesHideTheBubbleAndItReappearsWhereItWasShown() throws {
        let camera = Project.Camera(
            enabled: true,
            keyframes: [
                BubbleKeyframe(t: 0, x: 0.8, y: 0.8),
                BubbleKeyframe(t: 5, x: 0.8, y: 0.8, visible: false),
                BubbleKeyframe(t: 8, x: 0.3, y: 0.3),
            ])
        #expect(camera.bubbleCenter(at: 3) != nil)
        #expect(camera.bubbleCenter(at: 6) == nil)
        // No slide in from the hidden position: it appears at its new place.
        #expect(camera.bubbleCenter(at: 8.01) == NormalizedPoint(x: 0.3, y: 0.3))
    }

    @Test func manifestsWithoutVisibilityDecodeAsVisible() throws {
        let decoded = try JSONDecoder().decode(BubbleKeyframe.self, from: Data(#"{"t":1,"x":0.5,"y":0.25}"#.utf8))
        #expect(decoded == BubbleKeyframe(t: 1, x: 0.5, y: 0.25, visible: true))
    }

    @Test func keyframesWithin150msReplaceThePreviousOne() {
        var camera = Project.Camera(enabled: true, size: 0.2, keyframes: [])
        camera.record(BubbleKeyframe(t: 0, x: 0.5, y: 0.5), aspect: 1)
        camera.record(BubbleKeyframe(t: 0.1, x: 0.6, y: 0.5), aspect: 1)
        camera.record(BubbleKeyframe(t: 2, x: 0.4, y: 0.5), aspect: 1)
        #expect(camera.keyframes == [BubbleKeyframe(t: 0.1, x: 0.6, y: 0.5), BubbleKeyframe(t: 2, x: 0.4, y: 0.5)])
    }

    @Test func recordedKeyframesKeepTheBubbleInsideTheFrame() {
        // A 16:10 frame: the bubble (0.2 of the width) is 0.32 of the height.
        var camera = Project.Camera(enabled: true, size: 0.2, keyframes: [])
        camera.record(BubbleKeyframe(t: 0, x: 1.2, y: -0.5), aspect: 1.6)
        let k = camera.keyframes[0]
        #expect(abs(k.x - 0.9) < 1e-9)
        #expect(abs(k.y - 0.16) < 1e-9)
    }

    @Test func simultaneousClicksAndASingleSample() {
        let track = CursorTrack(
            samples: [CursorSample(t: 2, x: 0.4, y: 0.6)], clicks: [ClickEvent(t: 1, x: 0.1, y: 0.1), ClickEvent(t: 1, x: 0.9, y: 0.9)])
        #expect(track.clicks(activeAt: 1.1).count == 2)  // both ripple
        #expect(track.position(at: 0) == NormalizedPoint(x: 0.4, y: 0.6))
        #expect(track.position(at: 50) == NormalizedPoint(x: 0.4, y: 0.6))
    }

    @Test func noClickEffectsPastTheCursorData() {
        let track = CursorTrack(clicks: [ClickEvent(t: 5, x: 0.5, y: 0.5)], coveredUntil: 5.1)
        #expect(track.clicks(activeAt: 5.05).count == 1)
        #expect(track.clicks(activeAt: 5.2).isEmpty)
    }
}
