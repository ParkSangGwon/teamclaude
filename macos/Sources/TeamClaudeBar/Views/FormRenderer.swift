import SwiftUI
import AppKit
import TeamClaudeCore

/// Renders one `SettingField` from the schema: label, help, the right control,
/// and the live / restart tag. Commits go back as JSON (nil = delete the key).
struct FieldRow: View {
    @Environment(AppStore.self) private var store
    let field: SettingField
    let value: JSON
    let onCommit: (JSON?) -> Void

    var applies: Applies { field.applies.resolved(serverVersion: store.serverVersion) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(field.label).font(.system(size: 13, weight: .semibold))
                Spacer()
                AppliesTag(applies: applies)
            }
            control
            Text(field.help).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .toggle:
            ToggleEditor(value: value.bool ?? false, onCommit: { onCommit(.bool($0)) })
        case .int(let min, let max, let step, let unit):
            NumberEditor(value: value.double, integer: true, min: min.map(Double.init), max: max.map(Double.init), step: Double(step), unit: unit, onCommit: { onCommit($0.map(JSON.number)) })
        case .double(let min, let max, let step, let unit):
            NumberEditor(value: value.double, integer: false, min: min, max: max, step: step, unit: unit, onCommit: { onCommit($0.map(JSON.number)) })
        case .text(let placeholder):
            TextEditorRow(value: value.string ?? "", placeholder: placeholder ?? "", onCommit: { onCommit($0.isEmpty ? nil : .string($0)) })
        case .secret:
            SecretEditor(value: value.string, canRegenerate: field.id == "proxy.apiKey", onCommit: { onCommit($0.map(JSON.string)) })
        case .picker(let options):
            PickerEditor(options: options, value: value.string ?? options.first ?? "", onCommit: { onCommit(.string($0)) })
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
        switch applies {
        case .live: Text("applies live").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
        default: Label("restart", systemImage: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(.yellow)
        }
    }
}

struct ToggleEditor: View {
    var value: Bool
    var onCommit: (Bool) -> Void
    @State private var local = false
    var body: some View {
        Toggle("", isOn: $local).labelsHidden().toggleStyle(.switch).controlSize(.small)
            .onAppear { local = value }
            .onChange(of: value) { _, new in local = new }
            .onChange(of: local) { _, new in if new != value { onCommit(new) } }
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
        guard let v else { return "" }
        return integer || v == v.rounded() ? String(Int(v)) : String(v)
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
        guard let v = Double(trimmed) else { error = "not a number"; return }
        if let min, v < min { error = "min \(format(min))"; return }
        if let max, v > max { error = "max \(format(max))"; return }
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
            if text != value { Button("Apply") { onCommit(text.trimmingCharacters(in: .whitespaces)) }.controlSize(.small) }
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
        guard let value, !value.isEmpty else { return "(not set)" }
        if value.count <= 8 { return String(repeating: "•", count: value.count) }
        return value.prefix(5) + "…" + value.suffix(3)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(masked).font(.system(size: 12, design: .monospaced)).foregroundStyle(value == nil ? .secondary : .primary)
            if let value, !value.isEmpty {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }.controlSize(.small)
            }
            Button(value == nil ? "Set…" : "Change…") { draft = ""; editing = true }.controlSize(.small)
            if canRegenerate { Button("Regenerate…") { confirmRegenerate = true }.controlSize(.small) }
            if value != nil, !canRegenerate { Button("Clear") { onCommit(nil) }.controlSize(.small) }
            Spacer()
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter the new value").font(.headline)
                SecureField("secret", text: $draft).textFieldStyle(.roundedBorder).frame(width: 360)
                HStack { Spacer(); Button("Cancel") { editing = false }; Button("Save") { onCommit(draft); editing = false }.keyboardShortcut(.defaultAction).disabled(draft.isEmpty) }
            }.padding(20)
        }
        .confirmationDialog("Regenerate the proxy key?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { onCommit(ConfigFile.newProxyKey()) }
        } message: { Text("Remote clients and the dashboard need the new key. The app switches to it automatically.") }
    }
}

