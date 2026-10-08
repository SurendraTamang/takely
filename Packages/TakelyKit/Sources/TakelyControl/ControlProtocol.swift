import CoreGraphics
import Foundation

/// A command to the running app, from the `takely` CLI, the `takely://` URL scheme or App Intents.
public struct ControlRequest: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable, CaseIterable {
        case start, stop, pause, resume, marker, retake, discard, status
        /// Runs a Demo Mode plan (Takely Pro) while recording it; replies with the video like `stop`.
        case demo
        /// Stops the running demo (`takely demo stop`, or Ctrl-C on `takely demo`); what was recorded is saved.
        case stopDemo = "demo-stop"
        /// Checks what Takely depends on (permissions, copies of the app, disk, Apple Intelligence) and says what to fix.
        case doctor
        /// Uploads a finished recording (its MP4) to the person's own bucket; replies with the link.
        case share
    }

    public var command: Command
    /// `start`: false skips the 3-2-1 countdown (nil: the user's setting).
    public var countdown: Bool?
    /// `start`: record this area (global points, origin top-left) instead of the chosen display.
    public var region: [Double]?
    /// `demo`: the plan's text.
    public var plan: String?
    /// `start`: false records without the camera or the microphone this time (nil: the user's setting).
    public var camera: Bool?
    public var microphone: Bool?
    /// `start`: the display to record, counted from 1 left to right (nil: the chosen one).
    public var display: Int?
    /// `start`: record the window of this app (name or bundle ID) or with this text in its title, frontmost first.
    public var window: String?
    /// `share`: the recording's MP4 (or its .takely bundle).
    public var path: String?

    public init(
        _ command: Command, countdown: Bool? = nil, region: CGRect? = nil, plan: String? = nil, camera: Bool? = nil,
        microphone: Bool? = nil, display: Int? = nil, window: String? = nil
    ) {
        self.window = window
        self.command = command
        self.plan = plan
        self.camera = camera
        self.microphone = microphone
        self.display = display
        self.countdown = countdown
        self.region = region.map { [$0.minX, $0.minY, $0.width, $0.height] }
    }

    /// The region, if one was given and it's valid (4 numbers, positive size).
    public var regionRect: CGRect? {
        guard let r = region, r.count == 4, r[2] > 0, r[3] > 0 else { return nil }
        return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
    }

    /// A region was given but can't be used: refuse rather than record the whole display instead.
    public var hasInvalidRegion: Bool { region != nil && regionRect == nil }
}

/// The app's answer: what state it's in now, and for `stop` the finished video.
public struct ControlReply: Codable, Sendable, Equatable {
    public var ok: Bool
    /// idle, starting, recording, paused, stopping or exporting.
    public var state: String
    public var path: String?
    public var duration: Double?
    public var title: String?
    public var error: String?
    /// `doctor`: the report, one line per check.
    public var report: String?
    /// `share`: the recording's link.
    public var link: String?

    public init(
        ok: Bool, state: String, path: String? = nil, duration: Double? = nil, title: String? = nil, error: String? = nil,
        report: String? = nil
    ) {
        self.report = report
        self.ok = ok
        self.state = state
        self.path = path
        self.duration = duration
        self.title = title
        self.error = error
    }
}

/// Where the app listens: a Unix domain socket only this user can open (like `docker.sock`).
public enum ControlSocket {
    public static var defaultPath: String {
        URL.applicationSupportDirectory.appending(path: "Takely/control.sock").path
    }
}

/// `takely://record/start?countdown=0&x-success=…&x-error=…` — the x-callback-url convention: on success the app
/// opens `x-success` with `state` added; on failure `x-error` with `errorMessage`.
///
/// Any web page or app can open a link, so a link is treated as untrusted: callbacks never carry the video's path or
/// title (use the CLI or Shortcuts for that), and can't open files or web pages.
public struct ControlURL: Sendable, Equatable {
    public var request: ControlRequest
    public var success: URL?
    public var failure: URL?

    public init?(_ url: URL) {
        guard url.scheme == "takely", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // takely://record/start, takely://record/stop … and takely://status.
        let parts = ([url.host() ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        let name = parts.first == "record" ? parts.dropFirst().first : parts.first
        // A demo drives the keyboard and mouse: never from a link (any web page can open one).
        guard let name, let command = ControlRequest.Command(rawValue: name), command != .demo, command != .stopDemo, command != .doctor,
            command != .share
        else { return nil }  // `doctor`, `share`: a web page mustn't learn what's on the Mac or publish it
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        var request = ControlRequest(command)
        if let countdown = query["countdown"] { request.countdown = !["0", "false", "no", "off"].contains(countdown.lowercased()) }
        let off = { (value: String) in ["0", "false", "no", "off"].contains(value.lowercased()) }
        if let camera = query["camera"], off(camera) { request.camera = false }
        if let microphone = query["mic"], off(microphone) { request.microphone = false }
        request.display = query["display"].map { Int($0) ?? 0 }
        request.window = query["window"]  // parsed so the app can refuse it (links can't choose a window)
        if let region = query["region"] {
            // Kept even when malformed, so the command is refused instead of recording the whole display.
            request.region = region.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? -1 }
        }
        self.request = request
        success = query["x-success"].flatMap(URL.init(string:)).flatMap(Self.allowedCallback)
        failure = query["x-error"].flatMap(URL.init(string:)).flatMap(Self.allowedCallback)
    }

    /// Callbacks go back to an app (Shortcuts, Raycast…), never to files, web pages, scripts or Takely itself.
    static func allowedCallback(_ url: URL) -> URL? {
        let blocked: Set<String> = ["file", "http", "https", "ftp", "data", "javascript", "takely"]
        guard let scheme = url.scheme?.lowercased(), !blocked.contains(scheme) else { return nil }
        return url
    }

    /// The callback to open for `reply`, if one was given.
    public func callback(for reply: ControlReply) -> URL? {
        guard let base = reply.ok ? success : failure, var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        var items = components.queryItems ?? []
        if reply.ok {
            items.append(URLQueryItem(name: "state", value: reply.state))
        } else {
            items.append(URLQueryItem(name: "errorMessage", value: reply.error ?? "Failed"))
        }
        components.queryItems = items
        return components.url
    }
}
