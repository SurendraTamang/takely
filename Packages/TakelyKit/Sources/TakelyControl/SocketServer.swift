import Foundation
import OSLog

/// Serves `ControlRequest`s on a Unix domain socket: one JSON request line in, one JSON reply line out, per
/// connection. The socket file is mode 0600, so only this user can send commands.
public final class SocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlReply

    private let path: String
    private let handler: Handler
    private var listener: Int32 = -1
    private let log = Logger(subsystem: "app.takely", category: "control")

    public init(path: String = ControlSocket.defaultPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// Starts listening (replacing a stale socket file left by a crash).
    public func start() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var address = try Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            let error = errno
            close(fd)
            throw SocketError.system("bind", error)
        }
        listener = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "Takely control socket"
        thread.start()
    }

    public func stop() {
        guard listener >= 0 else { return }
        shutdown(listener, SHUT_RDWR)
        close(listener)
        listener = -1
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                return  // closed by stop()
            }
            var noSigPipe: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let handler = handler
            let log = log
            Task.detached {
                defer { close(connection) }
                guard let line = LineIO.readLine(connection) else { return }
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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = try SocketServer.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw SocketError.notRunning }
        LineIO.write(try JSONEncoder().encode(request), to: fd)
        guard let line = LineIO.readLine(fd) else { throw SocketError.noReply }
        return try JSONDecoder().decode(ControlReply.self, from: line)
    }
}

public enum SocketError: Error, LocalizedError, Equatable {
    case notRunning
    case noReply
    case pathTooLong(String)
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Takely isn't running."
        case .noReply: "Takely didn't answer."
        case .pathTooLong(let path): "Socket path too long: \(path)"
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Newline-framed messages over a blocking socket.
enum LineIO {
    /// Up to the first newline (or the end); nil if nothing arrived. Requests and replies are small.
    static func readLine(_ fd: Int32, limit: Int = 1 << 20) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < limit {
            let n = read(fd, &byte, 1)
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
                if n <= 0 { return }
                offset += n
            }
        }
    }
}
