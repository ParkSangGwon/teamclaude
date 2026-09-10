import Foundation

/// `teamclaude update` knows whether it is an npm or a git install and asks the
/// registry itself; the app only reads back what it installed.
public enum UpdateCheck {
    /// The version `teamclaude update` reports it installed, from its stdout.
    public static func installedVersion(fromUpdateOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            if let r = line.range(of: "Updated to ") {
                let tail = line[r.upperBound...].prefix { $0.isNumber || $0 == "." }
                let version = String(tail).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !version.isEmpty { return version }
            }
        }
        return nil
    }
}
