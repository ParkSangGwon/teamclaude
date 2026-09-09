import Foundation
import XCTest
import TeamClaudeCore

final class ProxyLocatorTests: XCTestCase {
    private let exists: (String) -> Bool = { _ in true }

    func testBinSymlinkPlist() throws {
        let loc = try XCTUnwrap(ProxyLocator.fromLaunchAgent(plist: Fixtures.url("launchagent-bin-symlink.plist"), fileExists: exists))
        XCTAssertEqual(loc.node?.path, "/usr/local/bin/node")
        XCTAssertEqual(loc.entry.path, "/usr/local/bin/teamclaude")
        XCTAssertEqual(loc.environment, ["PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/ted"])
        XCTAssertEqual(loc.source, .launchAgent)
        XCTAssertNil(loc.configPathOverride)
        XCTAssertEqual(loc.executable.path, "/usr/local/bin/node")
        XCTAssertEqual(loc.leadingArguments, ["/usr/local/bin/teamclaude"])
        XCTAssertEqual(loc.describe, "/usr/local/bin/node /usr/local/bin/teamclaude")
    }

    func testEntryPlist() throws {
        let loc = try XCTUnwrap(ProxyLocator.fromLaunchAgent(plist: Fixtures.url("launchagent-entry.plist"), fileExists: exists))
        XCTAssertEqual(loc.node?.path, "/Users/ted/.nvm/versions/node/v24.13.1/bin/node")
        XCTAssertEqual(loc.entry.path, "/Users/ted/.nvm/versions/node/v24.13.1/lib/node_modules/teamclaude/src/index.js")
        XCTAssertTrue(loc.entry.path.hasSuffix("src/index.js"))
        XCTAssertEqual(loc.configPathOverride, "/Users/ted/.config/teamclaude-test.json")
        XCTAssertEqual(loc.environment["PATH"], "/Users/ted/.nvm/versions/node/v24.13.1/bin:/usr/local/bin:/usr/bin:/bin")
        XCTAssertEqual(loc.environment["HOME"], "/Users/ted")
        XCTAssertEqual(loc.source, .launchAgent)
    }

