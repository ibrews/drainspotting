import Foundation
import DrainspottingKit

// drainspot — the free CLI companion to Drainspotting.app
// Reads the same local power logs and prints a battery autopsy in the terminal.

let arguments = CommandLine.arguments.dropFirst()
var wantJSON = false
var wantLive = false
var sessionCount = 1
var showAll = false

var iterator = arguments.makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--json": wantJSON = true
    case "--live": wantLive = true
    case "--all": showAll = true
    case "--sessions":
        if let v = iterator.next(), let n = Int(v), n > 0 { sessionCount = min(n, 50) }
    case "--version":
        print("drainspot 1.0.1")
        exit(0)
    case "-h", "--help":
        print("""
        drainspot — battery autopsy for your Mac (companion CLI to Drainspotting.app)

        USAGE:
          drainspot                 Autopsy of the most recent battery session
          drainspot --sessions 5    Show the last 5 battery sessions
          drainspot --live          What is keeping the Mac awake right now
          drainspot --all           Include macOS-internal assertions
          drainspot --json          Machine-readable output

        All data comes from your Mac's own power log (pmset). Nothing leaves the machine.
        https://github.com/ibrews/drainspotting
        """)
        exit(0)
    default:
        FileHandle.standardError.write("unknown option: \(argument)\n".data(using: .utf8)!)
        exit(2)
    }
}

let useColor = ProcessInfo.processInfo.environment["NO_COLOR"] == nil && isatty(1) != 0
func style(_ text: String, _ code: String) -> String {
    useColor ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
}
func bold(_ t: String) -> String { style(t, "1") }
func dim(_ t: String) -> String { style(t, "2") }
func red(_ t: String) -> String { style(t, "31") }
func yellow(_ t: String) -> String { style(t, "33") }
func green(_ t: String) -> String { style(t, "32") }
func cyan(_ t: String) -> String { style(t, "36") }

let shortTime: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d HH:mm"
    return f
}()

func severityMark(_ severity: CulpritExplanation.Severity) -> String {
    switch severity {
    case .heavy: return red("●")
    case .notable: return yellow("●")
    case .info: return dim("○")
    }
}

func printCulprits(_ culprits: [Culprit], limit: Int = 8) {
    if culprits.isEmpty {
        print(dim("  No sleep-blocking apps recorded in this window."))
        return
    }
    for (index, culprit) in culprits.prefix(limit).enumerated() {
        let held = Humanizer.duration(culprit.awakeHeldSeconds)
        print("  \(index + 1). \(severityMark(culprit.explanation.severity)) \(bold(culprit.displayName))  \(dim(Humanizer.midSentence(culprit.explanation.title)))  \(cyan(held))")
        if culprit.explanation.severity >= .notable {
            print("     \(dim(culprit.explanation.meaning))")
            if let suggestion = culprit.explanation.suggestion {
                print("     \(green("fix:")) \(suggestion)")
            }
        }
    }
}

struct JSONCulprit: Codable {
    let process: String, displayName: String, assertionType: String
    let heldSeconds: Double, awakeHeldSeconds: Double
    let severity: Int, meaning: String, suggestion: String?
}
struct JSONSession: Codable {
    let start: Date, end: Date, startPercent: Int, endPercent: Int
    let ongoing: Bool, awakeSeconds: Double, asleepSeconds: Double, darkWakeSeconds: Double
    let awakeDropPercent: Double, asleepDropPercent: Double, wakeCount: Int
    let culprits: [JSONCulprit]
}

func jsonCulprits(_ culprits: [Culprit]) -> [JSONCulprit] {
    culprits.map {
        JSONCulprit(process: $0.process, displayName: $0.displayName,
                    assertionType: $0.assertionType, heldSeconds: $0.heldSeconds,
                    awakeHeldSeconds: $0.awakeHeldSeconds,
                    severity: $0.explanation.severity.rawValue,
                    meaning: $0.explanation.meaning, suggestion: $0.explanation.suggestion)
    }
}

