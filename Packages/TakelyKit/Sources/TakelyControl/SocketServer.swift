import Foundation
import OSLog
import Synchronization

/// Serves `ControlRequest`s on a Unix domain socket: one JSON request line in, one JSON reply line out, per
/// connection. The folder is 0700 and the socket 0600, and each peer's user is checked, so only this user can send
/// commands. Started and stopped on the main actor.
public final class SocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlReply

    private let path: String
    private let handler: Handler
    private let state = Mutex<(listener: Int32, stopped: Bool, inode: ino_t)>((-1, false, 0))
    /// Clients still sending their request: more than `maxReading` at once are turned away, so a few slow ones can't
    /// tie up the system's threads.
    private let reading = Mutex(0)
    static let maxReading = 4
    private let log = Logger(subsystem: "app.takely", category: "control")
    /// A client gets this long to send its request (and to take its reply): a silent one can't hold the server.
    static let timeout = timeval(tv_sec: 5, tv_usec: 0)

    public init(path: String = ControlSocket.defaultPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// Starts listening. A stale socket file (left by a crash) is replaced; a live one (another running Takely) isn't.
    public func start() throws {
        signal(SIGPIPE, SIG_IGN)  // a client hanging up mid-reply is an error return, not a crash (usual for servers)
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR,
            info.st_mode & 0o077 == 0 || chmod(folder, 0o700) == 0
        else {
            throw SocketError.unsafeFolder(folder)
        }
        if (try? SocketClient.connect(path)).map({ close($0) }) != nil { throw SocketError.alreadyServing }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var address = try Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, fchmodat(AT_FDCWD, path, 0o600, AT_SYMLINK_NOFOLLOW) == 0, listen(fd, 8) == 0, lstat(path, &info) == 0 else {
            let error = errno
            close(fd)
            throw SocketError.system("bind", error)
        }
        state.withLock { $0 = (fd, false, info.st_ino) }
        let thread = Thread { self.acceptLoop(fd) }
        thread.name = "Takely control socket"
        thread.start()
    }

    /// Stops listening and removes the socket file, if it's still ours.
    public func stop() {
        let (fd, inode) = state.withLock { state -> (Int32, ino_t) in
            defer { state = (-1, true, 0) }
            return (state.listener, state.inode)
        }
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        var info = stat()
        if lstat(path, &info) == 0, info.st_ino == inode { unlink(path) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let connection = accept(fd, nil, nil)
            if state.withLock({ $0.stopped }) {
                if connection >= 0 { close(connection) }
                return
            }
            guard connection >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            var peer: uid_t = 0
            var group: gid_t = 0
            guard getpeereid(connection, &peer, &group) == 0, peer == getuid() else {
                close(connection)
                continue
            }
            var on: Int32 = 1
            var timeout = Self.timeout
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            // Each client is read on its own queue (bounded by the timeout): a silent one delays only itself, and
            // blocking reads never sit on the async thread pool.
            let handler = handler
            let log = log
            let admitted = reading.withLock { count in
                guard count < Self.maxReading else { return false }
                count += 1
                return true
            }
            guard admitted else {
                close(connection)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let line = LineIO.readLine(connection, deadline: .now + .seconds(Int(Self.timeout.tv_sec)))
                self.reading.withLock { $0 -= 1 }
                guard let line else {
                    close(connection)  // hung up or said nothing (e.g. another instance checking the socket is live)
                    return
                }
                Task.detached {
                    defer { close(connection) }
                    let reply: ControlReply
                    if let request = try? JSONDecoder().decode(ControlRequest.self, from: line) {
                        reply = await handler(request)
                    } else {
                        reply = ControlReply(ok: false, state: "unknown", error: "Couldn't read the request")
                        log.error("bad control request")
                    }
                    if let data = try? JSONEncoder().encode(reply) { LineIO.write(data, to: connection) }
                }
            }
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }
}

/// Sends one request to the app and waits for its reply (a `stop` waits for the export).
public enum SocketClient {
    public static func send(_ request: ControlRequest, path: String = ControlSocket.defaultPath) throws -> ControlReply {
        let fd = try connect(path)
        defer { close(fd) }
        LineIO.write(try JSONEncoder().encode(request), to: fd)
        guard let line = LineIO.readLine(fd) else { throw SocketError.noReply }
        return try JSONDecoder().decode(ControlReply.self, from: line)
    }

    /// A connected socket; `notRunning` when nothing listens there, `noAccess` when the socket isn't ours to use.
    static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = try SocketServer.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let error = errno
            close(fd)
            throw error == EACCES || error == EPERM ? SocketError.noAccess : SocketError.notRunning
        }
        return fd
    }
}

public enum SocketError: Error, LocalizedError, Equatable {
    case notRunning
    case noReply
    case noAccess
    case alreadyServing
    case unsafeFolder(String)
    case pathTooLong(String)
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Takely isn't running."
        case .noReply: "Takely didn't answer."
        case .noAccess: "Not allowed to talk to Takely (the control socket belongs to another user)."
        case .alreadyServing: "Another Takely is already listening for commands."
        case .unsafeFolder(let folder): "Takely's folder isn't private to you: \(folder)"
        case .pathTooLong(let path): "Socket path too long: \(path)"
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Newline-framed messages over a blocking socket.
enum LineIO {
    /// Up to the first newline (or the end); nil if nothing arrived. Requests and replies are small. `deadline` bounds
    /// the whole line (the socket's timeout bounds each read, so a byte-at-a-time sender is cut off here).
    static func readLine(_ fd: Int32, limit: Int = 1 << 20, deadline: ContinuousClock.Instant? = nil) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < limit {
            if let deadline, ContinuousClock.now >= deadline { return nil }
            let n = read(fd, &byte, 1)
            if n < 0, errno == EINTR { continue }
            if n <= 0 || byte == UInt8(ascii: "\n") { break }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
    }

    static func write(_ data: Data, to fd: Int32) {
        var message = data
        message.append(UInt8(ascii: "\n"))
        message.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return }
                offset += n
            }
        }
    }
}
