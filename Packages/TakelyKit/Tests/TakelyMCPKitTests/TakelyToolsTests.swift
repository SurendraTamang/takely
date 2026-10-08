import Foundation
import MCP
import ProjectKit
import Synchronization
import TakelyControl
import Testing

@testable import TakelyMCPKit

@Suite struct TakelyToolsTests {
    /// Records what the tools send, and answers like the app.
    final class FakeApp: Sendable {
        let sent = Mutex<[ControlRequest]>([])
        let answer: @Sendable (ControlRequest) -> ControlReply
        init(_ answer: @escaping @Sendable (ControlRequest) -> ControlReply) { self.answer = answer }
        var send: TakelyTools.Send {
            { request in
                self.sent.withLock { $0.append(request) }
                return self.answer(request)
            }
        }
    }

    static func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { if case .text(let text, _, _) = $0 { text } else { nil } }.joined()
    }

    @Test func everyToolHasADescriptionAndAnObjectSchema() {
        #expect(Set(TakelyTools.all.map(\.name)).count == TakelyTools.all.count)
        for tool in TakelyTools.all {
            #expect(tool.description?.isEmpty == false, "\(tool.name)")
            #expect(tool.inputSchema.objectValue?["type"]?.stringValue == "object", "\(tool.name)")
        }
    }

    @Test func recordStartMapsItsArgumentsAndNeverCountsDown() async {
        let app = FakeApp { _ in ControlReply(ok: true, state: "recording") }
        let result = await TakelyTools.call(
            "record_start", arguments: ["window": "Safari", "camera": false, "display": 2], send: app.send)
        #expect(result.isError == false && Self.text(result) == "state: recording")
        let request = app.sent.withLock { $0 }.first
        #expect(request?.command == .start && request?.countdown == false)
        #expect(request?.window == "Safari" && request?.camera == false && request?.display == 2 && request?.microphone == nil)
    }

    @Test func stopReturnsWhatAnAgentNeedsNext() async {
        let app = FakeApp { _ in ControlReply(ok: true, state: "idle", path: "/Movies/a.mp4", duration: 12.34, title: "Fix the login") }
        let result = await TakelyTools.call("record_stop", arguments: nil, send: app.send)
        #expect(Self.text(result) == "state: idle\npath: /Movies/a.mp4\nduration: 12.3 s\ntitle: Fix the login")
    }

    @Test func failuresAreErrorResultsWithTakelysReason() async {
        let app = FakeApp { _ in ControlReply(ok: false, state: "idle", error: "Not recording.") }
        let result = await TakelyTools.call("record_stop", arguments: nil, send: app.send)
        #expect(result.isError == true && Self.text(result) == "Not recording.")
        let unreachable = await TakelyTools.call("status", arguments: nil) { _ in throw SocketError.notRunning }
        #expect(unreachable.isError == true && Self.text(unreachable) == "Takely isn't running.")
        #expect(await TakelyTools.call("run_demo", arguments: [:], send: app.send).isError == true)
    }

    @Test func shareAndDemoCarryTheirInput() async {
        let app = FakeApp { request in
            var reply = ControlReply(ok: true, state: "idle")
            if request.command == .share {
                reply.link = "https://cdn.example/takely/abc/index.html"
                reply.poster = "https://cdn.example/takely/abc/poster-1.jpg"
                reply.title = "Fix [login]"
                reply.duration = 75
            }
            return reply
        }
        let shared = await TakelyTools.call("share", arguments: ["path": "/Movies/a.mp4"], send: app.send)
        #expect(Self.text(shared).contains("link: https://cdn.example/takely/abc/index.html"))
        // Ready for a pull request: a clickable poster (brackets in the title escaped).
        #expect(
            Self.text(shared).contains(
                #"[![▶︎ Fix \[login\] (1:15)](https://cdn.example/takely/abc/poster-1.jpg)](https://cdn.example/takely/abc/index.html)"#))
        _ = await TakelyTools.call("run_demo", arguments: ["plan": "open TextEdit\nkey cmd+n"], send: app.send)
        let sent = app.sent.withLock { $0 }
        #expect(sent.map(\.command) == [.share, .demo])
        #expect(sent[0].path == "/Movies/a.mp4" && sent[1].plan == "open TextEdit\nkey cmd+n")
    }

    @Test func transcriptIsReadFromTheRecording() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try ProjectBundle.create(in: folder)
        try bundle.write(
            Transcript(
                locale: "en_US",
                phrases: [.init(start: 1, end: 3, text: "Here's the fix.", words: []), .init(start: 65, end: 67, text: "Done.", words: [])])
        )
        let mp4 = bundle.exportURL
        let result = await TakelyTools.call("transcript", arguments: ["path": .string(mp4.path)]) { _ in
            Issue.record("the app isn't needed")
            return ControlReply(ok: true, state: "idle")
        }
        #expect(Self.text(result) == "[0:01] Here's the fix.\n[1:05] Done.")
    }

    @Test func prDemoPromptWalksThroughConfirmedRecordingAndSharing() throws {
        #expect(TakelyPrompts.all.map(\.name) == ["pr_demo"])
        let result = try #require(TakelyPrompts.get("pr_demo", arguments: ["change": "the new Export button", "app": "Takely"]))
        guard case .text(let text) = result.messages.first?.content else {
            Issue.record("no text")
            return
        }
        #expect(text.contains("the new Export button working in Takely"))
        for step in ["run_demo", "confirms", "share", "pull request"] { #expect(text.contains(step), "\(step)") }
        #expect(TakelyPrompts.get("nope", arguments: nil) == nil)
    }

    @Test func pathsMustBeFull() async {
        let app = FakeApp { _ in ControlReply(ok: true, state: "idle") }
        #expect(await TakelyTools.call("share", arguments: ["path": "a.mp4"], send: app.send).isError == true)
        #expect(app.sent.withLock { $0 }.isEmpty)  // never sent: the app would resolve it elsewhere
        _ = await TakelyTools.call("share", arguments: ["path": "~/Movies/Takely/x.takely/exports/x.mp4"], send: app.send)
        #expect(app.sent.withLock { $0 }.first?.path == NSHomeDirectory() + "/Movies/Takely/x.takely/exports/x.mp4")
    }
}
