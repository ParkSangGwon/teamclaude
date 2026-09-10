import SwiftUI
import AppKit
import TeamClaudeCore

/// Renders one `SettingField` from the schema: label, help, the right control,
/// and the live / restart tag. Commits go back as JSON (nil = delete the key).
struct FieldRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.snapshotMode) private var snapshotMode
    let field: SettingField
    let value: JSON
    let onCommit: (JSON?) -> Void

    var applies: Applies { field.applies.resolved(serverVersion: store.serverVersion) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(field.label)).font(.system(size: 13, weight: .semibold))
                Spacer()
                AppliesTag(applies: applies)
            }
            // ImageRenderer draws AppKit-backed fields as placeholders; the PNGs show the value as text instead.
            if snapshotMode {
                Text(snapshotText).font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary)
            } else {
                control.accessibilityLabel(L(field.label))
            }
            Text(L(field.help)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private var snapshotText: String {
        switch field.kind {
        case .toggle: return value.bool == true ? L("on") : L("off")
        case .secret: return value.string.map { _ in "•••••" } ?? L("(not set)")
        case .stringList: return value.stringArray.isEmpty ? L("(none)") : value.stringArray.joined(separator: ", ")
        case .keyedNumbers, .objectList: return value.isNull ? L("(default)") : value.pretty()
        default: return value.string ?? value.double.map { $0 == $0.rounded() ? String(Derived.safeInt($0)) : String($0) } ?? L("(default)")
        }
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .toggle:
            Toggle(L(field.label), isOn: Binding(get: { value.bool ?? false }, set: { onCommit(.bool($0)) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
        case .int(let min, let max, let step, let unit):
            NumberEditor(value: value.double, integer: true, min: min.map(Double.init), max: max.map(Double.init), step: Double(step), unit: unit, onCommit: { onCommit($0.map(JSON.number)) })
        case .double(let min, let max, let step, let unit):
            NumberEditor(value: value.double, integer: false, min: min, max: max, step: step, unit: unit, onCommit: { onCommit($0.map(JSON.number)) })
        case .text(let placeholder):
            TextEditorRow(value: value.string ?? "", placeholder: placeholder ?? "", onCommit: { onCommit($0.isEmpty ? nil : .string($0)) })
        case .secret:
            SecretEditor(value: value.string, canRegenerate: field.id == "proxy.apiKey", onCommit: { onCommit($0.map(JSON.string)) })
        case .picker(let options):
            Picker(L(field.label), selection: Binding(get: { value.string ?? options.first ?? "" }, set: { if $0 != value.string { onCommit(.string($0)) } })) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
        case .stringList:
            TextEditorRow(value: value.stringArray.joined(separator: ", "), placeholder: "comma-separated", onCommit: { text in
                let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                onCommit(items.isEmpty ? nil : .array(items.map(JSON.string)))
            })
        case .keyedNumbers(let keys):
            KeyedNumbersEditor(keys: keys, value: value, onCommit: onCommit)
        case .objectList(let fields):
            ObjectListEditor(fields: fields, value: value, onCommit: onCommit)
        }
    }
}

struct AppliesTag: View {
    var applies: Applies
    var body: some View {
        // The adaptive severity colours: system green/yellow are near-invisible on the light window background.
        switch applies {
        case .live: Label(L("applies live"), systemImage: "bolt.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Level.green.color)
        default: Label(L("restart"), systemImage: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(Level.orange.color)
        }
    }
}

struct NumberEditor: View {
    var value: Double?
    var integer: Bool
    var min: Double?
    var max: Double?
    var step: Double
    var unit: String?
    var onCommit: (Double?) -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text).textFieldStyle(.roundedBorder).frame(width: 110).multilineTextAlignment(.trailing)
                .onSubmit(commit)
            if let unit { Text(unit).font(.system(size: 12)).foregroundStyle(.secondary) }
            Stepper("", onIncrement: { bump(step) }, onDecrement: { bump(-step) }).labelsHidden()
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            Spacer()
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, new in text = format(new) }
    }

    private func format(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return integer || v == v.rounded() ? String(Derived.safeInt(v)) : String(v)
    }

    private func bump(_ delta: Double) {
        let base = Double(text) ?? value ?? 0
        text = format(clamp(base + delta))
        commit()
    }

    private func clamp(_ v: Double) -> Double {
        var x = v
        if let min { x = Swift.max(min, x) }
        if let max { x = Swift.min(max, x) }
        return integer ? x.rounded() : x
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { error = nil; onCommit(nil); return }
        guard let v = Double(trimmed) else { error = L("not a number"); return }
        if let min, v < min { error = L("min %@", format(min)); return }
        if let max, v > max { error = L("max %@", format(max)); return }
        error = nil
        let clamped = integer ? v.rounded() : v
        if clamped != value { onCommit(clamped) }
    }
}

struct TextEditorRow: View {
    var value: String
    var placeholder: String
    var onCommit: (String) -> Void
    @State private var text = ""
    var body: some View {
        HStack {
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                .onSubmit { if text != value { onCommit(text.trimmingCharacters(in: .whitespaces)) } }
            if text != value { Button(L("Apply")) { onCommit(text.trimmingCharacters(in: .whitespaces)) }.controlSize(.small) }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, new in text = new }
    }
}

struct SecretEditor: View {
    var value: String?
    var canRegenerate: Bool
    var onCommit: (String?) -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmRegenerate = false

    var masked: String {
        guard let value, !value.isEmpty else { return L("(not set)") }
        if value.count <= 8 { return String(repeating: "•", count: value.count) }
        return value.prefix(5) + "…" + value.suffix(3)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(masked).font(.system(size: 12, design: .monospaced)).foregroundStyle(value == nil ? .secondary : .primary)
            if let value, !value.isEmpty {
                Button(L("Copy")) { Actions.copySecret(value) }.controlSize(.small)
            }
            Button(value == nil ? L("Set…") : L("Change…")) { draft = ""; editing = true }.controlSize(.small)
            if canRegenerate { Button(L("Regenerate…")) { confirmRegenerate = true }.controlSize(.small) }
            if value != nil, !canRegenerate { Button(L("Clear")) { onCommit(nil) }.controlSize(.small) }
            Spacer()
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Enter the new value")).font(.headline)
                SecureField(L("secret"), text: $draft).textFieldStyle(.roundedBorder).frame(width: 360)
                HStack { Spacer(); Button(L("Cancel")) { editing = false }; Button(L("Save")) { onCommit(draft); editing = false }.keyboardShortcut(.defaultAction).disabled(draft.isEmpty) }
            }.padding(20)
        }
        .confirmationDialog(L("Regenerate the proxy key?"), isPresented: $confirmRegenerate) {
            Button(L("Regenerate"), role: .destructive) { onCommit(ConfigFile.newProxyKey()) }
        } message: { Text(L("Remote clients and the dashboard need the new key. The app switches to it automatically.")) }
    }
}

