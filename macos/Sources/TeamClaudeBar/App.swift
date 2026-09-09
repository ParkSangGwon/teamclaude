import AppKit
import SwiftUI
import TeamClaudeCore

@main
struct TeamClaudeBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock icon, no main window. Set here too so `swift run` behaves like the bundle.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppStore!
    private var statusItem: StatusItemController!
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = AppStore()
        statusItem = StatusItemController(store: store, openSettings: { [weak self] in self?.showSettings() })
        Notifier.shared.requestAuthorization()
        store.start()
        // `TEAMCLAUDE_BAR_SNAPSHOT=<dir>` renders the popover to PNG after the first
        // poll and quits: PR screenshots and a look at the layout without a click.
        if let dir = ProcessInfo.processInfo.environment["TEAMCLAUDE_BAR_SNAPSHOT"], !dir.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                store.loadConfigRoot()
                Snapshot.write(store: store, to: URL(fileURLWithPath: dir))
                NSApp.terminate(nil)
            }
        }
        // `TEAMCLAUDE_BAR_DEBUG_WINDOW=<section>` opens the settings window on that
        // section and the popover, and logs their window numbers for `screencapture -l`.
        if let raw = ProcessInfo.processInfo.environment["TEAMCLAUDE_BAR_DEBUG_WINDOW"], let section = SettingsSection(rawValue: raw) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                settings = SettingsWindowController(store: store, section: section)
                settings?.show()
                NSLog("[TeamClaudeBar] settings window %d", settings?.windowNumber ?? -1)
                statusItem.showPopover()
                try? await Task.sleep(for: .seconds(1))
                NSLog("[TeamClaudeBar] popover window %d", statusItem.popoverWindowNumber ?? -1)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    @objc func showSettings() {
        statusItem.closePopover()
        if settings == nil { settings = SettingsWindowController(store: store) }
        settings?.show()
    }
}
