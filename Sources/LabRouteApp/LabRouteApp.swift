import SwiftUI
import LabRouteCore
import LabRouteServices

@main
struct LabRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ApplicationModel()
    var body: some Scene {
        MenuBarExtra {
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
        } label: {
            Image(nsImage: MenuBarIcon.image(for: menuState))
        }
        Window("LabRoute", id: "main") {
            MainView(model: model)
                .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 720)
        }
        .defaultSize(width: 640, height: 720)
        .windowResizability(.contentMinSize)
        // Returning users run in the menu bar. Fresh setup, recovery and fixture demos open the window.
        .defaultLaunchBehavior(CommandLine.arguments.contains("--non-interactive") ||
                              (model.configuredConnection != nil && !model.needsRecovery && !CommandLine.arguments.contains("--fixture")) ? .suppressed : .presented)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Disconnect and Quit LabRoute") { model.quit() }
                    .keyboardShortcut("q").disabled(model.busy)
            }
        }
    }

    private var menuState: MenuBarIcon.State {
        if model.busy { return .connecting }
        if model.routingState == .active { return .connected }
        if model.routingState == .degraded || model.needsRecovery || model.error != nil { return .attention }
        return .disconnected
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

/// Monochrome template images in the style of the system menu bar: one route glyph
/// that fills in when connected and dims while connecting.
enum MenuBarIcon {
    enum State { case disconnected, connecting, connected, attention }

    static func image(for state: State) -> NSImage {
        let (name, alpha, label): (String, CGFloat, String) = switch state {
        case .disconnected: ("point.bottomleft.forward.to.point.topright.scurvepath", 1, "LabRoute, disconnected")
        case .connecting: ("point.bottomleft.forward.to.point.topright.scurvepath", 0.4, "LabRoute, connecting")
        case .connected: ("point.bottomleft.forward.to.point.topright.scurvepath.fill", 1, "LabRoute, connected")
        case .attention: ("exclamationmark.triangle", 1, "LabRoute, needs attention")
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(configuration) else {
            return NSImage()
        }
        let image = alpha < 1 ? NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha); return true
        } : symbol
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }
}

/// Routes every quit (menu, ⌘Q, logout, `brew uninstall`, Activity Monitor's Quit)
/// through Disconnect, so proxy settings are restored before the process exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppTermination.request()
    }
}

@MainActor enum AppTermination {
    static weak var model: ApplicationModel?
    private static var awaitingReply = false

    static func request() -> NSApplication.TerminateReply {
        guard let model, model.ownsRuntime, !model.isShuttingDown, !awaitingReply else { return .terminateNow }
        awaitingReply = true
        Task { @MainActor in
            if model.busy {
                model.cancelSetup()
                for _ in 0..<100 where model.busy { try? await Task.sleep(for: .milliseconds(100)) }
            }
            if !model.execute(ControlRequest(.quit)).success { finish(allowed: false) }
        }
        return .terminateLater
    }

    /// Called by the controller once Disconnect finished (or failed).
    static func finish(allowed: Bool) {
        if awaitingReply {
            awaitingReply = false
            NSApp.reply(toApplicationShouldTerminate: allowed)
        } else if allowed {
            NSApp.terminate(nil)
        }
    }
}
