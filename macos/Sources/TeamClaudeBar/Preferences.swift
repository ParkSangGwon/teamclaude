import Foundation
import TeamClaudeCore

/// Per-user app preferences (UserDefaults). The proxy's own settings live in its config file.
@MainActor
final class Preferences {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    enum Key {
        static let pollOpen = "pollOpenSeconds"
        static let pollClosed = "pollClosedSeconds"
        static let iconStyle = "iconStyle"
        static let pinCurrent = "iconPinCurrent"
        static let showRemaining = "iconShowRemaining"
        static let monochrome = "iconMonochrome"
        static let warnLevel = "warnLevel"
        static let resetStyle = "resetStyle"
        static let cliPath = "cliPathOverride"
        static let alertPrefs = "alertPrefs"
        static let alertState = "alertState"
        static let hidePII = "hidePII"
        static let keepRight = "menuBarKeepRight"
    }

    enum IconStyle: String, CaseIterable { case barsPercent, bars, percent, barsBoth, quiet }

    var pollOpen: TimeInterval { get { d.object(forKey: Key.pollOpen) as? Double ?? 2 } set { d.set(newValue, forKey: Key.pollOpen) } }
    var pollClosed: TimeInterval { get { d.object(forKey: Key.pollClosed) as? Double ?? 30 } set { d.set(newValue, forKey: Key.pollClosed) } }
    var iconStyle: IconStyle { get { IconStyle(rawValue: d.string(forKey: Key.iconStyle) ?? "") ?? .barsPercent } set { d.set(newValue.rawValue, forKey: Key.iconStyle) } }
    var pinCurrent: Bool { get { d.bool(forKey: Key.pinCurrent) } set { d.set(newValue, forKey: Key.pinCurrent) } }
    var showRemaining: Bool { get { d.bool(forKey: Key.showRemaining) } set { d.set(newValue, forKey: Key.showRemaining) } }
    var monochrome: Bool { get { d.object(forKey: Key.monochrome) as? Bool ?? true } set { d.set(newValue, forKey: Key.monochrome) } }
    var warnLevel: Double { get { d.object(forKey: Key.warnLevel) as? Double ?? 0.7 } set { d.set(newValue, forKey: Key.warnLevel) } }
    var resetStyle: Derived.ResetStyle { get { Derived.ResetStyle(rawValue: d.string(forKey: Key.resetStyle) ?? "") ?? .both } set { d.set(newValue.rawValue, forKey: Key.resetStyle) } }
    var cliPath: String? { get { d.string(forKey: Key.cliPath) } set { d.set(newValue, forKey: Key.cliPath) } }
    var hidePII: Bool { get { d.bool(forKey: Key.hidePII) } set { d.set(newValue, forKey: Key.hidePII) } }
    /// Place the item next to the system items so a full menu bar never hides it (default on).
    var keepRight: Bool { get { d.object(forKey: Key.keepRight) as? Bool ?? true } set { d.set(newValue, forKey: Key.keepRight) } }

    var alertPrefs: AlertPrefs {
        get { (d.data(forKey: Key.alertPrefs).flatMap { try? JSONDecoder().decode(AlertPrefs.self, from: $0) }) ?? AlertPrefs() }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: Key.alertPrefs) }
    }
    var alertState: AlertState {
        get { (d.data(forKey: Key.alertState).flatMap { try? JSONDecoder().decode(AlertState.self, from: $0) }) ?? AlertState() }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: Key.alertState) }
    }
}
