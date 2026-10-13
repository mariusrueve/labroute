import Foundation
import Darwin
import LabRouteCore

/// Small blocking-with-deadline TCP helpers shared by `labroute proxy` and the
/// split HTTP proxy. Nothing here logs hosts or payloads.
public enum TCPConnector {
    /// Delay before racing the next address, as in Happy Eyeballs (RFC 8305).
    static let attemptDelay: Duration = .milliseconds(250)

    /// Connects to `host`, starting one attempt per address 250 ms apart and
    /// keeping the first that succeeds. An unreachable IPv6 route therefore
    /// costs 250 ms instead of the whole timeout.
    public static func connect(host: String, port: UInt16, timeout: Duration) throws -> Int32 {
        let deadline = ContinuousClock.now + timeout
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0, let first = list else { throw RuntimeError.message("Could not resolve the host.") }
        defer { freeaddrinfo(first) }
        var addresses: [UnsafeMutablePointer<addrinfo>] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current { addresses.append(info); current = info.pointee.ai_next }

        var lastError: Error = RuntimeError.message("Could not connect to the host.")
        var pending: [Int32] = []
        defer { pending.forEach { Darwin.close($0) } }
        var next = 0
        var nextStart = ContinuousClock.now
        while true {
            let now = ContinuousClock.now
            guard now < deadline else { throw RuntimeError.message("Connection timed out.") }
            if next < addresses.count && now >= nextStart {
                let info = addresses[next].pointee
                next += 1; nextStart = now + attemptDelay
                let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
                if fd < 0 { lastError = LocalSocket.posixError(); nextStart = now; continue }
                SocketIO.prepare(fd)
                if Darwin.connect(fd, info.ai_addr, info.ai_addrlen) == 0 { return fd }
                if errno == EINPROGRESS { pending.append(fd) } else { lastError = LocalSocket.posixError(); Darwin.close(fd); nextStart = now; continue }
            }
            if pending.isEmpty {
                if next >= addresses.count { throw lastError }
                nextStart = now; continue
            }
            let wakeAt = next < addresses.count ? min(nextStart, deadline) : deadline
            let remaining = wakeAt - ContinuousClock.now
            let milliseconds = max(1, Int32(min(Double(remaining.components.seconds) * 1000 + Double(remaining.components.attoseconds) / 1e15 + 1, 600_000)))
            var descriptors = pending.map { pollfd(fd: $0, events: Int16(POLLOUT), revents: 0) }
            let result = poll(&descriptors, nfds_t(descriptors.count), milliseconds)
            if result < 0 && errno != EINTR { throw LocalSocket.posixError() }
            guard result > 0 else { continue }
            for descriptor in descriptors where descriptor.revents != 0 {
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                pending.removeAll { $0 == descriptor.fd }
                if getsockopt(descriptor.fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0 { return descriptor.fd }
                lastError = POSIXError(POSIXErrorCode(rawValue: error) ?? .ECONNREFUSED)
                Darwin.close(descriptor.fd)
                nextStart = ContinuousClock.now  // a failed attempt starts the next one at once
            }
        }
    }
}

public enum SOCKS5Client {
    /// Opens `host:port` through the loopback SOCKS5 listener of `ssh -D`.
    /// Returns the connected socket and any bytes that arrived after the reply.
    public static func open(socksPort: UInt16, host: String, port: UInt16, timeout: Duration = .seconds(10)) throws -> (fd: Int32, leftover: [UInt8]) {
        let request = try SOCKS5.connectRequest(host: host, port: port)
        let deadline = ContinuousClock.now + timeout
        let fd = try TCPConnector.connect(host: "127.0.0.1", port: socksPort, timeout: timeout)
        do {
            try SocketIO.writeAll(fd, SOCKS5.greeting, deadline: deadline)
            var buffer: [UInt8] = []
            while true {
                switch SOCKS5.parseGreeting(buffer) {
                case .needMore: buffer += try SocketIO.readSome(fd, deadline: deadline)
                case .rejected: throw SOCKS5Error.rejected
                case .accepted: break
                }
                if SOCKS5.parseGreeting(buffer) == .accepted { break }
            }
            buffer.removeFirst(2)
            try SocketIO.writeAll(fd, request, deadline: deadline)
            while true {
                switch SOCKS5.parseReply(buffer) {
                case .needMore: buffer += try SocketIO.readSome(fd, deadline: deadline)
                case .failure(let code): throw SOCKS5Error.failed(code)
                case .success(let length): return (fd, Array(buffer.dropFirst(length)))
                }
            }
        } catch { Darwin.close(fd); throw error }
    }
}

public enum SocketIO {
    static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    static func wait(_ fd: Int32, event: Int16, deadline: ContinuousClock.Instant) throws {
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw RuntimeError.message("Connection timed out.") }
            let milliseconds = Int32(min(Double(remaining.components.seconds) * 1000 + Double(remaining.components.attoseconds) / 1e15 + 1, 600_000))
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw RuntimeError.message("Connection timed out.") }
            return
        }
    }
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8], deadline: ContinuousClock.Instant) throws {
        var offset = 0
        while offset < bytes.count {
            try wait(fd, event: Int16(POLLOUT), deadline: deadline)
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { throw LocalSocket.posixError() }
            offset += count
        }
    }
    /// Returns at least one byte, or throws on EOF, error or deadline.
    public static func readSome(_ fd: Int32, max: Int = 4096, deadline: ContinuousClock.Instant) throws -> [UInt8] {
        var chunk = [UInt8](repeating: 0, count: max)
        while true {
            try wait(fd, event: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { throw RuntimeError.message("Connection closed.") }
            return Array(chunk.prefix(count))
        }
    }
}