let provider = PowerDataProvider()
let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    defer { semaphore.signal() }
    do {
        if wantLive {
            let live = try await provider.captureLiveAssertions()
            let battery = try? await provider.captureBattery()

            if wantJSON {
                struct JSONLive: Codable {
                    let capturedAt: Date, batteryPercent: Int?, charging: Bool
                    let assertions: [JSONAssertion], kernelAssertions: [String]
                }
                struct JSONAssertion: Codable {
                    let pid: Int, process: String, type: String, name: String, heldSeconds: Double
                }
                let payload = JSONLive(
                    capturedAt: live.capturedAt,
                    batteryPercent: battery?.percent,
                    charging: battery?.isCharging ?? false,
                    assertions: live.assertions.map {
                        JSONAssertion(pid: $0.pid, process: $0.process, type: $0.type,
                                      name: $0.name, heldSeconds: $0.heldSeconds)
                    },
                    kernelAssertions: live.kernelAssertions)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(data: try encoder.encode(payload), encoding: .utf8)!)
                return
            }

            print(bold("⚡ Drainspotting — live sleep blockers"))
            if let battery, let pct = battery.percent {
                let chargeState = battery.isCharging ? "charging" : (battery.externalPowerConnected ? "on AC" : "on battery")
                print(dim("Battery \(pct)% · \(chargeState)"))
            }
            print("")
            let interesting = live.assertions.filter { Humanizer.sleepPreventingTypes.contains($0.type) || showAll }
            if interesting.isEmpty {
                print(green("Nothing is blocking sleep right now."))
            } else {
                for assertion in interesting.sorted(by: { $0.heldSeconds > $1.heldSeconds }) {
                    let (display, explanation, internalFlag) = Humanizer.explain(
                        process: assertion.process, assertionType: assertion.type,
                        assertionName: assertion.name, heldSeconds: assertion.heldSeconds,
                        windowSeconds: max(assertion.heldSeconds, 3600))
                    if internalFlag && !showAll { continue }
                    print("  \(severityMark(explanation.severity)) \(bold(display)) \(dim("(\(assertion.process), pid \(assertion.pid))")) — \(Humanizer.midSentence(explanation.title)) for \(cyan(Humanizer.duration(assertion.heldSeconds)))")
                }
            }
            if !live.kernelAssertions.isEmpty {
                print(dim("\nKernel: \(live.kernelAssertions.joined(separator: ", "))"))
            }
            return
        }

        FileHandle.standardError.write(dim("Reading the power log (pmset takes ~10s)…\n").data(using: .utf8)!)
        let report = try await provider.captureReport()

        let sessions = Array(report.sessions.prefix(sessionCount))
        if sessions.isEmpty {
            print("No battery discharge sessions found in the log.")
            print(dim("This Mac may be a desktop, or it hasn't run on battery recently."))
            return
        }

        if wantJSON {
            let payload = sessions.map { session -> JSONSession in
                let culprits = CulpritAnalyzer.culprits(in: session.interval, report: report,
                                                        includeSystemInternal: showAll)
                return JSONSession(
                    start: session.interval.start, end: session.interval.end,
                    startPercent: session.startPercent, endPercent: session.endPercent,
                    ongoing: session.ongoing,
                    awakeSeconds: session.seconds(in: .awake),
                    asleepSeconds: session.seconds(in: .asleep),
                    darkWakeSeconds: session.seconds(in: .darkWake),
                    awakeDropPercent: session.dropByState[.awake] ?? 0,
                    asleepDropPercent: session.dropByState[.asleep] ?? 0,
                    wakeCount: session.wakes.count,
                    culprits: jsonCulprits(culprits))
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: try encoder.encode(payload), encoding: .utf8)!)
            return
        }

        print(bold("⚡ Drainspotting — battery autopsy"))
        for session in sessions {
            let start = shortTime.string(from: session.interval.start)
            let end = session.ongoing ? "now" : shortTime.string(from: session.interval.end)
            let header = "\(start) → \(end)  (\(Humanizer.duration(session.duration)))"
            print("\n\(bold(header))")
            print("  \(bold("\(session.startPercent)% → \(session.endPercent)%"))  (−\(session.totalDropPercent)%)\(session.ongoing ? dim("  · still on battery") : "")")

            var parts: [String] = []
            for state in [SystemPowerState.awake, .asleep, .darkWake] {
                let secs = session.seconds(in: state)
                guard secs > 60 else { continue }
                let drop = session.dropByState[state] ?? 0
                let label = state == .awake ? "Awake" : state == .asleep ? "Asleep" : "DarkWake"
                var piece = "\(label) \(Humanizer.duration(secs)) (−\(String(format: "%.1f", drop))%"
                if let rate = session.drainRatePerHour(in: state) {
                    piece += ", \(String(format: "%.1f", rate))%/h"
                }
                piece += ")"
                parts.append(piece)
            }
            print("  " + parts.joined(separator: " · "))

            if !session.wakes.isEmpty {
                var causeCounts: [String: Int] = [:]
                for wake in session.wakes {
                    let title = Humanizer.describeWakeCause(wake.rawCause, matchedRequest: wake.matchedRequest).title
                    causeCounts[title, default: 0] += 1
                }
                let summary = causeCounts.sorted { $0.value > $1.value }
                    .map { "\($0.value)× \(Humanizer.midSentence($0.key))" }
                    .joined(separator: ", ")
                print("  \(dim("Wakes: \(session.wakes.count) (\(summary))"))")
            }

            print("\n  \(bold("Top culprits:"))")
            let culprits = CulpritAnalyzer.culprits(in: session.interval, report: report,
                                                    includeSystemInternal: showAll)
            printCulprits(culprits)
        }
        print(dim("\nAll analysis is local — nothing leaves this Mac. Full timelines: Drainspotting.app"))
    } catch {
        FileHandle.standardError.write(red("error: \(error)\n").data(using: .utf8)!)
        exitCode = 1
    }
}

semaphore.wait()
exit(exitCode)
