import Foundation
import Testing

@testable import ProjectKit

@Suite struct ProjectTests {
    static func sample() -> Project {
        Project(
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            capture: .init(target: .display, pixelSize: PixelSize(width: 1728, height: 1080), fps: 30, codec: .hevc),
            segments: [.init(file: "segment-000.mov", duration: 4.5, tracks: [.screen, .camera, .system, .mic])],
            camera: .init(enabled: true)
        )
    }

    @Test func roundTripsThroughJSON() throws {
        let project = Self.sample()
        let decoded = try Project.decode(project.encoded())
        #expect(decoded == project)
    }

    @Test func writesCurrentSchemaVersion() throws {
        let json = try JSONSerialization.jsonObject(with: Self.sample().encoded()) as? [String: Any]
        #expect(json?["schemaVersion"] as? Int == Project.currentSchemaVersion)
    }

    @Test func rejectsFutureSchemaVersion() {
        let data = Data(#"{"schemaVersion": 99}"#.utf8)
        #expect(throws: ProjectError.unsupportedSchemaVersion(99)) { try Project.decode(data) }
    }

    @Test func durationSumsSegments() {
        var project = Self.sample()
        project.segments.append(.init(file: "segment-001.mov", duration: 2.5, tracks: [.screen]))
        #expect(project.duration == 7.0)
    }

    @Test func schemaVersionsBelowOneAreRefused() {
        #expect(throws: ProjectError.unsupportedSchemaVersion(0)) { try Project.decode(Data(#"{"schemaVersion":0}"#.utf8)) }
    }
}