/// Per-bucket percentages; empty = default. Stored as fractions (0–1).
struct KeyedNumbersEditor: View {
    var keys: [String]
    var value: JSON
    var onCommit: (JSON?) -> Void
    @State private var texts: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let scalar = value.double {
                Text(L("Currently a single value: %@", Derived.formatPercent(scalar))).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(keys, id: \.self) { key in
                HStack {
                    Text(key).font(.system(size: 12, design: .monospaced)).frame(width: 150, alignment: .leading)
                    TextField(key, text: Binding(get: { texts[key] ?? "" }, set: { texts[key] = $0 }), prompt: Text(L("default")))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
                        .onSubmit(commit)
                    Text("%").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(L("Apply")) { commit() }.controlSize(.small)
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            }
        }
        .onAppear(perform: load)
        .onChange(of: value) { _, _ in load() }
    }

    private func load() {
        var t: [String: String] = [:]
        if let obj = value.object {
            for (k, v) in obj { if let d = v.double { t[k] = String(format: "%g", d * 100) } }
        } else if let d = value.double {
            t["default"] = String(format: "%g", d * 100)
        }
        texts = t
        error = nil
    }

    /// Nothing is written while any entry is wrong: a silently dropped value would read as "applied".
    private func commit() {
        var obj: [String: JSON] = [:]
        for key in keys {
            let raw = (texts[key] ?? "").trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { continue }
            guard let pct = Double(raw), pct >= 0, pct <= 100 else { error = "\(key): " + L("a number from 0 to 100"); return }
            obj[key] = .number(pct / 100)
        }
        error = nil
        onCommit(obj.isEmpty ? nil : .object(obj))
    }
}

/// A list of small objects with string fields (client keys, usage dimensions, model map).
struct ObjectListEditor: View {
    var fields: [String]
    var value: JSON
    var onCommit: (JSON?) -> Void
    @State private var rows: [[String: String]] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { i in
                HStack {
                    ForEach(fields, id: \.self) { f in
                        let secret = SettingsSchema.sensitiveKeys.contains(f)
                        // Index-keyed rows: a binding can be read once more after its row was removed.
                        let text = Binding(get: { rows.indices.contains(i) ? rows[i][f] ?? "" : "" },
                                           set: { if rows.indices.contains(i) { rows[i][f] = $0 } })
                        Group {
                            if secret {
                                SecureField(f, text: text)
                            } else {
                                TextField(f, text: text)
                            }
                        }.textFieldStyle(.roundedBorder).frame(width: 180)
                    }
                    Button { rows.remove(at: i); commit() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            HStack {
                Button(L("Add")) { rows.append([:]) }.controlSize(.small)
                if fields.contains("key") { Button(L("Add with generated key")) { rows.append(["key": ConfigFile.newProxyKey()]) }.controlSize(.small) }
                Button(L("Apply")) { commit() }.controlSize(.small)
            }
        }
        .onAppear(perform: load)
        .onChange(of: value) { _, _ in load() }
    }

    private func load() {
        if fields == ["from", "to"], let obj = value.object {
            rows = obj.keys.sorted().map { ["from": $0, "to": obj[$0]?.string ?? ""] }
        } else {
            rows = (value.array ?? []).map { row in
                var r: [String: String] = [:]
                for f in fields { r[f] = row[f].string ?? "" }
                return r
            }
        }
    }

    private func commit() {
        let clean = rows.filter { row in fields.contains { !(row[$0] ?? "").isEmpty } }
        if fields == ["from", "to"] {
            var obj: [String: JSON] = [:]
            for r in clean { if let from = r["from"], !from.isEmpty { obj[from] = .string(r["to"] ?? "") } }
            onCommit(obj.isEmpty ? nil : .object(obj))
        } else {
            let arr = clean.map { r in JSON.object(Dictionary(uniqueKeysWithValues: fields.map { ($0, JSON.string(r[$0] ?? "")) })) }
            onCommit(arr.isEmpty ? nil : .array(arr))
        }
    }
}

/// A whole section rendered from the schema, routing CLI-backed fields to their verbs.
struct SchemaPane: View {
    @Environment(AppStore.self) private var store
    let section: SettingsSection
    var fields: [SettingField] { SettingsSchema.fields(in: section) }