struct PickerEditor: View {
    var options: [String]
    var value: String
    var onCommit: (String) -> Void
    @State private var local = ""
    var body: some View {
        Picker("", selection: $local) { ForEach(options, id: \.self) { Text($0).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            .onAppear { local = value }
            .onChange(of: value) { _, new in local = new }
            .onChange(of: local) { _, new in if new != value { onCommit(new) } }
    }
}

/// Per-bucket percentages; empty = default. Stored as fractions (0–1).
struct KeyedNumbersEditor: View {
    var keys: [String]
    var value: JSON
    var onCommit: (JSON?) -> Void
    @State private var texts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let scalar = value.double {
                Text("Currently a single value: \(Derived.formatPercent(scalar))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(keys, id: \.self) { key in
                HStack {
                    Text(key).font(.system(size: 12, design: .monospaced)).frame(width: 150, alignment: .leading)
                    TextField("default", text: Binding(get: { texts[key] ?? "" }, set: { texts[key] = $0 })).textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
                        .onSubmit(commit)
                    Text("%").foregroundStyle(.secondary)
                }
            }
            Button("Apply") { commit() }.controlSize(.small)
        }
        .onAppear(perform: load)
        .onChange(of: value) { _, _ in load() }
    }

    private func load() {
        var t: [String: String] = [:]
        if let obj = value.object {
            for (k, v) in obj { if let d = v.double { t[k] = String(format: "%g", d * 100) } }
        }
        texts = t
    }

    private func commit() {
        var obj: [String: JSON] = [:]
        for key in keys {
            let raw = (texts[key] ?? "").trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { continue }
            guard let pct = Double(raw), pct >= 0, pct <= 100 else { continue }
            obj[key] = .number(pct / 100)
        }
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
                        Group {
                            if secret {
                                SecureField(f, text: Binding(get: { rows[i][f] ?? "" }, set: { rows[i][f] = $0 }))
                            } else {
                                TextField(f, text: Binding(get: { rows[i][f] ?? "" }, set: { rows[i][f] = $0 }))
                            }
                        }.textFieldStyle(.roundedBorder).frame(width: 180)
                    }
                    Button { rows.remove(at: i); commit() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            HStack {
                Button("Add") { rows.append([:]) }.controlSize(.small)
                if fields.contains("key") { Button("Add with generated key") { rows.append(["key": ConfigFile.newProxyKey()]) }.controlSize(.small) }
                Button("Apply") { commit() }.controlSize(.small)
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

    var body: some View {
        ForEach(fields) { field in
            FieldRow(field: field, value: displayValue(field)) { new in
                Task { await store.apply(change(for: field, value: new), label: field.label) }
            }
            Divider()
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

    static func change(for field: SettingField, value: JSON?, serverVersion: String?) -> SettingChange {
        switch field.id {
        case "switchThreshold":
            return .threshold(percent: value?.double ?? 98)
        case "switchThresholds":
            var table: [String: Double?] = [:]
            for key in Buckets.all { table[key] = value?[key].double.map { $0 * 100 } }
            if table.values.allSatisfy({ $0 == nil }) { return .threshold(percent: 98) }
            return .thresholdTable(table)
        case "distributeSessions":
            return .distribute(value?.string ?? "off")
        case "quotaProbeSeconds":
            return .probe(seconds: Int(value?.double ?? 0))
        case "warmupSeconds":
            let secs = Int(value?.double ?? 0)
            return secs <= 0 ? .warmupOff : .warmupInterval(seconds: secs)
        default:
            return .json(path: field.path, value: value, applies: field.applies)
        }
    }

    private func change(for field: SettingField, value: JSON?) -> SettingChange {
        SchemaPane.change(for: field, value: value, serverVersion: store.serverVersion)
    }
}
