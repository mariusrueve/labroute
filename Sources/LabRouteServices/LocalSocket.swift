import Foundation
import Darwin

public struct LocalPeer: Sendable {
    public let uid: uid_t
    public let pid: pid_t
    public var parentPID: pid_t? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }
    public var executable: String? {
        // The SDK's (4 * MAXPATHLEN) macro is not imported into Swift.
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

public enum LocalSocket {
    public static var directory: URL { URL(fileURLWithPath: "/tmp/labroute-\(getuid())", isDirectory: true) }
    public static var control: URL { directory.appendingPathComponent("control.sock") }
    public static func prepareDirectory(_ directory: URL = directory) throws {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw posixError() }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw RuntimeError.message("The local IPC directory is not private or has the wrong owner.")
        }
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw RuntimeError.message("Local socket path is too long.") }
        withUnsafeMutableBytes(of: &value.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        return value
    }
    static func configure(_ fd: Int32, seconds: Int = 120) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    static func peer(_ fd: Int32) throws -> LocalPeer {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var size = socklen_t(MemoryLayout.size(ofValue: pid))
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { throw RuntimeError.message("Local IPC peer is not authorized.") }
        return LocalPeer(uid: uid, pid: pid)
    }
    private static func wait(_ fd: Int32, event: Int16, deadline: ContinuousClock.Instant) throws {
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw RuntimeError.message("Local IPC frame deadline exceeded.") }
            let milliseconds = Double(remaining.components.seconds) * 1000 + Double(remaining.components.attoseconds) / 1e15
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, Int32(max(1, min(milliseconds.rounded(.up), Double(Int32.max)))))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw RuntimeError.message("Local IPC frame deadline exceeded.") }
            return
        }
    }
    static func receive(_ fd: Int32, timeout: Duration = .seconds(5)) throws -> Data {
        let deadline = ContinuousClock.now + timeout
        var output = Data()
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        while output.count <= 65536 {
            try wait(fd, event: Int16(POLLIN), deadline: deadline)
            var chunk = [UInt8](repeating: 0, count: min(4096, 65537 - output.count))
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { throw RuntimeError.message("Local IPC connection ended.") }
            if let end = chunk.prefix(count).firstIndex(of: 10) {
                guard end == count - 1 else { throw RuntimeError.message("Unexpected data after local IPC frame.") }
                output.append(contentsOf: chunk.prefix(end))
                guard output.count <= 65536 else { throw RuntimeError.message("Local IPC message is too large.") }
                return output
            }
            output.append(contentsOf: chunk.prefix(count))
        }
        throw RuntimeError.message("Local IPC message is too large.")
    }
    static func send(_ data: Data, to fd: Int32) throws {
        guard data.count <= 65536, !data.contains(10) else { throw RuntimeError.message("Invalid local IPC frame.") }
        let deadline = ContinuousClock.now + .seconds(5)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let framed = data + Data([10])
        try framed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd, event: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
    }
    public static func request(_ data: Data, at url: URL = control, timeoutSeconds: Int = 120) throws -> Data {
        try prepareDirectory(url.deletingLastPathComponent())
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        configure(fd, seconds: max(1, min(timeoutSeconds, 120)))
        var address = try address(url.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw RuntimeError.message("LabRoute is not running or its local service is unavailable.") }
        _ = try peer(fd)
        try send(data, to: fd)
        return try receive(fd, timeout: .seconds(max(1, min(timeoutSeconds, 120))))
    }
    static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// Bounded same-user IPC. The lock prevents two application owners and stale-socket races.
public final class LocalServer: @unchecked Sendable {
    private let fd: Int32, lockFD: Int32
    private let path: String
    private let state = NSLock()
    private var stopped = false
    private var activeClients = 0
    private var listenerClosed = false
    public init(url: URL, delivered: @escaping @Sendable (Data, LocalPeer) async -> Void = { _, _ in }, handler: @escaping @Sendable (Data, LocalPeer) async -> Data) throws {
        try LocalSocket.prepareDirectory(url.deletingLastPathComponent())
        path = url.path
        lockFD = Darwin.open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw LocalSocket.posixError() }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD); throw RuntimeError.message("Another LabRoute instance is already running.")
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { Darwin.close(lockFD); throw LocalSocket.posixError() }
        unlink(path)
        do {
            var address = try LocalSocket.address(path)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { throw LocalSocket.posixError() }
        } catch { Darwin.close(fd); Darwin.close(lockFD); throw error }
        DispatchQueue(label: "org.labroute.socket", qos: .utility).async { [self] in
            let slots = DispatchSemaphore(value: 4)
            defer { Darwin.close(fd); unlink(path); flock(lockFD, LOCK_UN); Darwin.close(lockFD); markListenerClosed() }
            while !isStopped {
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 200) > 0 else { continue }
                if isStopped { break }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                guard slots.wait(timeout: .now()) == .success else { Darwin.close(client); continue }
                addClient()
                LocalSocket.configure(client, seconds: 5)
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let peer = try LocalSocket.peer(client)
                        let input = try LocalSocket.receive(client)
                        Task {
                            let response = await handler(input, peer)
                            let sent = (try? LocalSocket.send(response, to: client)) != nil
                            Darwin.close(client); slots.signal(); self.removeClient()
                            if sent { await delivered(response, peer) }
                        }
                    } catch { Darwin.close(client); slots.signal(); self.removeClient() }
                }
            }
        }
    }
    private func addClient() { state.lock(); activeClients += 1; state.unlock() }
    private func removeClient() { state.lock(); activeClients -= 1; state.unlock() }
    private func markListenerClosed() { state.lock(); listenerClosed = true; state.unlock() }
    private var drained: Bool { state.lock(); defer { state.unlock() }; return listenerClosed && activeClients == 0 }
    public func stopAndDrain(timeout: Duration) async {
        stop()
        let deadline = ContinuousClock.now + timeout
        while !drained && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
    private var isStopped: Bool { state.lock(); defer { state.unlock() }; return stopped }
    public func stop() { state.lock(); stopped = true; state.unlock() }
}
