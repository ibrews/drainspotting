import Foundation

/// Runs a system command and returns stdout. Injectable so tests use fixtures.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> String
}

public struct CommandError: Error, CustomStringConvertible {
    public let executable: String
    public let underlying: String
    public var description: String { "\(executable) failed: \(underlying)" }
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: CommandError(
                        executable: executable, underlying: error.localizedDescription))
                    return
                }
                // Read fully before waiting to avoid pipe-buffer deadlock on large output.
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: CommandError(
                        executable: executable,
                        underlying: "exit code \(process.terminationStatus)"))
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}

/// Central data source: fetches raw system data and produces parsed results.
public actor PowerDataProvider {
    private let runner: CommandRunning

    public init(runner: CommandRunning = SystemCommandRunner()) {
        self.runner = runner
    }

    /// Full historical report. Slow (~10–15s) because `pmset -g log` itself is slow;
    /// callers should show progress and cache the result.
    public func captureReport(now: Date = Date()) async throws -> PowerReport {
        let logText = try await runner.run("/usr/bin/pmset", arguments: ["-g", "log"])
        let events = PMSetLogParser.parse(logText)
        return SessionBuilder.buildReport(events: events, now: now)
    }

    /// Live snapshot of currently-held assertions. Fast (<1s).
    public func captureLiveAssertions() async throws -> LiveAssertionsState {
        let text = try await runner.run("/usr/bin/pmset", arguments: ["-g", "assertions"])
        return AssertionsParser.parse(text)
    }

    /// Current battery snapshot. Fast (<1s).
    public func captureBattery() async throws -> BatterySnapshot {
        let xml = try await runner.run("/usr/sbin/ioreg", arguments: ["-arn", "AppleSmartBattery"])
        return BatterySampler.parse(ioregPlistXML: xml)
    }
}
