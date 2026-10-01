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
guard let name = arguments.first, name != "help", name != "--help", name != "-h" else { exit(arguments.isEmpty ? 2 : 0, usage) }
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

/// Sends the request, launching Takely first if it isn't running (and waiting up to 10 s for it to listen).
func send(_ request: ControlRequest) throws -> ControlReply {
    do {
        return try SocketClient.send(request)
    } catch SocketError.notRunning {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.takely.Takely") else {
            throw SocketError.notRunning
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            if let reply = try? SocketClient.send(request) { return reply }
        }
        throw SocketError.notRunning
    }
}

do {
    let reply = try send(request)
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(reply), as: UTF8.self))
    } else if reply.ok {
        print(reply.path ?? reply.state)
    }
    if !reply.ok {
        if !json { FileHandle.standardError.write(Data(((reply.error ?? "Failed.") + "\n").utf8)) }
        exit(1)
    }
} catch {
    exit(3, error.localizedDescription)
}
