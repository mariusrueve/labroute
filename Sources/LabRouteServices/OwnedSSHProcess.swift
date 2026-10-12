import Foundation
import Darwin

/// PID alone is insufficient after a crash: include kernel start time and user.
public struct OwnedSSHProcess: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64
    public static func capture(_ pid: Int32) -> OwnedSSHProcess? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_uid == getuid(), LocalPeer(uid: getuid(), pid: pid).executable == "/usr/bin/ssh" else { return nil }
        return OwnedSSHProcess(pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }
    public func stopIfStillOwned() async throws {
        guard Self.capture(pid) == self else { return }
        guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { throw LocalSocket.posixError() }
        let deadline = ContinuousClock.now + .seconds(5)
        let killAfter = ContinuousClock.now + .seconds(1)
        var killed = false
        while ContinuousClock.now < deadline {
            if Self.capture(pid) != self { return }
            if !killed && ContinuousClock.now >= killAfter {
                guard Self.capture(pid) == self else { return }
                _ = kill(pid, SIGKILL); killed = true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Never kill another process if this PID was reused during the wait.
        if Self.capture(pid) == self { throw RuntimeError.message("The recorded SSH process has not exited. Retry recovery after it stops.") }
    }
}
