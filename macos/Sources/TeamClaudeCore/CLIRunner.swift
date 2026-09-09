import Foundation

public struct CLIResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    /// The last non-empty stderr lines, which is where the CLI puts its reason.
    public var failureMessage: String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.isEmpty { return timedOut ? "timed out" : "exit code \(exitCode)" }
        return lines.suffix(3).joined(separator: " ")
    }
}

public enum CLIError: Error, Sendable, Equatable {
    case notFound
    case launch(String)
    case failed(CLIResult)
    case cancelled

    public var message: String {
        switch self {
        case .notFound: return "teamclaude CLI not found — set its path in Settings → Proxy"
        case .launch(let why): return "Could not start teamclaude: \(why)"
        case .failed(let r): return r.timedOut ? "teamclaude timed out" : r.failureMessage
        case .cancelled: return "cancelled"
        }
    }
}

public enum OutputLine: Sendable, Equatable {
    case out(String)
    case err(String)
    public var text: String { switch self { case .out(let s), .err(let s): return s } }
}

/// Runs `teamclaude <args>` as a child process. Both pipes are drained
/// concurrently (a full 64 KiB pipe would otherwise deadlock the child), stdin is
/// fed once and closed, and a timeout or task cancellation sends SIGTERM then
/// SIGKILL. Output lines can be streamed to a sheet as they arrive.
public actor CLIRunner {
    public let location: CLILocation?

    public init(location: CLILocation?) { self.location = location }

    public func run(_ args: [String], stdin: String? = nil, timeout: TimeInterval = 30,
                    onLine: (@Sendable (OutputLine) -> Void)? = nil) async throws -> CLIResult {
        guard let location else { throw CLIError.notFound }
        return try await CLIRunner.execute(executable: location.executable, arguments: location.leadingArguments + args,
                                           environment: CLIRunner.environment(for: location), stdin: stdin, timeout: timeout, onLine: onLine)
    }

    /// The child's environment: the LaunchAgent's PATH/config when known, and never an npm self-update.
    public static func environment(for location: CLILocation) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in location.environment { env[k] = v }
        if env["PATH"] == nil { env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
        env["TEAMCLAUDE_DISABLE_AUTOUPDATE"] = "1"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }

    public static func execute(executable: URL, arguments: [String], environment: [String: String], stdin: String? = nil,
                               timeout: TimeInterval = 30, onLine: (@Sendable (OutputLine) -> Void)? = nil) async throws -> CLIResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLIResult, Error>) in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = environment
                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = inPipe
                let collector = OutputCollector(onLine: onLine)
                outPipe.fileHandleForReading.readabilityHandler = { h in collector.feed(h.availableData, err: false) }
                errPipe.fileHandleForReading.readabilityHandler = { h in collector.feed(h.availableData, err: true) }
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.feed(outPipe.fileHandleForReading.readDataToEndOfFile(), err: false)
                    collector.feed(errPipe.fileHandleForReading.readDataToEndOfFile(), err: true)
                    collector.flush()
                    let (out, err) = collector.snapshot()
                    let timedOut = box.finish()
                    cont.resume(returning: CLIResult(exitCode: p.terminationStatus, stdout: out, stderr: err, timedOut: timedOut))
                }
                do { try process.run() } catch {
                    cont.resume(throwing: CLIError.launch(error.localizedDescription))
                    return
                }
                box.set(process)
                if let stdin {
                    inPipe.fileHandleForWriting.write(Data((stdin + "\n").utf8))
                }
                try? inPipe.fileHandleForWriting.close()
                box.armTimeout(timeout)
            }
        } onCancel: {
            box.kill()
        }
    }
}

/// Process handle shared between the continuation, the timeout timer and cancellation.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var timer: DispatchSourceTimer?
    private var timedOut = false
    private var finished = false

    func set(_ p: Process) { lock.lock(); process = p; lock.unlock() }

    func armTimeout(_ seconds: TimeInterval) {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + seconds)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.timedOut = !self.finished; self.lock.unlock()
            self.kill()
        }
        t.resume()
        lock.lock(); timer = t; lock.unlock()
    }

    /// SIGTERM, then SIGKILL two seconds later if still alive.
    func kill() {
        lock.lock(); let p = process; let done = finished; lock.unlock()
        guard let p, !done, p.isRunning else { return }
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
        }
    }

    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        finished = true
        timer?.cancel()
        return timedOut
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    private var outLine = Data(), errLine = Data()
    private let onLine: (@Sendable (OutputLine) -> Void)?

    init(onLine: (@Sendable (OutputLine) -> Void)?) { self.onLine = onLine }

    func feed(_ data: Data, err isErr: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isErr { err.append(data) } else { out.append(data) }
        var lines: [OutputLine] = []
        if onLine != nil {
            var buf = isErr ? errLine : outLine
            buf.append(data)
            while let nl = buf.firstIndex(of: 0x0a) {
                let line = String(decoding: buf[buf.startIndex..<nl], as: UTF8.self)
                lines.append(isErr ? .err(line) : .out(line))
                buf.removeSubrange(buf.startIndex...nl)
            }
            if isErr { errLine = buf } else { outLine = buf }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    /// A trailing partial line (a prompt without a newline) is still worth showing.
    func flush() {
        lock.lock()
        var lines: [OutputLine] = []
        if !outLine.isEmpty { lines.append(.out(String(decoding: outLine, as: UTF8.self))); outLine.removeAll() }
        if !errLine.isEmpty { lines.append(.err(String(decoding: errLine, as: UTF8.self))); errLine.removeAll() }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func snapshot() -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}
