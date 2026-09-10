import XCTest
@testable import TeamClaudeCore

final class UpdateCheckTests: XCTestCase {
    func testParseLatest() {
        XCTAssertEqual(UpdateCheck.parseLatest(Data(#"{"name":"@karpeleslab/teamclaude","version":"1.1.18"}"#.utf8)), "1.1.18")
        XCTAssertNil(UpdateCheck.parseLatest(Data("not json".utf8)))
        XCTAssertNil(UpdateCheck.parseLatest(Data(#"{"version":""}"#.utf8)))
    }

    func testIsNewer() {
        XCTAssertTrue(UpdateCheck.isNewer(latest: "1.1.18", installed: "1.1.16"))
        XCTAssertFalse(UpdateCheck.isNewer(latest: "1.1.18", installed: "1.1.18"))
        XCTAssertFalse(UpdateCheck.isNewer(latest: "1.1.17", installed: "1.1.18"))
        XCTAssertFalse(UpdateCheck.isNewer(latest: "1.1.18", installed: "unknown"), "a git checkout is never outdated")
        XCTAssertFalse(UpdateCheck.isNewer(latest: "1.2.0-beta.1", installed: "1.1.18"), "pre-releases are not offered")
        XCTAssertFalse(UpdateCheck.isNewer(latest: nil, installed: "1.1.18"))
        XCTAssertFalse(UpdateCheck.isNewer(latest: "1.1.18", installed: nil))
    }

    func testInstalledVersionFromUpdateOutput() {
        XCTAssertEqual(UpdateCheck.installedVersion(fromUpdateOutput: "Current version: 1.1.16\nUpdating 1.1.16 → 1.1.18 …\nUpdated to 1.1.18. Restart teamclaude to use the new version.\n"), "1.1.18")
        XCTAssertNil(UpdateCheck.installedVersion(fromUpdateOutput: "Already up to date (latest is 1.1.18).\n"))
    }
}
