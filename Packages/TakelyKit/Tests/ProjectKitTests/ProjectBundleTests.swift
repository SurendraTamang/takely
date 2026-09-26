import Foundation
import Testing

@testable import ProjectKit

@Suite struct ProjectBundleTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "takely-tests-\(UUID().uuidString)")

    @Test func createsNamedPackageWithSubfolders() throws {
        let date = Date(timeIntervalSince1970: 0)
        let bundle = try ProjectBundle.create(in: folder, date: date)
        #expect(bundle.url.pathExtension == "takely")
        #expect(bundle.name.hasPrefix("Recording-"))
        #expect(FileManager.default.fileExists(atPath: bundle.segmentsURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.exportsURL.path))
    }

    @Test func persistsManifestAndCursor() throws {
        let bundle = try ProjectBundle.create(in: folder)
        let project = ProjectTests.sample()
        let cursor = CursorTrack(samples: [CursorSample(t: 0, x: 0.1, y: 0.2)])
        try bundle.write(project)
        try bundle.write(cursor)
        #expect(try bundle.readProject() == project)
        #expect(try bundle.readCursor() == cursor)
    }

    @Test func missingCursorReadsEmpty() throws {
        let bundle = try ProjectBundle.create(in: folder)
        #expect(try bundle.readCursor() == CursorTrack())
    }

    @Test func segmentNamesAreZeroPadded() {
        #expect(ProjectBundle.segmentFileName(index: 7) == "segment-007.mov")
    }
}
