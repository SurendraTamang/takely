import CoreGraphics
import Foundation
import Testing

@testable import TakelyControl

@Suite struct ControlTests {
    /// In a fresh private folder (socket paths must stay under ~100 bytes).
    static func socketPath() -> String {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tk-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder.appending(path: "c.sock").path
    }

    @Test func parsesURLSchemeCommandsAndOptions() throws {
        let start = try #require(ControlURL(URL(string: "takely://record/start?countdown=0&region=10,20,300,200")!))
        #expect(start.request == ControlRequest(.start, countdown: false, region: CGRect(x: 10, y: 20, width: 300, height: 200)))
        #expect(ControlURL(URL(string: "takely://record/stop")!)?.request.command == .stop)
        #expect(ControlURL(URL(string: "takely://status")!)?.request.command == .status)
        #expect(ControlURL(URL(string: "takely://record/explode")!) == nil)
        #expect(ControlURL(URL(string: "takely://record/start?region=0,0,-1,-1")!)?.request.hasInvalidRegion == true)
        #expect(ControlURL(URL(string: "takely://record/start?region=1,2")!)?.request.hasInvalidRegion == true)
        #expect(ControlURL(URL(string: "https://record/start")!) == nil)
    }

    @Test func xCallbackCarriesThePathOrTheError() throws {
        let url = try #require(
            ControlURL(URL(string: "takely://record/stop?x-success=shortcuts://done&x-error=shortcuts://failed?from=takely")!))
        // Never the path or title: any web page can open a link.
        let done = url.callback(for: ControlReply(ok: true, state: "idle", path: "/Movies/a b.mp4", duration: 12.34, title: "Secret"))
        #expect(done?.absoluteString == "shortcuts://done?state=idle")
        let failed = url.callback(for: ControlReply(ok: false, state: "idle", error: "Not recording."))
        #expect(failed?.absoluteString == "shortcuts://failed?from=takely&errorMessage=Not%20recording.")
        #expect(ControlURL(URL(string: "takely://record/stop")!)?.callback(for: ControlReply(ok: true, state: "idle")) == nil)
        for blocked in ["https://evil.example/", "file:///Applications/Calculator.app", "javascript:alert(1)", "takely://record/stop"] {
            let hostile = ControlURL(URL(string: "takely://status?x-success=\(blocked)&x-error=\(blocked)")!)
            #expect(hostile?.callback(for: ControlReply(ok: true, state: "idle")) == nil, "\(blocked)")
        }
    }

    @Test func requestAndReplyRoundTripThroughARealSocket() async throws {
        let path = Self.socketPath()
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

    @Test func aSecondServerDoesNotTakeOverALiveSocket() async throws {
        let path = Self.socketPath()
        let first = SocketServer(path: path) { _ in ControlReply(ok: true, state: "first") }
        try first.start()
        defer { first.stop() }
        let second = SocketServer(path: path) { _ in ControlReply(ok: true, state: "second") }
        #expect(throws: SocketError.alreadyServing) { try second.start() }
        second.stop()  // never started: leaves the first one's socket alone
        let reply = try await Task.detached { try SocketClient.send(ControlRequest(.status), path: path) }.value
        #expect(reply.state == "first")
    }

    @Test func aStaleSocketFileIsReplaced() async throws {
        let path = Self.socketPath()
        FileManager.default.createFile(atPath: path, contents: Data())  // left behind by a crash
        let server = SocketServer(path: path) { _ in ControlReply(ok: true, state: "idle") }
        try server.start()
        defer { server.stop() }
        let reply = try await Task.detached { try SocketClient.send(ControlRequest(.status), path: path) }.value
        #expect(reply.ok)
    }

    @Test func aSilentClientDoesNotDelayOthers() async throws {
        let path = Self.socketPath()
        let server = SocketServer(path: path) { _ in ControlReply(ok: true, state: "idle") }
        try server.start()
        defer { server.stop() }
        let silent = try SocketClient.connect(path)  // connects, never writes
        defer { close(silent) }
        let started = ContinuousClock.now
        let reply = try await Task.detached { try SocketClient.send(ControlRequest(.status), path: path) }.value
        #expect(reply.ok)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func aLineSentByteByByteIsCutOffAtTheDeadline() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { fds.forEach { close($0) } }
        _ = write(fds[1], "x", 1)  // then nothing more: the read would wait for the newline
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let started = ContinuousClock.now
        #expect(LineIO.readLine(fds[0], deadline: .now) == nil)
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
