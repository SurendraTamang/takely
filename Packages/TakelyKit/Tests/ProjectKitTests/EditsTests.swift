import Foundation
import Testing

@testable import ProjectKit

@Suite struct EditsTests {
    @Test func cutsMergeAndRestoreSplits() {
        var edits = Edits()
        edits.cut(TimeRange(start: 5, end: 7))
        edits.cut(TimeRange(start: 1, end: 2))
        edits.cut(TimeRange(start: 6, end: 9))
        #expect(edits.cuts == [TimeRange(start: 1, end: 2), TimeRange(start: 5, end: 9)])
        edits.restore(TimeRange(start: 6, end: 7))
        #expect(edits.cuts == [TimeRange(start: 1, end: 2), TimeRange(start: 5, end: 6), TimeRange(start: 7, end: 9)])
    }

    @Test func mapsRecordingTimeToOutputAndBack() {
        let map = EditMap(cuts: [TimeRange(start: 0, end: 1), TimeRange(start: 4, end: 6)], duration: 10)
        #expect(map.kept == [TimeRange(start: 1, end: 4), TimeRange(start: 6, end: 10)])
        #expect(map.outputDuration == 7 && map.hasCuts)
        #expect(map.outputTime(0.5) == nil && map.outputTime(5) == nil)
        #expect(map.outputTime(2) == 1 && map.outputTime(7) == 4 && map.outputTime(10) == 7)
        #expect(map.sourceTime(1) == 2 && map.sourceTime(3) == 6 && map.sourceTime(4) == 7)
        // A caption across a cut is clipped; one inside a cut is gone.
        #expect(map.output(TimeRange(start: 3, end: 7)) == TimeRange(start: 2, end: 4))
        #expect(map.output(TimeRange(start: 4.5, end: 5.5)) == nil)
        #expect(!EditMap(cuts: [], duration: 10).hasCuts)
        // A few ms left between two cuts is dropped; joins land on whole ticks.
        let sliver = EditMap(cuts: [TimeRange(start: 1, end: 2), TimeRange(start: 2.01, end: 3.00049)], duration: 5)
        #expect(sliver.kept == [TimeRange(start: 0, end: 1), TimeRange(start: 3, end: 5)])
    }

    @Test func zoomEasesInAndOut() {
        let zoom = Zoom(start: 10, end: 14, scale: 2)
        #expect(zoom.scale(at: 9) == 1 && zoom.scale(at: 10) == 1)
        #expect(zoom.scale(at: 10.2) > 1 && zoom.scale(at: 10.2) < 2)
        #expect(zoom.scale(at: 12) == 2)
        #expect(Zoom(start: 0, end: 1, scale: 9).scale == 3)
    }

    @Test func roundTripsThroughTheBundle() throws {
        let bundle = try ProjectBundle.create(in: FileManager.default.temporaryDirectory.appending(path: "takely-tests/\(UUID())"))
        #expect(try bundle.readEdits().isEmpty)
        let edits = Edits(
            cuts: [TimeRange(start: 1, end: 2)], zooms: [Zoom(start: 3, end: 5, focus: .point(NormalizedPoint(x: 0.2, y: 0.3)))])
        try bundle.write(edits)
        #expect(try bundle.readEdits() == edits)
    }
}
