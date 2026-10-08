import Foundation
import MCP
import TakelyControl
import TakelyMCPKit

// `takely-mcp` — Takely's MCP server for AI agents (Claude Code, Codex, Cursor…), over stdio. Add it with e.g.
// `claude mcp add takely -- /Applications/Takely.app/Contents/Helpers/takely-mcp`. Takely must be running.

/// The Takely app this server ships in (Contents/Helpers/takely-mcp), if it's inside one.
let app: URL? = {
    let tool = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = tool.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return bundle.pathExtension == "app" ? bundle : nil
}()

let server = Server(
    name: "takely",
    version: app.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? "dev",
    instructions: """
        Takely records this Mac's screen. Use it to show your work as a video: record_start, do the work (or run_demo \
        with a plan to perform and narrate it), record_stop, then share for a link (e.g. for a pull request). The \
        person sees when Takely records and confirms demo plans; secrets on screen are blurred when that's on.
        """,
    capabilities: .init(prompts: .init(listChanged: false), tools: .init(listChanged: false)))

await server.withMethodHandler(ListTools.self) { _ in .init(tools: TakelyTools.all) }
await server.withMethodHandler(ListPrompts.self) { _ in .init(prompts: TakelyPrompts.all) }
await server.withMethodHandler(GetPrompt.self) { params in
    guard let prompt = TakelyPrompts.get(params.name, arguments: params.arguments) else {
        throw MCPError.invalidParams("Unknown prompt \(params.name)")
    }
    return prompt
}
/// Blocking socket calls (a demo or an export can take minutes) run on their own queue, never on the Swift
/// concurrency pool the server reads requests on.
let calls = DispatchQueue(label: "app.takely.mcp.calls", attributes: .concurrent)

await server.withMethodHandler(CallTool.self) { params in
    await TakelyTools.call(params.name, arguments: params.arguments) { request in
        try await withCheckedThrowingContinuation { continuation in
            calls.async { continuation.resume(with: Result { try send(request) }) }
        }
    }
}

/// Sends a request; if Takely isn't running, opens it in the background (as the `takely` CLI does) and waits for it,
/// up to 10 s. `status` just reports that it isn't running.
@Sendable func send(_ request: ControlRequest) throws -> ControlReply {
    do {
        return try SocketClient.send(request)
    } catch SocketError.notRunning where request.command != .status {
        // The Takely this server ships in (not whichever copy macOS picks for the bundle ID); -g: stay in the back.
        let open = Process()
        open.executableURL = URL(filePath: "/usr/bin/open")
        open.arguments = ["-g"] + (app.map { [$0.path] } ?? ["-b", "app.takely.Takely"])
        open.standardOutput = FileHandle.nullDevice  // stdout is the MCP channel
        open.standardError = FileHandle.nullDevice
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
