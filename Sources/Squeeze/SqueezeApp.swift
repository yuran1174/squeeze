import AppKit
import SwiftUI

@main
struct SqueezeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(AppModel.shared)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("Squeeze", id: "programs") {
            MainView().environmentObject(AppModel.shared)
        }
        .defaultSize(width: 860, height: 560)
    }
}

/// The menu bar icon. It exists for the whole life of the app, so it is where `openWindow` is captured.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "rectangle.compress.vertical")
            .onAppear {
                let open = openWindow
                AppModel.shared.openMainWindow = {
                    open(id: "programs")
                    NSApp.activate(ignoringOtherApps: true)
                }
                // open the window when the user starts Squeeze, not when it starts at login
                if !AppDelegate.launchedAtLogin {
                    DispatchQueue.main.async { AppModel.shared.openMainWindow?() }
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // login items are launched with keyAELaunchedAsLogInItem in the open-application event
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            AppDelegate.launchedAtLogin = true
        }
    }

    /// Squeeze opened again from Finder or Launchpad while it runs: show the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in AppModel.shared.openMainWindow?() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
