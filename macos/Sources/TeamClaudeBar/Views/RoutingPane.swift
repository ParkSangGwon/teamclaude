import SwiftUI
import TeamClaudeCore

struct RoutingPane: View {
    @Environment(AppStore.self) private var store
    @State private var editing: RouteDraft?
    @State private var confirmRemove: String?

    var routes: [JSON] { store.configValue(["routes"]).array ?? [] }
    var accountNames: [String] { (store.status?.accounts.map(\.name)) ?? (store.configValue(["accounts"]).array ?? []).compactMap { $0["name"].string } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Routes").font(.system(size: 13, weight: .semibold)); Spacer(); AppliesTag(applies: .live); Button("Add route…") { editing = RouteDraft() }.controlSize(.small) }
            if routes.isEmpty {
                Text("No routes — every model rotates across all accounts. Families the proxy meters separately (Fable, Sonnet) get their own weekly bucket automatically.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(routes.enumerated()), id: \.offset) { _, r in
                let live = store.status?.routes.first { $0.name == r["name"].string }
                HStack(alignment: .top) {
                    Circle().fill(routeColor(r["color"].string)).frame(width: 8, height: 8).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(r["name"].string ?? "?").font(.system(size: 13, weight: .semibold))
                            Text(r["match"].stringArray.joined(separator: ", ")).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        let accts = r["accounts"].stringArray
                        Text(accts.isEmpty ? "all accounts" : accts.map(store.compactName).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary)
                        if let live {
                            Text("now → \(live.target.map(store.compactName) ?? "—")" + (live.pinned.map { " · pinned to \(store.compactName($0))" } ?? "") + " · \(live.accounts.filter(\.eligible).count) of \(live.accounts.count) eligible").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Edit") { editing = RouteDraft(json: r) }.controlSize(.small)
                    Button("Remove") { confirmRemove = r["name"].string }.controlSize(.small)
                }
                .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            if let live = store.status?.routes.filter({ $0.autocreated }), !live.isEmpty {
                Text("Auto routes from the proxy: " + live.map { "\($0.name) → \($0.target.map(store.compactName) ?? "—")" }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("First matching route wins; listed accounts are exclusive. Pins made with `s` in the TUI are runtime-only and shown above as \"pinned\".").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            SchemaPane(section: .routing)
        }
        .sheet(item: $editing) { draft in RouteSheet(draft: draft, accountNames: accountNames) { editing = nil } }
        .confirmationDialog("Remove route \(confirmRemove ?? "")?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) { if let n = confirmRemove { Task { await store.apply(.routeRemove(name: n), label: "Route \(n)") } } }
        }
    }

    private func routeColor(_ name: String?) -> Color {
        switch name { case "red": return .red; case "green": return .green; case "yellow": return .yellow; case "blue": return .blue; case "magenta": return .purple; case "cyan": return .cyan; default: return .secondary.opacity(0.5) }
    }
}

struct RouteDraft: Identifiable {
    var id = UUID()
    var name = ""
    var match = ""
    var accounts: Set<String> = []
    var bucket = ""
    var color = ""
    var isNew = true

    init() {}
    init(json: JSON) {
        name = json["name"].string ?? ""
        match = json["match"].stringArray.joined(separator: ", ")
        accounts = Set(json["accounts"].stringArray)
        bucket = json["bucket"].string ?? ""
        color = json["color"].string ?? ""
        isNew = false
    }
}

struct RouteSheet: View {
    @Environment(AppStore.self) private var store
    @State var draft: RouteDraft
    var accountNames: [String]
    var dismiss: () -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isNew ? "Add route" : "Edit route").font(.headline)
            HStack { Text("Name").frame(width: 80, alignment: .trailing); TextField("fable", text: $draft.name).textFieldStyle(.roundedBorder).disabled(!draft.isNew) }
            HStack { Text("Match").frame(width: 80, alignment: .trailing); TextField("*fable*, *opus*", text: $draft.match).textFieldStyle(.roundedBorder) }
            HStack(alignment: .top) {
                Text("Accounts").frame(width: 80, alignment: .trailing)
                VStack(alignment: .leading) {
                    ForEach(accountNames, id: \.self) { n in
                        Toggle(n, isOn: Binding(get: { draft.accounts.contains(n) }, set: { on in if on { draft.accounts.insert(n) } else { draft.accounts.remove(n) } }))
                    }
                    Text("None selected = every account may serve it.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack { Text("Bucket").frame(width: 80, alignment: .trailing); Picker("", selection: $draft.bucket) { Text("auto (by model family)").tag(""); Text("unified7d (shared weekly)").tag("unified7d"); Text("unified7dFable").tag("unified7dFable"); Text("unified7dSonnet").tag("unified7dSonnet") }.labelsHidden() }
            HStack { Text("Color").frame(width: 80, alignment: .trailing); Picker("", selection: $draft.color) { Text("default").tag(""); ForEach(["red", "green", "yellow", "blue", "magenta", "cyan"], id: \.self) { Text($0).tag($0) } }.labelsHidden() }
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 11)) }
            HStack { Spacer(); Button("Cancel", action: dismiss); Button("Save") { save() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 460)
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let globs = draft.match.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !name.isEmpty else { error = "A name is required"; return }
        guard !globs.isEmpty else { error = "At least one model glob is required"; return }
        let accounts = accountNames.filter { draft.accounts.contains($0) }
        Task {
            await store.apply(.routeAdd(name: name, match: globs, accounts: accounts, bucket: draft.bucket.isEmpty ? nil : draft.bucket, color: draft.color.isEmpty ? nil : draft.color), label: "Route \(name)")
            dismiss()
        }
    }
}
