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
                Snapshot.write(store: store, to: URL(fileURLWithPath: dir))
                NSApp.terminate(nil)
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
