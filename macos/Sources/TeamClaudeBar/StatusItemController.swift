import AppKit
import SwiftUI
import Observation
import TeamClaudeCore

/// Owns every piece of AppKit state for the menu bar item: the status item, the
/// popover, the right-click menu, and the observation loop that redraws the icon.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: AppStore
    private let openSettings: () -> Void
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var lastModel: IconModel?
    private var lastStyle: Preferences.IconStyle?
    private var lastMono: Bool?

    init(store: AppStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "teamclaudeBar.main"
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView().environment(store))
        observe()
    }

    /// Re-render whenever the pieces of the store the icon depends on change.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        let model = store.iconModel
        let style = store.prefs.iconStyle
        let mono = store.prefs.monochrome
        guard let button = item.button else { return }
        if model == lastModel, style == lastStyle, mono == lastMono { return }
        lastModel = model; lastStyle = style; lastMono = mono
        let rendered = IconRenderer.render(model, style: style, monochrome: mono)
        button.image = rendered.image
        button.attributedTitle = rendered.title
        button.toolTip = model.tooltip
        button.setAccessibilityLabel(model.tooltip)
    }

    @objc private func clicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option) {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    func showPopover() {
        guard let button = item.button else { return }
        store.popoverOpen = true
        store.refreshNow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        store.popoverOpen = false
    }

    private func showMenu() {
        let menu = NSMenu()
        let current = store.status?.currentAccount
        let head = NSMenuItem(title: current.map { "Current: \(store.displayName($0))" } ?? "TeamClaude", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if let status = store.status, !status.accounts.isEmpty {
            let switchMenu = NSMenu()
            for a in status.accountsByPriority {
                var title = store.displayName(a.name)
                if let why = UnavailableText.label(a.unavailable) { title += " · \(why)" }
                let mi = NSMenuItem(title: title, action: #selector(switchAccount(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = a.name
                mi.state = a.name == current ? .on : .off
                switchMenu.addItem(mi)
            }
            let switchItem = NSMenuItem(title: "Switch To", action: nil, keyEquivalent: "")
            switchItem.submenu = switchMenu
            menu.addItem(switchItem)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Reload Config", action: #selector(reload), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Open Proxy Log", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TeamClaude Bar", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { store.switchTo(name) }
    }
    @objc private func refresh() { store.refreshNow() }
    @objc private func reload() { store.reloadConfig() }
    @objc private func openDashboard() { Actions.openDashboard(store) }
    @objc private func openLog() { NSWorkspace.shared.open(ProxyLocator.logPath()) }
    @objc private func settings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

enum Actions {
    /// The dashboard asks for the key on first open even on loopback, so put it on the pasteboard first.
    @MainActor static func openDashboard(_ store: AppStore) {
        if let key = store.endpoint.apiKey, !key.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key, forType: .string)
            store.showToast(.info, "Proxy key copied — paste it if the dashboard asks")
        }
        NSWorkspace.shared.open(store.endpoint.dashboardURL)
    }

    /// Open `teamclaude attach` in the default terminal through a .command file (no Automation permission needed).
    @MainActor static func attachInTerminal(_ store: AppStore) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "TeamClaudeBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "attach.command")
        let cmd = store.cliLocation.map { loc in
            var env = ""
            if let c = loc.configPathOverride { env = "export TEAMCLAUDE_CONFIG=\(shellQuote(c))\n" }
            return "#!/bin/zsh\n\(env)exec \(shellQuote(loc.executable.path)) \(loc.leadingArguments.map(shellQuote).joined(separator: " ")) attach\n"
        } ?? "#!/bin/zsh -l\nexec teamclaude attach\n"
        try? cmd.write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o755)
        NSWorkspace.shared.open(file)
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
