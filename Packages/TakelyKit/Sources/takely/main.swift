import AppKit
import TakelyControl

// `takely` — controls the running Takely app (launching it if needed). See `takely help`.

let usage = """
    Usage: takely <command> [options]

      record start [--no-countdown] [--region x,y,w,h]   start recording (the chosen display, or an area)
             [--display n] [--no-camera] [--no-mic]       display n (1 = leftmost); without camera or microphone
             [--window <app or title>]                    a window: the app's name or bundle ID, or text in its title
      record stop                                        stop, export, and print the video's path
      pause | resume | marker | retake | discard         while recording
      status                                             what Takely is doing
      demo [run] <plan.txt | ->                          record a Demo Mode plan (Takely Pro); prints the video's path
                                                         (Ctrl-C stops the demo and keeps what was recorded)
      demo stop                                          stop the running demo
      doctor                                             check permissions, copies of the app, disk, Apple Intelligence
      share <video.mp4>                                  upload a recording to your bucket and print its link

      --json   print the reply as JSON

    Exit status: 0 done, 1 Takely refused or failed, 2 bad usage, 3 Takely couldn't be reached.
    """

func exit(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let json = arguments.contains("--json")
arguments.removeAll { $0 == "--json" }
if arguments.first == "record" { arguments.removeFirst() }
guard let name = arguments.first else { exit(2, usage) }
if ["help", "--help", "-h"].contains(name) {
    print(usage)
    exit(0)
}
if name == "demo", arguments.dropFirst().first == "stop" { arguments = ["demo-stop"] + arguments.dropFirst(2) }
guard let command = ControlRequest.Command(rawValue: arguments[0]) else { exit(2, "Unknown command “\(name)”.\n\n" + usage) }
var request = ControlRequest(command)
var rest = arguments.dropFirst()
if command == .share {
    guard let file = rest.popFirst(), rest.isEmpty else { exit(2, "share needs the recording's MP4.\n\n" + usage) }
    request.path = URL(filePath: file).standardizedFileURL.path
}
if command == .demo {
    if rest.first == "run" { rest.removeFirst() }
    guard let file = rest.popFirst(), rest.isEmpty else { exit(2, "demo needs one plan file (or - for standard input).\n\n" + usage) }
    let data = file == "-" ? FileHandle.standardInput.readDataToEndOfFile() : FileManager.default.contents(atPath: file)
    guard let data, let plan = String(data: data, encoding: .utf8) else { exit(2, "Couldn't read the plan “\(file)”.") }
    request.plan = plan
}
while let option = rest.popFirst() {
    switch option {
    case "--no-countdown" where command == .start:
        request.countdown = false
    case "--countdown" where command == .start:
        request.countdown = true
    case "--no-camera" where command == .start:
        request.camera = false
    case "--no-mic" where command == .start:
        request.microphone = false
    case "--display" where command == .start:
        guard let number = rest.popFirst().flatMap({ Int($0) }), number >= 1 else { exit(2, "--display needs a number from 1 (leftmost).") }
        request.display = number
    case "--window" where command == .start:
        guard let text = rest.popFirst(), !text.isEmpty else { exit(2, "--window needs an app name, bundle ID or title text.") }
        request.window = text
    case "--region" where command == .start:
        let numbers = (rest.popFirst() ?? "").split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { exit(2, "--region needs x,y,width,height (points).") }
        request.region = numbers
    default:
        exit(2, "Unknown option “\(option)” for \(name).\n\n" + usage)
    }
}

/// The Takely app this tool belongs to (it ships inside it, as Contents/Helpers/takely), else the registered one.
func takelyApp() -> URL? {
    let tool = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = tool.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if bundle.pathExtension == "app" { return bundle }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.takely.Takely")
}

/// Sends the request. If Takely isn't running it's launched first (except for `status`, which then just says so),
/// and the request is sent once it listens (within 10 s) — only resent while nothing was listening.
func send(_ request: ControlRequest) throws -> ControlReply {
    do {
        return try SocketClient.send(request)
    } catch SocketError.notRunning {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "app.takely.Takely").isEmpty {
            throw CLIError.unreachable
        }
        guard request.command != .status else { return ControlReply(ok: true, state: "not running") }
        guard let app = takelyApp() else { throw SocketError.notRunning }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            do {
                return try SocketClient.send(request)
            } catch SocketError.notRunning {
                continue
            }
        }
        throw SocketError.notRunning
    }
}

enum CLIError: Error, LocalizedError {
    case unreachable
    var errorDescription: String? {
        "Takely is running but isn't accepting commands (another copy may be listening, or its control socket failed)."
    }
}

/// Ctrl-C during `takely demo` stops the demo in the app (what was recorded is kept) and waits for its answer; a
/// second Ctrl-C quits without waiting.
var interrupt: DispatchSourceSignal?
if command == .share {
    guard let file = rest.popFirst(), rest.isEmpty else { exit(2, "share needs the recording's MP4.\n\n" + usage) }
    request.path = URL(filePath: file).standardizedFileURL.path
}
if command == .demo {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    var stopping = false
    source.setEventHandler {
        if stopping { exit(130) }
        stopping = true
        FileHandle.standardError.write(Data("\nStopping the demo… (Ctrl-C again to quit without waiting)\n".utf8))
        _ = try? SocketClient.send(ControlRequest(.stopDemo))
    }
    source.resume()
    interrupt = source
}

do {
    let reply = try send(request)
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(reply), as: UTF8.self))
    } else if reply.ok {
        print(
            request.command == .doctor
                ? reply.report ?? reply.state
                : request.command == .share
                    ? reply.link ?? reply.state
                    : request.command == .stop || request.command == .demo ? reply.path ?? reply.state : reply.state)
    }
    if !reply.ok {
        if !json, let report = reply.report {
            print(report)  // doctor found problems: the report says which
        } else if !json {
            // An app older than this command doesn't know the request (e.g. updated but not restarted).
            let error =
                reply.error == "Couldn't read the request" && request.command == .doctor
                ? "This Takely is older than the takely command: quit and reopen Takely (or update it)." : reply.error ?? "Failed."
            FileHandle.standardError.write(Data((error + "\n").utf8))
        }
        exit(1)
    }
} catch {
    exit(3, error.localizedDescription)
}
