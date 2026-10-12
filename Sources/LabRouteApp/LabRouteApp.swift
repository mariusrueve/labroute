import SwiftUI
import LabRouteCore
import LabRouteServices

@main
struct LabRouteApp: App {
    @StateObject private var model = ApplicationModel()
    var body: some Scene {
        MenuBarExtra("LabRoute", systemImage: menuIcon) {
            Text(model.status)
            if let error = model.error { Text(error).lineLimit(3) }
            Divider()
            Button("Connect") { model.connect() }
                .disabled(model.busy || model.serving || model.needsRecovery || model.configuredConnection == nil)
            Button("Disconnect") { model.restore() }.disabled(model.busy || (!model.serving && !model.needsRecovery))
            if model.needsRecovery && !model.serving {
                Button("Restore Proxy Settings") { model.restore() }.disabled(model.busy)
            }
            Divider()
            OpenWindowButton()
            Button("Disconnect and Quit") { model.quit() }.disabled(model.busy)
        }
        Window("LabRoute", id: "main") {
            ScrollView { MainView(model: model).padding(24) }
                .frame(width: 560, height: 680)
        }
        .windowResizability(.contentSize)
        // Returning users run in the menu bar. Fresh setup and recovery open the window.
        .defaultLaunchBehavior(CommandLine.arguments.contains("--non-interactive") ||
                              (model.configuredConnection != nil && !model.needsRecovery) ? .suppressed : .presented)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Disconnect and Quit LabRoute") { model.quit() }
                    .keyboardShortcut("q").disabled(model.busy)
            }
        }
    }

    private var menuIcon: String {
        if model.routingState == .active { return "network.badge.shield.half.filled" }
        if model.busy { return "arrow.triangle.2.circlepath" }
        if model.routingState == .degraded || model.needsRecovery || model.error != nil { return "exclamationmark.triangle" }
        return "network"
    }
}

private struct OpenWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open LabRoute…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
