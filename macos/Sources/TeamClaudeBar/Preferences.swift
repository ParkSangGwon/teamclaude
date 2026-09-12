import Foundation
import Observation
import TeamClaudeCore

/// Per-user app preferences: observable stored properties that mirror themselves
/// into UserDefaults, so views bind to them directly and the icon re-renders on
/// change. The proxy's own settings live in its config file.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    enum IconStyle: String, CaseIterable { case barsPercent, bars, percent, barsBoth, quiet }

    /// One choice for both cadences: (popover open, popover closed) seconds.
    enum Refresh: String, CaseIterable {
        case fast, normal, powerSaver
        var intervals: (open: TimeInterval, closed: TimeInterval) {
            switch self {
            case .fast: return (2, 15)
            case .normal: return (2, 30)
            case .powerSaver: return (5, 60)
            }
        }
        var title: String {
            switch self {
            case .fast: return L("Fast (2 s / 15 s)")
            case .normal: return L("Normal (2 s / 30 s)")
            case .powerSaver: return L("Power saver (5 s / 60 s)")
            }
        }
    }

    var refresh: Refresh { didSet { d.set(refresh.rawValue, forKey: "refreshProfile") } }
    var iconStyle: IconStyle { didSet { d.set(iconStyle.rawValue, forKey: "iconStyle") } }
    var pinCurrent: Bool { didSet { d.set(pinCurrent, forKey: "iconPinCurrent") } }
    var showRemaining: Bool { didSet { d.set(showRemaining, forKey: "iconShowRemaining") } }
    var monochrome: Bool { didSet { d.set(monochrome, forKey: "iconMonochrome") } }
    var resetStyle: Derived.ResetStyle { didSet { d.set(resetStyle.rawValue, forKey: "resetStyle") } }
    var cliPath: String? { didSet { d.set(cliPath, forKey: "cliPathOverride") } }
    var hidePII: Bool { didSet { d.set(hidePII, forKey: "hidePII") } }
    /// ⌃⌥⌘N: move traffic to the next account that can serve.
    var hotkeyNextAccount: Bool { didSet { d.set(hotkeyNextAccount, forKey: "hotkeyNextAccount") } }
    /// ⌃⌥⌘T: open or close the popover.
    var hotkeyTogglePopover: Bool { didSet { d.set(hotkeyTogglePopover, forKey: "hotkeyTogglePopover") } }
    var alertPrefs: AlertPrefs { didSet { d.set(try? JSONEncoder().encode(alertPrefs), forKey: "alertPrefs") } }
    var alertState: AlertState { didSet { d.set(try? JSONEncoder().encode(alertState), forKey: "alertState") } }
    var rotationLog: RotationLog { didSet { d.set(try? JSONEncoder().encode(rotationLog), forKey: "rotationLog") } }
    /// UI language code from `L10n.supported`; nil follows the Mac's language setting.
    var language: String? { didSet { d.set(language, forKey: "language"); L10n.activate(language) } }

    var pollOpen: TimeInterval { refresh.intervals.open }
    var pollClosed: TimeInterval { refresh.intervals.closed }

    private let d = UserDefaults.standard

    private init() {
        // A pre-profile build stored the two intervals; the closed one picks the nearest profile.
        let closed = d.object(forKey: "pollClosedSeconds") as? Double
        refresh = Refresh(rawValue: d.string(forKey: "refreshProfile") ?? "") ?? (closed.map { $0 <= 15 ? .fast : $0 >= 60 ? .powerSaver : .normal } ?? .normal)
        iconStyle = IconStyle(rawValue: d.string(forKey: "iconStyle") ?? "") ?? .barsPercent
        pinCurrent = d.bool(forKey: "iconPinCurrent")
        showRemaining = d.bool(forKey: "iconShowRemaining")
        monochrome = d.object(forKey: "iconMonochrome") as? Bool ?? true
        resetStyle = Derived.ResetStyle(rawValue: d.string(forKey: "resetStyle") ?? "") ?? .both
        cliPath = d.string(forKey: "cliPathOverride")
        hidePII = d.bool(forKey: "hidePII")
        hotkeyNextAccount = d.object(forKey: "hotkeyNextAccount") as? Bool ?? true
        hotkeyTogglePopover = d.object(forKey: "hotkeyTogglePopover") as? Bool ?? true
        alertPrefs = (d.data(forKey: "alertPrefs").flatMap { try? JSONDecoder().decode(AlertPrefs.self, from: $0) }) ?? AlertPrefs()
        alertState = (d.data(forKey: "alertState").flatMap { try? JSONDecoder().decode(AlertState.self, from: $0) }) ?? AlertState()
        rotationLog = (d.data(forKey: "rotationLog").flatMap { try? JSONDecoder().decode(RotationLog.self, from: $0) }) ?? RotationLog()
        // A code from a build that shipped more languages must not leave the picker on an invalid selection.
        language = d.string(forKey: "language").flatMap { code in L10n.supported.contains { $0.code == code } ? code : nil }
        L10n.activate(language)
    }
}
