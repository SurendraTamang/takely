import Foundation
import MCP
import TakelyControl
import TakelyMCPKit

// `takely-mcp` — Takely's MCP server for AI agents (Claude Code, Codex, Cursor…), over stdio. Add it with e.g.
// `claude mcp add takely -- /Applications/Takely.app/Contents/Helpers/takely-mcp`. Takely must be running.

let server = Server(
    name: "takely", version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
    instructions: """
        Takely records this Mac's screen. Use it to show your work as a video: record_start, do the work (or run_demo \
        with a plan to perform and narrate it), record_stop, then share for a link (e.g. for a pull request). The \
        person sees when Takely records and confirms demo plans; secrets on screen are blurred when that's on.
        """,
    capabilities: .init(tools: .init(listChanged: false)))

await server.withMethodHandler(ListTools.self) { _ in .init(tools: TakelyTools.all) }
await server.withMethodHandler(CallTool.self) { params in
    await TakelyTools.call(params.name, arguments: params.arguments) { request in
        // Blocking socket I/O, off the server's tasks.
        try await Task.detached { try send(request) }.value
    }
}

/// Sends a request; if Takely isn't running, opens it in the background (as the `takely` CLI does) and waits for it,
/// up to 10 s. `status` just reports that it isn't running.
@Sendable func send(_ request: ControlRequest) throws -> ControlReply {
    do {
        return try SocketClient.send(request)
    } catch SocketError.notRunning where request.command != .status {
        let open = Process()
        open.executableURL = URL(filePath: "/usr/bin/open")
        open.arguments = ["-g", "-b", "app.takely.Takely"]  // -g: don't bring it to the front
        try open.run()
        open.waitUntilExit()
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            do { return try SocketClient.send(request) } catch SocketError.notRunning { continue }
        }
        throw SocketError.notRunning
    }
}
try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
