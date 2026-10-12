import SwiftUI
import LabRouteServices

@MainActor
final class ApplicationModel: ApplicationController {
    private var powerObservers: [NSObjectProtocol] = []
    @Published var sshExpanded = false
    override init(environment: ControllerEnvironment = .live(), startIPC: Bool = true) {
        var selected = environment
        if CommandLine.arguments.contains("--non-interactive") {
            selected.forceNonInteractive = true; selected.allowsAutomaticConnection = false; selected.onboardingAllowed = false
        }
        if let index = CommandLine.arguments.firstIndex(of: "--fixture") {
            #if DEBUG
            guard index + 1 < CommandLine.arguments.count,
                  let fixture = try? FixtureEnvironment(id: CommandLine.arguments[index + 1]) else { fatalError("Invalid fixture ID") }
            selected = fixture.environment()
            #else
            fatalError("Fixture mode is unavailable in release builds")
            #endif
        }
        super.init(environment: selected, startIPC: startIPC)
        sshExpanded = configuredConnection == nil
        guard ownsRuntime else { Task { NSApp.terminate(nil) }; return }
        terminate = { NSApp.terminate(nil) }
        powerObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleSleep() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleWake() }
            }
        ]
    }
    func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose an existing private key. LabRoute will not modify it."
        if panel.runModal() == .OK { keyPath = panel.url?.path ?? "" }
    }
}