/// Copies bytes in both directions until both have ended. End of input on one
/// side half-closes the other, so protocols like ssh and git see a clean EOF.
public enum StreamRelay {
    public struct Endpoint: Sendable {
        public let read: Int32, write: Int32
        public init(read: Int32, write: Int32) { self.read = read; self.write = write }
        public init(socket: Int32) { read = socket; write = socket }
    }
    private struct Direction {
        let from: Int32, to: Int32
        var buffer: [UInt8]
        var offset = 0
        var readOpen = true
        var done = false
        var pending: Bool { offset < buffer.count }
    }

    public static func run(_ a: Endpoint, _ b: Endpoint, initialToB: [UInt8] = [], initialToA: [UInt8] = []) {
        for fd in Set([a.read, a.write, b.read, b.write]) { SocketIO.prepare(fd) }
        var directions = [Direction(from: a.read, to: b.write, buffer: initialToB), Direction(from: b.read, to: a.write, buffer: initialToA)]
        var chunk = [UInt8](repeating: 0, count: 65536)
        while directions.contains(where: { !$0.done }) {
            var descriptors: [pollfd] = []
            var owners: [(Int, Bool)] = []  // (direction, isWrite)
            for index in directions.indices where !directions[index].done {
                if directions[index].pending {
                    descriptors.append(pollfd(fd: directions[index].to, events: Int16(POLLOUT), revents: 0)); owners.append((index, true))
                } else if directions[index].readOpen {
                    descriptors.append(pollfd(fd: directions[index].from, events: Int16(POLLIN), revents: 0)); owners.append((index, false))
                } else {
                    halfClose(directions[index].to); directions[index].done = true
                }
            }
            guard !descriptors.isEmpty else { continue }
            let result = poll(&descriptors, nfds_t(descriptors.count), -1)
            if result < 0 { if errno == EINTR { continue }; return }
            for (slot, owner) in owners.enumerated() where descriptors[slot].revents != 0 {
                let index = owner.0
                if owner.1 {
                    let count = directions[index].buffer.withUnsafeBytes {
                        Darwin.write(directions[index].to, $0.baseAddress!.advanced(by: directions[index].offset), directions[index].buffer.count - directions[index].offset)
                    }
                    if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                    // The receiver is gone: nothing more can be delivered either way.
                    guard count > 0 else { return }
                    directions[index].offset += count
                    if !directions[index].pending { directions[index].buffer.removeAll(keepingCapacity: true); directions[index].offset = 0 }
                } else {
                    let count = Darwin.read(directions[index].from, &chunk, chunk.count)
                    if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                    if count <= 0 { directions[index].readOpen = false; continue }
                    directions[index].buffer = Array(chunk.prefix(count)); directions[index].offset = 0
                }
            }
        }
    }

    private static func halfClose(_ fd: Int32) {
        var info = stat()
        if fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK { shutdown(fd, SHUT_WR) } else { Darwin.close(fd) }
    }
}
