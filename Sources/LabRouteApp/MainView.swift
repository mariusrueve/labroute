import SwiftUI
import LabRouteCore
import LabRouteServices

enum MainTab: Hashable { case domains, terminal, connection, settings }

/// Status and connect controls stay fixed; daily use (domains) and one-time
/// setup (connection, terminal) live in separate tabs.
struct MainView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TabView(selection: $model.selectedTab) {
                tab { DomainsTab(model: model) }.tabItem { Text("Domains") }.tag(MainTab.domains)
                tab { TerminalSection(model: model) }.tabItem { Text("Terminal") }.tag(MainTab.terminal)
                tab { ConnectionTab(model: model) }.tabItem { Text("Connection") }.tag(MainTab.connection)
                tab { SettingsTab(model: model) }.tabItem { Text("Settings") }.tag(MainTab.settings)
            }
        }
        .padding(20)
        .textFieldStyle(.roundedBorder)
        .sheet(item: $model.credential) { question in
            VStack(alignment: .leading, spacing: 16) {
                Text(question.kind == .hostTrust ? "Verify Server Identity" : "SSH Authentication").font(.headline)
                Text(question.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if question.kind != .hostTrust {
                    SecureField("Secret", text: $model.credentialValue)
                }
                HStack {
                    Button("Cancel") { model.answerCredential(nil) }
                    Spacer()
                    Button(question.kind == .hostTrust ? "Trust This Host" : "Continue") {
                        model.answerCredential(question.kind == .hostTrust ? "yes" : model.credentialValue)
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 480).interactiveDismissDisabled()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                Text(model.status).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.busy { Button("Cancel") { model.cancelSetup() } }
                Button("Disconnect") { model.restore() }.disabled(model.busy || (!model.serving && !model.needsRecovery))
                Button("Connect") { model.connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.serving || model.needsRecovery || model.configuredConnection == nil)
            }
            if model.configuredConnection == nil {
                Text("Start with SSH setup under Connection.").foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if model.needsRecovery && !model.serving {
                HStack {
                    Text("A previous session was interrupted. Disconnect restores your proxy settings; Reconnect resumes it.").font(.callout)
                    Button("Reconnect Recorded Session") { model.reconnectRecovery() }.disabled(model.busy)
                }
            }
        }
    }

    /// Each tab scrolls on its own and keeps its content left-aligned.
    private func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content().frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
}

struct DomainsTab: View {
    @ObservedObject var model: ApplicationModel
    /// Route edits are allowed while disconnected or connected, never mid-operation or during recovery.
    private var routesLocked: Bool { model.busy || (model.needsRecovery && !model.serving) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Domain or URL, e.g. intranet.uni-example.de", text: $model.domain)
                    .onSubmit { model.addRoute() }
                Picker("", selection: $model.destinationPack) {
                    Text("Custom").tag("custom")
                    Text("Internal").tag("internal")
                }.labelsHidden().frame(width: 100)
                Button("Add") { model.addRoute() }
            }.disabled(routesLocked)
            Text(model.serving ? "Changes apply immediately. Reload the page, or restart the browser if it keeps the old route."
                 : "Only these domains go through SSH; everything else connects directly. A domain includes its subdomains.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(model.packs) { pack in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        if pack.routes.isEmpty {
                            Text("No domains yet").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(pack.routes) { route in
                            HStack {
                                Toggle(route.domain.value, isOn: Binding(get: { route.enabled }, set: {
                                    model.setRoute(packID: pack.id, routeID: route.id, enabled: $0)
                                }))
                                if (!pack.enabled || !route.enabled) && RouteSet(packs: model.packs).matches(host: route.domain.value) {
                                    Text("covered by another rule").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20).padding(.top, 4)
                } label: {
                    Toggle("\(pack.name) (\(pack.routes.filter(\.enabled).count)/\(pack.routes.count))", isOn: Binding(
                        get: { pack.enabled }, set: { model.setPack(pack.id, enabled: $0) }))
                        .font(.headline)
                }
            }.disabled(routesLocked)
        }
    }
}

struct ConnectionTab: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH server").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Institution name", text: $model.institution)
                TextField("SSH hostname", text: $model.hostname)
                TextField("SSH port", text: $model.sshPort)
                TextField("Username", text: $model.username)
                Text(model.keyPath.isEmpty ? "A dedicated encrypted key will be created." : "Key: \(model.keyPath)")
                    .font(.caption).textSelection(.enabled)
                HStack {
                    Button("Choose Existing Key…") { model.chooseKey() }
                    Button("Create Dedicated Key") { model.keyPath = "" }
                    Spacer()
                    Button("Set Up and Verify SSH") { model.setup() }
                }
            }.disabled(model.busy || model.serving || model.needsRecovery || !model.ownsRuntime)
            Divider()

            Text("Network services").font(.headline)
            Text("The browser proxy is set on the services you tick.").font(.caption).foregroundStyle(.secondary)
            ForEach(model.services) { service in
                Toggle(service.name + (service.isPrimary ? " (active)" : ""), isOn: Binding(
                    get: { model.selectedServices.contains(service.id) },
                    set: { model.selectService(service.id, enabled: $0) }
                )).disabled(model.busy || model.serving || model.needsRecovery)
            }
            Button("Refresh Network Services") { model.refreshServices() }
                .disabled(model.busy || model.needsRecovery)
        }
    }
}

