import CoreGraphics
import Foundation
import Testing

@testable import TakelyControl

@Suite struct ControlTests {
    @Test func parsesURLSchemeCommandsAndOptions() throws {
        let start = try #require(ControlURL(URL(string: "takely://record/start?countdown=0&region=10,20,300,200")!))
        #expect(start.request == ControlRequest(.start, countdown: false, region: CGRect(x: 10, y: 20, width: 300, height: 200)))
        #expect(ControlURL(URL(string: "takely://record/stop")!)?.request.command == .stop)
        #expect(ControlURL(URL(string: "takely://status")!)?.request.command == .status)
        #expect(ControlURL(URL(string: "takely://record/explode")!) == nil)
        #expect(ControlURL(URL(string: "https://record/start")!) == nil)
    }

    @Test func xCallbackCarriesThePathOrTheError() throws {
        let url = try #require(
            ControlURL(URL(string: "takely://record/stop?x-success=shortcuts://done&x-error=shortcuts://failed?from=takely")!))
        let done = url.callback(for: ControlReply(ok: true, state: "idle", path: "/Movies/a b.mp4", duration: 12.34))
        #expect(done?.absoluteString == "shortcuts://done?path=/Movies/a%20b.mp4&duration=12.3&state=idle")
        let failed = url.callback(for: ControlReply(ok: false, state: "idle", error: "Not recording."))
        #expect(failed?.absoluteString == "shortcuts://failed?from=takely&errorMessage=Not%20recording.")
        #expect(ControlURL(URL(string: "takely://record/stop")!)?.callback(for: ControlReply(ok: true, state: "idle")) == nil)
    }

    @Test func requestAndReplyRoundTripThroughARealSocket() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "tk-\(UUID().uuidString.prefix(6)).sock").path
        let server = SocketServer(path: path) { request in
            ControlReply(ok: request.command == .status, state: "idle", path: request.countdown == false ? "/x.mp4" : nil)
        }
        try server.start()
        defer { server.stop() }
        var attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let reply = try await Task.detached { try SocketClient.send(ControlRequest(.status, countdown: false), path: path) }.value
        #expect(reply == ControlReply(ok: true, state: "idle", path: "/x.mp4"))
        server.stop()
        attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        #expect(attributes.isEmpty)
        #expect(throws: SocketError.notRunning) { try SocketClient.send(ControlRequest(.status), path: path) }
    }
}
