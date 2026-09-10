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
    private var hosting: NSHostingController<AnyView>?
    private var container: PopoverContainerController?
    /// Wide enough for the account table's five columns at a readable size.
    static let popoverWidth: CGFloat = 380
    private var lastModel: IconModel?
    private var lastStyle: Preferences.IconStyle?
    private var lastMono: Bool?
    private var lastLanguage: String??

    static let autosaveName = "teamclaudeBar.main"

    /// macOS remembers a status item's slot under this key (distance from the
    /// right edge, in points). A new item otherwise lands at the far left of the
    /// status area, which a full menu bar hides behind the notch or an overflow
    /// chevron. Seeded once, on the first launch, so a slot the user dragged the
    /// item to afterwards survives a relaunch.
    static func seedPositionOnFirstLaunch() {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(30, forKey: key)
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(autosaveName)")
    }

    init(store: AppStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        Self.seedPositionOnFirstLaunch()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = NSStatusItem.AutosaveName(Self.autosaveName)
        item.isVisible = true
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
        let hosting = NSHostingController(rootView: AnyView(PopoverView().environment(store)))
        // A bare NSHostingController as the popover's content ended up offset inside
        // the popover frame (clipped left edge). Pinning it inside a plain container
        // with Auto Layout keeps it exactly where the popover puts its content.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        let container = PopoverContainerController(hosting: hosting)
        popover.contentViewController = container
        self.hosting = hosting
        self.container = container
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
        let language = store.prefs.language   // the tooltip is localized; a change must re-render
        guard let button = item.button else { return }
        if model == lastModel, style == lastStyle, mono == lastMono, language == lastLanguage { return }
        lastLanguage = language
        lastModel = model; lastStyle = style; lastMono = mono
        let rendered = IconRenderer.render(model, style: style, monochrome: mono)
        if popover.isShown { resizePopover() }
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

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    func togglePopover() {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    func showPopover() {
        guard let button = item.button else { return }
        store.popoverOpen = true
        store.refreshNow()
        resizePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    var popoverWindowNumber: Int? { popover.contentViewController?.view.window?.windowNumber }

    /// Measure the SwiftUI content at the fixed width and size the popover to it.
    func resizePopover() {
        guard let hosting else { return }
        let size = hosting.sizeThatFits(in: NSSize(width: Self.popoverWidth, height: 10_000))
        let target = NSSize(width: Self.popoverWidth, height: max(120, ceil(size.height)))
        if popover.contentSize != target {
            container?.preferredContentSize = target
            popover.contentSize = target
        }
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
        let head = NSMenuItem(title: current.map { L("Current: %@", store.displayName($0)) } ?? "TeamClaude", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        if store.status?.accounts.count ?? 0 > 1 {
            let next = menu.addItem(withTitle: L("Switch to Next Available Account"), action: #selector(switchNext), keyEquivalent: "")
            next.target = self
            next.isEnabled = !store.isDown && store.switchSupported
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Refresh"), action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: L("Reload Config"), action: #selector(reload), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Open Dashboard"), action: #selector(openDashboard), keyEquivalent: "d").target = self
        menu.addItem(withTitle: L("Attach in Terminal"), action: #selector(attach), keyEquivalent: "t").target = self
        menu.addItem(withTitle: L("Open Proxy Log"), action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let paused = store.prefs.alertPrefs.isPaused(at: Date())
        menu.addItem(withTitle: paused ? L("Resume Notifications") : L("Pause Notifications for 1 Hour"), action: #selector(togglePause), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Settings…"), action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit TeamClaude Bar"), action: #selector(quit), keyEquivalent: "q").target = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func switchNext() { store.switchToNextAvailable() }
    @objc private func refresh() { store.refreshNow() }
    @objc private func reload() { Task { await store.reloadConfig() } }
    @objc private func openDashboard() { Actions.openDashboard(store) }
    @objc private func attach() { Actions.attachInTerminal(store) }
    @objc private func openLog() { NSWorkspace.shared.open(ProxyLocator.logPath()) }
    @objc private func togglePause() {
        var p = store.prefs.alertPrefs
        p.pausedUntil = p.isPaused(at: Date()) ? nil : Date().addingTimeInterval(3600)
        store.prefs.alertPrefs = p
    }
    @objc private func settings() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Plain container whose only job is to pin the SwiftUI hosting view to its edges.
@MainActor
final class PopoverContainerController: NSViewController {
    private let hosting: NSHostingController<AnyView>

    init(hosting: NSHostingController<AnyView>) {
        self.hosting = hosting
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func loadView() {
        let root = NSView()
        addChild(hosting)
        let child = hosting.view
        child.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            child.topAnchor.constraint(equalTo: root.topAnchor),
            child.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}

enum Actions {
    /// The dashboard asks for the key on first open even on loopback, so put it on the pasteboard first —
    /// marked concealed and transient so clipboard managers skip it and Handoff does not sync it.
    @MainActor static func openDashboard(_ store: AppStore) {
        if let key = store.endpoint.apiKey, !key.isEmpty {
            copySecret(key)
            store.showToast(.info, L("Proxy key copied — paste it if the dashboard asks"))
        }
        NSWorkspace.shared.open(store.endpoint.dashboardURL)
    }

    static func copySecret(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
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