struct SettingsTab: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preferences").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Connect automatically when LabRoute opens", isOn: Binding(get: { model.connectOnLaunch }, set: { model.setAutoConnect($0) }))
                Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
            Divider()
            Text("Diagnostics (this session only)").font(.headline)
            if model.events.isEmpty { Text("No events yet").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(model.events.enumerated()), id: \.offset) { item in
                Text(item.element).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }
}

/// ssh hosts, the jump-host fallback and the two lines that hook LabRoute into the terminal.
struct TerminalSection: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ssh, git and curl ignore the browser proxy. LabRoute writes ~/.ssh/labroute/config: hosts in a custom routed domain use the LabRoute tunnel while connected and the jump host otherwise.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            hook("~/.ssh/config", state: model.sshHookState, line: model.sshIncludeLine) { model.setSSHHook($0) }
            hook("~/.zshrc", state: model.shellHookState, line: model.shellHookLine) { model.setShellHook($0) }
            if !model.httpProxyStatus.isEmpty { Text(model.httpProxyStatus).font(.caption).foregroundStyle(.secondary) }
            if !model.sshConfigStatus.isEmpty {
                Text(model.sshConfigStatus).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Divider()

            Text("When LabRoute is disconnected").font(.subheadline.bold())
            Text(model.configuredConnection.map { "ssh jumps through the same server (\($0.username)@\($0.hostname):" + String($0.port) + ") using your own keys." }
                 ?? "Complete SSH setup under Connection first.")
                .fixedSize(horizontal: false, vertical: true)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Aliases for ssh, e.g. lab_tunnel", text: $model.gatewayAliasesText)
                TextField("Key for plain ssh (empty = your default keys)", text: $model.gatewayIdentity)
                Button("Choose…") { model.chooseIdentity(forGateway: true) }
                Button("Save") { model.saveGatewayDraft() }
            }
            Divider()

            HStack {
                Text("Hosts").font(.subheadline.bold())
                Spacer()
                Button("Add Host") { model.editHost(nil) }.disabled(model.editingHostID != nil)
            }
            ForEach(model.sshIntegration.hosts) { host in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(([host.hostname] + host.aliases).joined(separator: " · ")).textSelection(.enabled)
                        Text(model.sshHostRouted(host) ? "LabRoute tunnel when connected, jump host otherwise"
                             : "⚠ Not in a custom routed domain: add its domain above to route it")
                            .font(.caption).foregroundStyle(model.sshHostRouted(host) ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    Button("Edit") { model.editHost(host) }
                    Button("Remove") { model.removeSSHHost(host.id) }
                }
            }
            if model.editingHostID != nil { editor }
        }
        .disabled(model.busy || !model.ownsRuntime)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("HostName, e.g. gerrit.example.org", text: $model.draftHostname)
            TextField("Aliases, e.g. gerrit", text: $model.draftAliases)
            HStack {
                TextField("Port (default 22)", text: $model.draftPort).frame(width: 140)
                TextField("User", text: $model.draftUser)
            }
            HStack {
                TextField("Identity file (optional)", text: $model.draftIdentity)
                Button("Choose…") { model.chooseIdentity(forGateway: false) }
            }
            Toggle("Only use this identity (IdentitiesOnly)", isOn: $model.draftIdentitiesOnly)
            Text("Extra options, one per line, e.g. LocalForward 8080 localhost:80").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.draftExtra).font(.body.monospaced()).frame(height: 60)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("Cancel") { model.editingHostID = nil }
                Button("Save Host") { model.saveDraftHost() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(8).background(Color.secondary.opacity(0.08)).cornerRadius(6)
    }

    private func hook(_ file: String, state: HookState, line: String, set: @escaping (Bool) -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            switch state {
            case .installed: Text("✓ \(file) includes LabRoute").font(.callout)
            case .missing: Text("\(file) does not include LabRoute yet").font(.callout)
            case .misplaced: Text("⚠ In \(file) the line must come before any Host or Match block").font(.callout)
            case .symlink: Text("\(file) is a symlink: add this line yourself").font(.callout)
            }
            Spacer()
            if state == .installed { Button("Remove") { set(false) } }
            else if state != .symlink { Button(state == .misplaced ? "Move to Top" : "Add") { set(true) } }
        }
        .help(line)
        .contextMenu { Button("Copy Line") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(line, forType: .string) } }
    }
}
