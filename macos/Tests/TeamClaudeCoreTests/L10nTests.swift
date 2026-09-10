import XCTest
@testable import TeamClaudeCore

final class L10nTests: XCTestCase {
    override func tearDown() { L10n.activate("en") }

    func testSystemDefaultPicksAShippedLanguage() {
        XCTAssertEqual(L10n.systemDefault(preferences: ["ko-KR", "en-US"]), "ko")
        XCTAssertEqual(L10n.systemDefault(preferences: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(L10n.systemDefault(preferences: ["pt-BR", "de-DE"]), "de")
        XCTAssertEqual(L10n.systemDefault(preferences: ["xx"]), "en")
    }

    func testEnglishIsTheKey() {
        L10n.activate("en")
        XCTAssertEqual(L("Accounts"), "Accounts")
        XCTAssertEqual(L("Resets in %@", "3h"), "Resets in 3h")
    }

    func testUnknownCodeFallsBackToSystem() {
        XCTAssertEqual(L10n.activate("tlh"), L10n.systemDefault())
    }

    func testKoreanTableLoadsFromTheResourceBundle() throws {
        // The Makefile copies the bundle into the app; `swift test` finds it beside the test bundle.
        try XCTSkipIf(L10n.resourceBundle() == nil, "resource bundle not built")
        XCTAssertEqual(L10n.activate("ko"), "ko")
        XCTAssertEqual(L("Accounts"), "계정")
        XCTAssertEqual(L("no-such-key"), "no-such-key")
    }

    /// Every shipped translation keeps the source string's placeholders, so `String(format:)` never reads past its arguments.
    func testShippedTablesKeepPlaceholders() throws {
        try XCTSkipIf(L10n.resourceBundle() == nil, "resource bundle not built")
        func placeholders(_ s: String) -> [String] {
            let re = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?[@d%]")
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]).replacingOccurrences(of: "[0-9]+\\$", with: "", options: .regularExpression) }.sorted()
        }
        for code in L10n.supported.map(\.code) where code != "en" {
            let table = L10n.loadTable(code)
            XCTAssertFalse(table.isEmpty, "\(code) has no table")
            // Tokenize left to right so `%%` is one escape and the trailing `%` of `%d%%` is not a stray.
            let tokens = try NSRegularExpression(pattern: "%%|%(?:\\d+\\$)?[@d]|%")
            for (key, value) in table {
                XCTAssertEqual(placeholders(key), placeholders(value), "\(code): placeholders differ for \(key)")
                XCTAssertFalse(value.isEmpty, "\(code): empty translation for \(key)")
                // A bare % is fine in a plain label, fatal in a format string: `%s` would read a C string off the stack.
                if !placeholders(key).isEmpty {
                    let bare = tokens.matches(in: value, range: NSRange(value.startIndex..., in: value)).contains { $0.range.length == 1 }
                    XCTAssertFalse(bare, "\(code): stray % in \(value)")
                }
            }
        }
    }

    func testAllLanguagesShipTheSameKeys() throws {
        try XCTSkipIf(L10n.resourceBundle() == nil, "resource bundle not built")
        let tables = L10n.supported.map(\.code).filter { $0 != "en" }.map { ($0, Set(L10n.loadTable($0).keys)) }
        guard let first = tables.first else { return }
        for (code, keys) in tables.dropFirst() where keys != first.1 {
            XCTFail("\(code) and \(first.0) ship different keys: \(keys.symmetricDifference(first.1).sorted().prefix(5))")
        }
    }
}
