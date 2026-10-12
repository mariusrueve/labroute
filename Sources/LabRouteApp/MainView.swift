import SwiftUI
import LabRouteCore
import LabRouteServices

struct MainView: View {
    @ObservedObject var model: ApplicationModel
    /// Route edits are allowed while disconnected or connected, never mid-operation or during recovery.
    private var routesLocked: Bool { model.busy || (model.needsRecovery && !model.serving) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                Text("LabRoute").font(.largeTitle.bold())
            }
            Text(model.status).font(.headline).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Connect") { model.connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.serving || model.needsRecovery || model.configuredConnection == nil)
                Button("Disconnect") { model.restore() }.disabled(model.busy || (!model.serving && !model.needsRecovery))
                if model.busy { Button("Cancel") { model.cancelSetup() } }
            }
            if model.configuredConnection == nil {
                Text("Start with SSH setup below.").foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if model.needsRecovery && !model.serving {
                Text("A previous session was interrupted. Disconnect restores your proxy settings; Reconnect resumes it.").font(.callout)
                Button("Reconnect Recorded Session") { model.reconnectRecovery() }.disabled(model.busy)
            }
            Divider()

            Text("Routed domains").font(.headline)
            HStack {
                TextField("Domain or URL, e.g. intranet.uni-example.de", text: $model.domain)
                    .onSubmit { model.addRoute() }
                Picker("", selection: $model.destinationPack) {
                    Text("Custom").tag("custom")
                    Text("Internal").tag("internal")
                }.labelsHidden().frame(width: 100)
                Button("Add") { model.addRoute() }
            }.disabled(routesLocked)
            if model.serving {
                Text("Changes apply immediately. Reload the page, or restart the browser if it keeps the old route.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.packs) { pack in
                DisclosureGroup {
                    if pack.routes.isEmpty {
                        Text("No domains yet").font(.caption).foregroundStyle(.secondary).padding(.leading, 16)
                    }
                    ForEach(pack.routes) { route in
                        HStack {
                            Toggle(route.domain.value, isOn: Binding(get: { route.enabled }, set: {
                                model.setRoute(packID: pack.id, routeID: route.id, enabled: $0)
                            }))
                            if (!pack.enabled || !route.enabled) && RouteSet(packs: model.packs).matches(host: route.domain.value) {
                                Text("covered by another rule").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.leading, 16)
                    }
                } label: {
                    Toggle("\(pack.name) (\(pack.routes.filter(\.enabled).count)/\(pack.routes.count))", isOn: Binding(
                        get: { pack.enabled }, set: { model.setPack(pack.id, enabled: $0) }))
                        .font(.headline)
                }
            }.disabled(routesLocked)
            Divider()

            Text("Network services").font(.headline)
            ForEach(model.services) { service in
                Toggle(service.name + (service.isPrimary ? " (active)" : ""), isOn: Binding(
                    get: { model.selectedServices.contains(service.id) },
                    set: { model.selectService(service.id, enabled: $0) }
                )).disabled(model.busy || model.serving || model.needsRecovery)
            }
            Button("Refresh Network Services") { model.refreshServices() }
                .disabled(model.busy || model.needsRecovery)
            Divider()

            DisclosureGroup("SSH setup", isExpanded: $model.sshExpanded) {
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
                    }
                    Button("Set Up and Verify SSH") { model.setup() }
                }.disabled(model.busy || model.serving || model.needsRecovery || !model.ownsRuntime)
            }
            DisclosureGroup("Preferences") {
                Toggle("Connect automatically when LabRoute opens", isOn: Binding(get: { model.connectOnLaunch }, set: { model.setAutoConnect($0) }))
                Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
            DisclosureGroup("Diagnostics (this session only)") {
                ForEach(Array(model.events.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.caption).textSelection(.enabled)
                }
            }
            Text("Only the domains above go through SSH; everything else connects directly. Disconnect restores your previous proxy settings.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
}
