import SwiftUI
import LabRouteCore
import LabRouteServices

@MainActor
final class ApplicationModel: ApplicationController {
    private var powerObservers: [NSObjectProtocol] = []
    @Published var selectedTab: MainTab = .domains
    // Host editor drafts. Command Line Tools builds have no @State, so form state lives here.
    @Published var editingHostID: UUID?
    @Published var draftAliases = ""
    @Published var draftHostname = ""
    @Published var draftPort = ""
    @Published var draftUser = ""
    @Published var draftIdentity = ""
    @Published var draftIdentitiesOnly = false
    @Published var draftExtra = ""
    @Published var gatewayAliasesText = ""
    @Published var gatewayIdentity = ""
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
        if configuredConnection == nil { selectedTab = .connection }
        gatewayAliasesText = sshIntegration.gateway.aliases.joined(separator: " ")
        gatewayIdentity = sshIntegration.gateway.identityFile ?? ""
        #if DEBUG
        // Development aid for README screenshots: the app renders its own window,
        // which needs no Screen Recording permission.
        // --snapshot-tabs <directory>: renders every tab offscreen, independent of window state.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-tabs"), index + 1 < CommandLine.arguments.count {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                for (name, tab) in [("domains", MainTab.domains), ("terminal", .terminal), ("connection", .connection), ("settings", .settings)] {
                    self?.selectedTab = tab
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.snapshotOffscreen(to: directory.appendingPathComponent(name + ".png"))
                }
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                self?.snapshotWindow(to: URL(fileURLWithPath: path))
            }
        }
        #endif
        guard ownsRuntime else { Task { NSApp.terminate(nil) }; return }
        terminate = { AppTermination.finish(allowed: true) }
        quitFailed = { AppTermination.finish(allowed: false) }
        AppTermination.model = self
        powerObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleSleep() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleWake() }
            }
        ]
    }
    #if DEBUG
    private func snapshotWindow(to url: URL) {
        guard let frame = NSApp.windows.first(where: { $0.isVisible && $0.title == "LabRoute" })?.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    private func snapshotOffscreen(to url: URL) {
        let view = NSHostingView(rootView: MainView(model: self).frame(width: 640, height: 720)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.frame.size = CGSize(width: 640, height: 720)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif

    func editHost(_ host: SSHHostEntry?) {
        let host = host ?? SSHHostEntry(aliases: [], hostname: "", user: configuredConnection?.username)
        editingHostID = host.id
        draftAliases = host.aliases.joined(separator: " "); draftHostname = host.hostname
        draftPort = host.port.map(String.init) ?? ""; draftUser = host.user ?? ""
        draftIdentity = host.identityFile ?? ""; draftIdentitiesOnly = host.identitiesOnly
        draftExtra = host.extraOptions.joined(separator: "\n")
    }

    func saveDraftHost() {
        guard let id = editingHostID else { return }
        let port = draftPort.trimmingCharacters(in: .whitespaces)
        guard port.isEmpty || UInt16(port).map({ $0 > 0 }) == true else { error = "Port must be 1–65535."; return }
        let host = SSHHostEntry(id: id, aliases: words(draftAliases), hostname: draftHostname.trimmingCharacters(in: .whitespaces).lowercased(),
            port: port.isEmpty ? nil : UInt16(port), user: optional(draftUser), identityFile: optional(draftIdentity),
            identitiesOnly: draftIdentitiesOnly,
            extraOptions: draftExtra.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        if saveSSHHost(host) { editingHostID = nil }
    }

    func saveGatewayDraft() {
        saveSSHGateway(SSHGateway(aliases: words(gatewayAliasesText), identityFile: optional(gatewayIdentity)))
    }

    /// Picks a private key and stores it home-relative, so the config stays readable.
    func chooseIdentity(forGateway: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "Choose the private key ssh should use. LabRoute only references it."
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let display = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        if forGateway { gatewayIdentity = display } else { draftIdentity = display }
    }

    private func words(_ text: String) -> [String] { text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) }
    private func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose an existing private key. LabRoute will not modify it."
        if panel.runModal() == .OK { keyPath = panel.url?.path ?? "" }
    }
}
