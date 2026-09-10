import Foundation
import XCTest
import TeamClaudeCore

final class UpdateCheckTests: XCTestCase {
    func testInstalledVersionFromUpdateOutput() {
        XCTAssertEqual(UpdateCheck.installedVersion(fromUpdateOutput: "Current version: 1.1.16\nUpdating 1.1.16 → 1.1.18 …\nUpdated to 1.1.18. Restart teamclaude to use the new version.\n"), "1.1.18")
        XCTAssertNil(UpdateCheck.installedVersion(fromUpdateOutput: "Current version: 1.1.18\nAlready up to date (latest is 1.1.18).\n"))
        XCTAssertNil(UpdateCheck.installedVersion(fromUpdateOutput: "This is a git checkout — update it with `git pull`, not npm.\n"))
        XCTAssertNil(UpdateCheck.installedVersion(fromUpdateOutput: ""))
    }
}