    func testBareExecutablePlist() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "tc-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appending(path: "bare.plist")
        let dict: [String: Any] = ["Label": "com.karpeleslab.teamclaude", "ProgramArguments": ["/opt/homebrew/bin/teamclaude", "server", "--headless"]]
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: plist)
        let loc = try XCTUnwrap(ProxyLocator.fromLaunchAgent(plist: plist, fileExists: exists))
        XCTAssertNil(loc.node)
        XCTAssertEqual(loc.entry.path, "/opt/homebrew/bin/teamclaude")
        XCTAssertEqual(loc.executable.path, "/opt/homebrew/bin/teamclaude")
        XCTAssertEqual(loc.leadingArguments, [])
        XCTAssertEqual(loc.environment, [:])
        XCTAssertEqual(loc.describe, "/opt/homebrew/bin/teamclaude")

        let short = dir.appending(path: "short.plist")
        try PropertyListSerialization.data(fromPropertyList: ["ProgramArguments": ["/only-one"]] as [String: Any], format: .xml, options: 0).write(to: short)
        XCTAssertNil(ProxyLocator.fromLaunchAgent(plist: short, fileExists: exists), "fewer than two arguments is not our plist")
        let garbage = dir.appending(path: "garbage.plist")
        try Data("not a plist".utf8).write(to: garbage)
        XCTAssertNil(ProxyLocator.fromLaunchAgent(plist: garbage, fileExists: exists))
    }

    func testMissingFilesGiveNil() {
        let plist = Fixtures.url("launchagent-bin-symlink.plist")
        XCTAssertNil(ProxyLocator.fromLaunchAgent(plist: plist, fileExists: { _ in false }))
        XCTAssertNil(ProxyLocator.fromLaunchAgent(plist: plist, fileExists: { $0 != "/usr/local/bin/teamclaude" }), "entry missing")
        XCTAssertNil(ProxyLocator.fromLaunchAgent(plist: plist, fileExists: { $0 != "/usr/local/bin/node" }), "node missing")
        XCTAssertNil(ProxyLocator.fromLaunchAgent(plist: URL(fileURLWithPath: "/nonexistent/agent.plist"), fileExists: exists))
    }

    func testLoginShellOutput() throws {
        let out = "/usr/local/bin/node\n/usr/local/bin/teamclaude\n/usr/local/bin:/usr/bin:/bin\n"
        let loc = try XCTUnwrap(ProxyLocator.fromLoginShellOutput(out, fileExists: exists))
        XCTAssertEqual(loc.node?.path, "/usr/local/bin/node")
        XCTAssertEqual(loc.entry.path, "/usr/local/bin/teamclaude")
        XCTAssertEqual(loc.environment, ["PATH": "/usr/local/bin:/usr/bin:/bin"])
        XCTAssertEqual(loc.source, .loginShell)

        // Shell noise before the answers, no node, spaces around lines.
        let noisy = "Welcome!\n  /opt/homebrew/bin/teamclaude  \n/opt/homebrew/bin:/usr/bin\n"
        let noNode = try XCTUnwrap(ProxyLocator.fromLoginShellOutput(noisy, fileExists: exists))
        XCTAssertNil(noNode.node)
        XCTAssertEqual(noNode.entry.path, "/opt/homebrew/bin/teamclaude")
        XCTAssertEqual(noNode.environment["PATH"], "/opt/homebrew/bin:/usr/bin")

        XCTAssertNil(ProxyLocator.fromLoginShellOutput("/usr/local/bin/node\n/usr/local/bin:/usr/bin\n", fileExists: exists), "no teamclaude")
        XCTAssertNil(ProxyLocator.fromLoginShellOutput(out, fileExists: { !$0.hasSuffix("/teamclaude") }), "teamclaude reported but gone")
        let nodeGone = try XCTUnwrap(ProxyLocator.fromLoginShellOutput(out, fileExists: { !$0.hasSuffix("/node") }))
        XCTAssertNil(nodeGone.node)
        XCTAssertNil(ProxyLocator.fromLoginShellOutput("", fileExists: exists))
        let noPath = try XCTUnwrap(ProxyLocator.fromLoginShellOutput("/usr/local/bin/teamclaude\n", fileExists: exists))
        XCTAssertEqual(noPath.environment, [:])
    }

    func testManualPath() throws {
        let loc = try XCTUnwrap(ProxyLocator.fromManualPath("~/bin/teamclaude", fileExists: exists))
        XCTAssertEqual(loc.entry.path, ("~/bin/teamclaude" as NSString).expandingTildeInPath)
        XCTAssertNil(loc.node)
        XCTAssertEqual(loc.source, .manual)
        XCTAssertNil(ProxyLocator.fromManualPath("", fileExists: exists))
        XCTAssertNil(ProxyLocator.fromManualPath("/x/teamclaude", fileExists: { _ in false }))
    }

    func testLaunchAgentAndLogPaths() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(ProxyLocator.launchAgentPath(home: home).path, "/Users/someone/Library/LaunchAgents/com.karpeleslab.teamclaude.plist")
        XCTAssertEqual(ProxyLocator.logPath(home: home).path, "/Users/someone/Library/Logs/teamclaude.log")
    }

    // MARK: service health

    func testServiceHealthParsesLaunchctlPrint() {
        let h = ServiceHealth.parse(launchctlPrint: Fixtures.text("launchctl-crashloop.txt"), installed: true)
        XCTAssertTrue(h.installed)
        XCTAssertTrue(h.loaded)
        XCTAssertEqual(h.pid, 81892)
        XCTAssertEqual(h.runs, 9212)
        XCTAssertEqual(h.lastExitCode, 1)
        XCTAssertEqual(h.state, "running")
        XCTAssertFalse(h.crashLooping, "a live pid in state running is not a loop, however many runs")

        let notLoaded = ServiceHealth.parse(launchctlPrint: nil, installed: true)
        XCTAssertEqual(notLoaded, ServiceHealth(installed: true, loaded: false))
        let empty = ServiceHealth.parse(launchctlPrint: "", installed: false)
        XCTAssertEqual(empty, ServiceHealth(installed: false, loaded: true, pid: nil, runs: nil, lastExitCode: nil, state: nil))
        let negative = ServiceHealth.parse(launchctlPrint: "\tstate = waiting\n\truns = 12\n\tlast exit code = -1\n", installed: true)
        XCTAssertEqual(negative.lastExitCode, -1)
        XCTAssertEqual(negative.state, "waiting")
        XCTAssertNil(negative.pid)
        XCTAssertTrue(negative.crashLooping)
    }

    func testCrashLoopingRule() {
        func health(pid: Int?, runs: Int?, exit: Int?, state: String?, loaded: Bool = true) -> ServiceHealth {
            ServiceHealth(installed: true, loaded: loaded, pid: pid, runs: runs, lastExitCode: exit, state: state)
        }
        XCTAssertTrue(health(pid: nil, runs: 5, exit: 1, state: "waiting").crashLooping)
        XCTAssertTrue(health(pid: 77, runs: 9, exit: 1, state: "spawn scheduled").crashLooping, "a pid that is not in state running")
        XCTAssertFalse(health(pid: 77, runs: 9, exit: 1, state: "running").crashLooping)
        XCTAssertFalse(health(pid: nil, runs: 4, exit: 1, state: "waiting").crashLooping, "fewer than five runs")
        XCTAssertFalse(health(pid: nil, runs: 9, exit: 0, state: "waiting").crashLooping, "clean exits")
        XCTAssertFalse(health(pid: nil, runs: nil, exit: 1, state: nil).crashLooping)
        XCTAssertFalse(health(pid: nil, runs: 9, exit: 1, state: "waiting", loaded: false).crashLooping)
    }

    func testPortOwnerParse() throws {
        let owner = try XCTUnwrap(PortOwner.parse(lsofFields: "p4090\ncnode\n"))
        XCTAssertEqual(owner.pid, 4090)
        XCTAssertEqual(owner.command, "node")
        XCTAssertEqual(PortOwner.parse(lsofFields: "p4090\ncnode\np5000\ncother\n"), owner, "the first listener")
        let bare = try XCTUnwrap(PortOwner.parse(lsofFields: "p4090\n"))
        XCTAssertEqual(bare.pid, 4090)
        XCTAssertEqual(bare.command, "")
        XCTAssertNil(PortOwner.parse(lsofFields: ""))
        XCTAssertNil(PortOwner.parse(lsofFields: "cnode\n"))
        XCTAssertNil(PortOwner.parse(lsofFields: "pabc\n"))
    }

    func testDiagnosisMatrix() throws {
        let owner = try XCTUnwrap(PortOwner.parse(lsofFields: "p4090\ncnode\n"))
        XCTAssertEqual(ServiceDiagnosis.diagnose(health: ServiceHealth(installed: false, loaded: false), portOwner: owner), .notInstalled)
        XCTAssertEqual(ServiceDiagnosis.diagnose(health: ServiceHealth(installed: true, loaded: false), portOwner: owner), .notLoaded)
        let running = ServiceHealth(installed: true, loaded: true, pid: 4090, runs: 3, lastExitCode: 0, state: "running")
        XCTAssertEqual(ServiceDiagnosis.diagnose(health: running, portOwner: owner), .healthy(pid: 4090))
        XCTAssertEqual(ServiceDiagnosis.diagnose(health: running, portOwner: nil), .healthy(pid: 4090), "no lsof answer, but a pid")
        let other = ServiceHealth(installed: true, loaded: true, pid: 5555, runs: 3, lastExitCode: 0, state: "running")
        XCTAssertEqual(ServiceDiagnosis.diagnose(health: other, portOwner: owner), .portHeldElsewhere(ownerPid: 4090, ownerCommand: "node", runs: 3))
        let looping = ServiceHealth(installed: true, loaded: true, pid: nil, runs: 9212, lastExitCode: 1, state: "waiting")
        XCTAssertEqual(ServiceDiagnosis.diagnose(health: looping, portOwner: owner), .portHeldElsewhere(ownerPid: 4090, ownerCommand: "node", runs: 9212), "someone else on the port explains the loop")
        XCTAssertEqual(ServiceDiagnosis.diagnose(health: looping, portOwner: nil), .crashLooping(runs: 9212, lastExitCode: 1))
        let stopped = ServiceHealth(installed: true, loaded: true, pid: nil, runs: 1, lastExitCode: 0, state: "waiting")
        XCTAssertEqual(ServiceDiagnosis.diagnose(health: stopped, portOwner: nil), .stopped)
    }

    func testDiagnosisText() {
        XCTAssertEqual(ServiceDiagnosis.healthy(pid: 7).text, "Service running (pid 7)")
        XCTAssertEqual(ServiceDiagnosis.portHeldElsewhere(ownerPid: 4090, ownerCommand: "node", runs: 3).text, "Port is served by another process (node, pid 4090); the LaunchAgent cannot start (3 attempts)")
        XCTAssertEqual(ServiceDiagnosis.portHeldElsewhere(ownerPid: 4090, ownerCommand: "", runs: nil).text, "Port is served by another process (pid 4090); the LaunchAgent cannot start")
        XCTAssertEqual(ServiceDiagnosis.crashLooping(runs: 9212, lastExitCode: 1).text, "Service is crash-looping (9212 runs, last exit 1)")
        XCTAssertEqual(ServiceDiagnosis.crashLooping(runs: nil, lastExitCode: nil).text, "Service is crash-looping)")
        XCTAssertEqual(ServiceDiagnosis.stopped.text, "Service loaded but not running")
        XCTAssertEqual(ServiceDiagnosis.notLoaded.text, "Service installed but not loaded")
        XCTAssertTrue(ServiceDiagnosis.notInstalled.text.hasPrefix("Service not installed"))
    }
}
