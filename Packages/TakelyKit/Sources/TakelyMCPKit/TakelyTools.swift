import Foundation
import MCP
import ProjectKit
import TakelyControl

/// Takely's tools for AI agents (MCP). Each one is a control command to the running app — the same path as the
/// `takely` CLI, with the same safety: the socket is this user's only, a demo plan is confirmed on screen, recording
/// shows Takely's indicator. Agents get plain-text answers they can act on.
public enum TakelyTools {
    /// Sends one request to the app (the control socket; a fake in tests).
    public typealias Send = @Sendable (ControlRequest) async throws -> ControlReply

    public static let all: [Tool] = [
        tool(
            "status", "Takely's state: idle, recording, paused, exporting… Call before starting.", [:],
            readOnly: true),
        tool(
            "record_start",
            "Start recording the Mac's screen (a display, one app's window, or an area). No countdown. Recording is "
                + "visible to the person (menu bar indicator). Stop with record_stop.",
            [
                "window": ("string", "Record only this app's window: its name (\"Safari\"), bundle ID, or text in its title"),
                "display": ("integer", "Record this display, counted from 1 left to right (default: the person's chosen display)"),
                "camera": ("boolean", "Include the camera bubble (default: the person's setting)"),
                "microphone": ("boolean", "Record the microphone (default: the person's setting)"),
            ]),
        tool(
            "record_stop",
            "Stop recording and export the video (waits for it). Returns the MP4's path, its length and title. "
                + "Secrets on screen (API keys, emails, card numbers) are blurred automatically when that setting is on.",
            [:]),
        tool("pause", "Pause the recording.", [:]),
        tool("resume", "Resume a paused recording.", [:]),
        tool("marker", "Mark this moment: it becomes a chapter in the video.", [:]),
        tool(
            "run_demo",
            "Perform a demo on the Mac while recording it, with spoken narration. Shown to the person first: nothing "
                + "runs until they confirm. Plan: one step per line — `open App`, `url https://…`, `click \"Label\"`, "
                + "`type \"text\"`, `key cmd+s`, `wait 1`, `say \"Narration.\"`. Prefer keyboard shortcuts over clicks. "
                + "Returns the video's path.",
            ["plan": ("string", "The steps, one per line")], required: ["plan"]),
        tool(
            "share",
            "Upload a finished recording to the person's own storage bucket and return its link — e.g. to put a demo "
                + "in a pull request. Needs sharing set up in Takely's Settings.",
            ["path": ("string", "The recording's MP4 (from record_stop or run_demo)")], required: ["path"]),
        tool(
            "transcript", "What was said in a recording, with times (made at export when transcription is on).",
            ["path": ("string", "The recording's MP4")], required: ["path"], readOnly: true),
        tool(
            "doctor", "Check what Takely needs (permissions, disk, Apple Intelligence) and what to fix.", [:], readOnly: true),
    ]

    /// Runs a tool; failures come back as an error result with Takely's own explanation.
    public static func call(_ name: String, arguments: [String: Value]?, send: Send) async -> CallTool.Result {
        let args = arguments ?? [:]
        do {
            switch name {
            case "status": return try await reply(send(ControlRequest(.status)))
            case "record_start":
                var request = ControlRequest(.start, countdown: false)
                request.window = args["window"]?.stringValue
                request.display = args["display"]?.intValue
                if let camera = args["camera"]?.boolValue { request.camera = camera }
                if let microphone = args["microphone"]?.boolValue { request.microphone = microphone }
                return try await reply(send(request))
            case "record_stop": return try await reply(send(ControlRequest(.stop)))
            case "pause": return try await reply(send(ControlRequest(.pause)))
            case "resume": return try await reply(send(ControlRequest(.resume)))
            case "marker": return try await reply(send(ControlRequest(.marker)))
            case "run_demo":
                guard let plan = args["plan"]?.stringValue else { return failure("run_demo needs a plan.") }
                return try await reply(send(ControlRequest(.demo, plan: plan)))
            case "share":
                guard let path = args["path"]?.stringValue else { return failure("share needs the recording's path.") }
                var request = ControlRequest(.share)
                request.path = path
                return try await reply(send(request))
            case "doctor": return try await reply(send(ControlRequest(.doctor)))
            case "transcript":
                guard let path = args["path"]?.stringValue else { return failure("transcript needs the recording's path.") }
                return transcript(URL(filePath: path))
            default: return failure("Unknown tool \(name).")
            }
        } catch {
            return failure(error.localizedDescription)
        }
    }

    /// The app's answer as text: what happened, and the details an agent needs next (path, length, link, report).
    static func reply(_ reply: ControlReply) -> CallTool.Result {
        guard reply.ok else {
            return CallTool.Result(content: [text(reply.report ?? reply.error ?? "Failed (\(reply.state)).")], isError: true)
        }
        var lines = ["state: \(reply.state)"]
        if let path = reply.path { lines.append("path: \(path)") }
        if let duration = reply.duration { lines.append(String(format: "duration: %.1f s", duration)) }
        if let title = reply.title { lines.append("title: \(title)") }
        if let link = reply.link { lines.append("link: \(link)") }
        if let report = reply.report { lines.append(report) }
        return CallTool.Result(content: [text(lines.joined(separator: "\n"))], isError: false)
    }

    /// "[0:12] Hello there" per phrase; read straight from the recording (no app needed).
    static func transcript(_ url: URL) -> CallTool.Result {
        guard let bundle = ProjectBundle.containing(url) ?? (url.pathExtension == "takely" ? ProjectBundle(url: url) : nil) else {
            return failure("That isn't a Takely recording.")
        }
        guard let transcript = try? bundle.readTranscript(), !transcript.phrases.isEmpty else {
            return failure("No transcript: transcription was off, nothing was said, or the language isn't supported.")
        }
        let lines = transcript.phrases.map { phrase in
            "[\(Duration.seconds(phrase.start).formatted(.time(pattern: .minuteSecond)))] \(phrase.text)"
        }
        return CallTool.Result(content: [text(lines.joined(separator: "\n"))], isError: false)
    }

    static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [text(message)], isError: true)
    }

    static func text(_ string: String) -> Tool.Content { .text(text: string, annotations: nil, _meta: nil) }

    private static func tool(
        _ name: String, _ description: String, _ properties: [String: (type: String, description: String)],
        required: [String] = [], readOnly: Bool = false
    ) -> Tool {
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(
                properties.mapValues { .object(["type": .string($0.type), "description": .string($0.description)]) }),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return Tool(
            name: name, description: description, inputSchema: .object(schema),
            annotations: .init(readOnlyHint: readOnly, openWorldHint: name == "share"))
    }
}
