import CoreGraphics
import Foundation

/// A command to the running app, from the `takely` CLI, the `takely://` URL scheme or App Intents.
public struct ControlRequest: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable, CaseIterable {
        case start, stop, pause, resume, marker, retake, discard, status
    }

    public var command: Command
    /// `start`: false skips the 3-2-1 countdown (nil: the user's setting).
    public var countdown: Bool?
    /// `start`: record this area (global points, origin top-left) instead of the chosen display.
    public var region: [Double]?

    public init(_ command: Command, countdown: Bool? = nil, region: CGRect? = nil) {
        self.command = command
        self.countdown = countdown
        self.region = region.map { [$0.minX, $0.minY, $0.width, $0.height] }
    }

    public var regionRect: CGRect? {
        guard let r = region, r.count == 4, r[2] > 0, r[3] > 0 else { return nil }
        return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
    }
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

    public init(ok: Bool, state: String, path: String? = nil, duration: Double? = nil, title: String? = nil, error: String? = nil) {
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
/// opens `x-success` with `path` (and `duration`) added; on failure `x-error` with `errorMessage`.
public struct ControlURL: Sendable, Equatable {
    public var request: ControlRequest
    public var success: URL?
    public var failure: URL?

    public init?(_ url: URL) {
        guard url.scheme == "takely", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // takely://record/start, takely://record/stop … and takely://status.
        let parts = ([url.host() ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        let name = parts.first == "record" ? parts.dropFirst().first : parts.first
        guard let name, let command = ControlRequest.Command(rawValue: name) else { return nil }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        var request = ControlRequest(command)
        if let countdown = query["countdown"] { request.countdown = !["0", "false", "no", "off"].contains(countdown.lowercased()) }
        if let region = query["region"] {
            let numbers = region.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if numbers.count == 4 { request.region = numbers }
        }
        self.request = request
        success = query["x-success"].flatMap(URL.init(string:))
        failure = query["x-error"].flatMap(URL.init(string:))
    }

    /// The callback to open for `reply`, if one was given.
    public func callback(for reply: ControlReply) -> URL? {
        guard let base = reply.ok ? success : failure, var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        var items = components.queryItems ?? []
        if reply.ok {
            if let path = reply.path { items.append(URLQueryItem(name: "path", value: path)) }
            if let duration = reply.duration { items.append(URLQueryItem(name: "duration", value: String(format: "%.1f", duration))) }
            items.append(URLQueryItem(name: "state", value: reply.state))
        } else {
            items.append(URLQueryItem(name: "errorMessage", value: reply.error ?? "Failed"))
        }
        components.queryItems = items
        return components.url
    }
}
