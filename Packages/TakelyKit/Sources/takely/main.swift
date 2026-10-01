import AppKit
import TakelyControl

// `takely` — controls the running Takely app (launching it if needed). See `takely help`.

let usage = """
    Usage: takely <command> [options]

      record start [--no-countdown] [--region x,y,w,h]   start recording (the chosen display, or an area)
      record stop                                        stop, export, and print the video's path
      pause | resume | marker | retake | discard         while recording
      status                                             what Takely is doing

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
guard let command = ControlRequest.Command(rawValue: name) else { exit(2, "Unknown command “\(name)”.\n\n" + usage) }
var request = ControlRequest(command)
var rest = arguments.dropFirst()
while let option = rest.popFirst() {
    switch option {
    case "--no-countdown" where command == .start:
        request.countdown = false
    case "--countdown" where command == .start:
        request.countdown = true
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

do {
    let reply = try send(request)
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(reply), as: UTF8.self))
    } else if reply.ok {
        print(request.command == .stop ? reply.path ?? reply.state : reply.state)
    }
    if !reply.ok {
        if !json { FileHandle.standardError.write(Data(((reply.error ?? "Failed.") + "\n").utf8)) }
        exit(1)
    }
} catch {
    exit(3, error.localizedDescription)
}