    /// Tuning knobs that only matter in one mode live in a collapsed group, disabled while that mode is off.
    static let groups: [(prefix: String, title: String, gate: (AppStore) -> Bool, note: String)] = [
        ("stormRamp.", "Storm control", { $0.configValue(["stormRamp", "enabled"]).bool == true }, "Storm control is off; turn it on above to tune these."),
        ("adaptiveDistribution.", "Adaptive distribution", { $0.configValue(["distributeSessions"]).string == "adaptive" }, "Session distribution is not in adaptive mode; these values are ignored until it is."),
    ]

    var body: some View {
        let grouped = SchemaPane.groups.filter { g in fields.contains { $0.id.hasPrefix(g.prefix) } }
        ForEach(fields.filter { f in !grouped.contains { f.id.hasPrefix($0.prefix) && f.id != $0.prefix + "enabled" } }) { field in
            row(field)
            Divider()
        }
        ForEach(Array(grouped.enumerated()), id: \.offset) { _, g in
            let members = fields.filter { $0.id.hasPrefix(g.prefix) && $0.id != g.prefix + "enabled" }
            let on = g.gate(store)
            DisclosureGroup {
                if !on { Text(L(g.note)).font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 4) }
                ForEach(members) { field in
                    row(field).disabled(!on).opacity(on ? 1 : 0.6)
                    Divider()
                }
            } label: {
                HStack { Text(L(g.title)).font(.system(size: 13, weight: .semibold)); Text(L("%d settings", members.count)).font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); AppliesTag(applies: .restart) }
            }
            .padding(.vertical, 8)
            Divider()
        }
    }

    private func row(_ field: SettingField) -> some View {
        FieldRow(field: field, value: displayValue(field)) { new in
            if let why = SchemaPane.validate(field, value: new) {
                store.showToast(.error, "\(L(field.label)): \(why)")
                return
            }
            Task { await store.apply(SettingsPlanner.change(for: field, value: new), label: L(field.label)) }
        }
    }

    /// What the CLI does not check for us and the proxy would die on at reload.
    static func validate(_ field: SettingField, value: JSON?) -> String? {
        switch field.id {
        case "upstreamProxy":
            return value?.string.flatMap(SettingsValidation.upstreamProxy)
        case "proxy.host":
            guard let h = value?.string, !h.isEmpty else { return nil }
            return ProxyEndpoint.isValid(host: h, port: 3456) ? nil : L("Not a host name or address the app can dial")
        case "proxy.port":
            guard let p = value?.int else { return nil }
            return (1...65535).contains(p) ? nil : L("Port must be 1–65535")
        case "proxy.usageDimensions":
            let headers = (value?.array ?? []).compactMap { $0["header"].string?.lowercased() }
            if let reserved = headers.first(where: { SettingsValidation.reservedDimensionHeaders.contains($0) }) {
                return L("%@ is a reserved header and cannot be a usage dimension", reserved)
            }
            return nil
        default:
            return nil
        }
    }

    /// `distributeSessions` is stored as `false | true | "adaptive"`; the picker shows off/on/adaptive.
    private func displayValue(_ field: SettingField) -> JSON {
        let raw = store.configValue(field.path)
        if field.id == "distributeSessions" {
            if raw.string == "adaptive" { return .string("adaptive") }
            return .string(raw.bool == true ? "on" : "off")
        }
        if field.id == "switchThreshold", let d = raw.double { return .number(d * 100) }
        if field.id == "switchThreshold", raw.object != nil { return .null }
        if field.id == "switchThresholds" { return store.configValue(["switchThreshold"]) }
        if field.id == "eventLogging", raw.isNull { return .string("hide") }
        if field.id == "logLevel", raw.isNull { return .string("body") }
        if field.id == "sx.mode", raw.isNull { return .string("always") }
        return raw
    }

}
