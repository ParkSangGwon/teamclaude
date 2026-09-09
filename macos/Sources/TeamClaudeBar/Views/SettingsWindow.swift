import AppKit
import SwiftUI
import TeamClaudeCore

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(store: AppStore) {
        let hosting = NSHostingController(rootView: SettingsRootView().environment(store))
        window = NSWindow(contentViewController: hosting)
        window.title = "TeamClaude Bar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 540))
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsRootView: View {
    @Environment(AppStore.self) private var store
    @State private var section: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { s in
                Text(s.title).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 200)
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Text(section.title).font(.title2.bold())
                Text("Settings panes land once the design direction is chosen.").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
