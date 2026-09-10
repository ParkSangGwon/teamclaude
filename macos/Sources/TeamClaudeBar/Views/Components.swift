import SwiftUI
import AppKit
import TeamClaudeCore

/// True while rendering to PNG: AppKit-backed controls (Menu) draw as a placeholder there.
private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var snapshotMode: Bool { get { self[SnapshotModeKey.self] } set { self[SnapshotModeKey.self] = newValue } }
}

/// Severity colours that read on both appearances: deeper than the system
/// greens/yellows in light mode (which wash out on the popover material),
/// brighter in dark mode.
enum LevelColors {
    static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }
    static let green = adaptive(light: (0.10, 0.58, 0.29), dark: (0.29, 0.84, 0.44))
    static let yellow = adaptive(light: (0.70, 0.50, 0.02), dark: (1.00, 0.84, 0.04))
    static let orange = adaptive(light: (0.86, 0.42, 0.04), dark: (1.00, 0.62, 0.04))
    static let red = adaptive(light: (0.82, 0.16, 0.14), dark: (1.00, 0.27, 0.23))

    static func nsColor(for level: Level) -> NSColor {
        switch level {
        case .green: return green
        case .yellow: return yellow
        case .orange: return orange
        case .red: return red
        }
    }
}

extension Level {
    var color: Color { Color(nsColor: LevelColors.nsColor(for: self)) }
}

extension Color {
    /// The colour names a route can carry in the config (the TUI's palette).
    static let routeNames = ["red", "green", "yellow", "blue", "magenta", "cyan"]

    static func route(_ name: String?) -> Color {
        switch name {
        case "red": return .red
        case "green": return .green
        case "yellow": return .yellow
        case "blue": return .blue
        case "magenta": return .purple
        case "cyan": return .cyan
        default: return .secondary.opacity(0.5)
        }
    }
}

/// A titled settings group: the same box every pane draws around a cluster of controls.
struct TitledGroup<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SectionHeader: View {
    var title: String
    var trailing: String?
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity)
    }
}

struct Chip: View {
    var text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// A quota bar with an elapsed-time tick, coloured by the TUI rule.
struct QuotaBar: View {
    var ratio: Double
    var level: Level
    var elapsed: Double?
    var cap: Double?
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(level.color).frame(width: max(ratio > 0 ? 1 : 0, geo.size.width * min(1, max(0, ratio))))
                if let elapsed {
                    Rectangle().fill(.primary.opacity(0.9)).frame(width: 1.5, height: height + 4)
                        .offset(x: geo.size.width * min(1, max(0, elapsed)) - 0.75, y: -2)
                }
                if let cap {
                    Rectangle().fill(.yellow).frame(width: 1, height: height + 2)
                        .offset(x: geo.size.width * min(1, max(0, cap)) - 0.5, y: -1)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One metric: title, tag, percentage, bar, reset text.
struct UsageRow: View {
    var title: String
    var subtitle: String?
    var tag: String?
    var ratio: Double?
    var resetAt: Date?
    var window: TimeInterval?
    var threshold: Double?
    var cap: Double?
    var resetStyle: Derived.ResetStyle
    var now: Date
    var footNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let tag { Chip(text: tag) }
                if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                // The number is what the card is for: the heaviest element on it.
                if let ratio {
                    Text(Derived.formatPercent(ratio)).font(.system(size: 17, weight: .bold)).monospacedDigit().foregroundStyle(level(ratio).color)
                } else {
                    Text("—").font(.system(size: 17, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            if let ratio {
                QuotaBar(ratio: ratio, level: level(ratio), elapsed: window.flatMap { Derived.elapsedFraction(resetAt: resetAt, window: $0, now: now) }, cap: cap)
            }
            let reset = Derived.formatResetLong(resetAt, style: resetStyle, now: now)
            if !reset.isEmpty || footNote != nil {
                Text([reset, footNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(ratio.map { Derived.formatPercent($0) } ?? "unknown") \(Derived.formatResetLong(resetAt, style: .countdown, now: now))")
    }

    func level(_ ratio: Double) -> Level {
        Derived.level(ratio: ratio, resetAt: resetAt, window: window, threshold: threshold, now: now)
    }
}

struct Banner: View {
    enum Kind { case bad, warn, info, ok }
    var kind: Kind
    var text: String
    var action: (() -> Void)? = nil
    var actionTitle: String? = nil
    var onDismiss: (() -> Void)? = nil

    var color: Color {
        switch kind {
        case .bad: return Level.red.color
        case .warn: return Level.orange.color
        case .info: return .blue
        case .ok: return Level.green.color
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .ok ? "checkmark.circle.fill" : kind == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(color).padding(.top, 1)
            Text(text).font(.system(size: 11)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action, let actionTitle {
                Button(actionTitle, action: action).font(.system(size: 10, weight: .semibold)).buttonStyle(.plain).foregroundStyle(color)
            }
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide for this session")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(0.35), lineWidth: 1))
    }
}
