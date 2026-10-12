import Foundation
import LabRouteServices

// stdout is OpenSSH's private response pipe. Never write prompts or diagnostics there.
do {
    guard let path = ProcessInfo.processInfo.environment["LABROUTE_ASKPASS_SOCKET"],
          CommandLine.arguments.count == 2 else { exit(1) }
    let request = try JSONEncoder().encode(CommandLine.arguments[1])
    let data = try LocalSocket.request(request, at: URL(fileURLWithPath: path))
    let response = try JSONDecoder().decode(CredentialReply.self, from: data)
    guard let value = response.value, !value.contains("\n"), !value.contains("\r") else { exit(1) }
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
} catch { exit(1) }
