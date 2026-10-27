import XCTest
@testable import DrainspottingKit

// MARK: - Helpers

private let baseDate: Date = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return f.date(from: "2026-07-20 08:00:00 -0700")!
}()

private func minutes(_ m: Double) -> Date { baseDate.addingTimeInterval(m * 60) }

private func fixture(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw XCTSkip("fixture \(name) missing")
    }
    return try String(contentsOf: url, encoding: .utf8)
}

private func event(_ atMinutes: Double, _ kind: LogEventKind,
                   charge: (Int, PowerSource)? = nil) -> PowerLogEvent {
    PowerLogEvent(
        time: minutes(atMinutes),
        kind: kind,
        charge: charge.map { ChargeAnnotation(percent: $0.0, source: $0.1) },
        raw: nil)
}

// MARK: - Parser tests

final class PMSetLogParserTests: XCTestCase {

    func testParsesRealFixtureBroadly() throws {
        let text = try fixture("pmset_log_real.txt")
        let events = PMSetLogParser.parse(text)
        XCTAssertGreaterThan(events.count, 100, "expected substantial event count from real log")

        var sleeps = 0, wakes = 0, darkWakes = 0, edges = 0, summaries = 0
        for e in events {
            switch e.kind {
            case .sleep: sleeps += 1
            case .wake: wakes += 1
            case .darkWake: darkWakes += 1
            case .assertionEdge: edges += 1
            case .assertionSummary: summaries += 1
            default: break
            }
        }
        XCTAssertGreaterThan(sleeps, 0)
        XCTAssertGreaterThan(wakes + darkWakes, 0)
        XCTAssertGreaterThan(edges, 0)
        XCTAssertGreaterThan(summaries, 0)

        // Strict chronological order after parse.
        for i in 1..<events.count {
            XCTAssertLessThanOrEqual(events[i - 1].time, events[i].time)
        }
    }

    func testSleepLine() throws {
        let line = "2026-07-23 00:56:03 -0700 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:51%) 642 secs  "
        let e = try XCTUnwrap(PMSetLogParser.parseLine(line))
        guard case .sleep(let reason) = e.kind else { return XCTFail("kind \(e.kind)") }
        XCTAssertEqual(reason, "Maintenance Sleep")
        XCTAssertEqual(e.charge?.percent, 51)
        XCTAssertEqual(e.charge?.source, .battery)
    }

    func testWakeLine() throws {
        let line = "2026-07-23 01:06:45 -0700 Wake                \tWake from Deep Idle [CDNVA] : due to smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty/HID Activity Using BATT (Charge:51%)           "
        let e = try XCTUnwrap(PMSetLogParser.parseLine(line))
        guard case .wake(let cause, let tag) = e.kind else { return XCTFail("kind \(e.kind)") }
        XCTAssertEqual(tag, "CDNVA")
        XCTAssertTrue(cause.contains("lid"))
        XCTAssertFalse(cause.contains("Using"), "charge annotation must be stripped from cause")
        XCTAssertEqual(e.charge?.percent, 51)
    }

    func testDarkWakeLine() throws {
        let line = "2026-07-23 00:49:21 -0700 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB.SPMISw3IRQ nub-spmi0.0x02 rtc/SleepService Using BATT (Charge:51%) 2 secs    "
        let e = try XCTUnwrap(PMSetLogParser.parseLine(line))
        guard case .darkWake(let cause, let tag) = e.kind else { return XCTFail("kind \(e.kind)") }
        XCTAssertEqual(tag, "CDNP")
        XCTAssertTrue(cause.contains("rtc/SleepService"))
        XCTAssertFalse(cause.contains("secs"))
    }

    func testAssertionCreatedLine() throws {
        let line = "2026-07-16 02:31:48 -0700 Assertions          \tPID 74603(chrome-headless-shell) Created NoDisplaySleepAssertion \"Capturing\" 00:00:00  id:0x0x500009279 [System: PrevIdle PrevDisp DeclUser IntPrevDisp kDisp]          "
        let e = try XCTUnwrap(PMSetLogParser.parseLine(line))
        guard case .assertionEdge(let edge) = e.kind else { return XCTFail("kind \(e.kind)") }
        XCTAssertEqual(edge.action, .created)
        XCTAssertEqual(edge.pid, 74603)
        XCTAssertEqual(edge.process, "chrome-headless-shell")
        XCTAssertEqual(edge.type, "NoDisplaySleepAssertion")
        XCTAssertEqual(edge.name, "Capturing")
        XCTAssertEqual(edge.heldSeconds, 0)
        XCTAssertEqual(edge.assertionID, "0x0x500009279")
    }

    func testAssertionReleasedLineWithDuration() throws {
        let line = "2026-07-16 02:31:54 -0700 Assertions          \tPID 736(coreaudiod) Released PreventUserIdleSystemSleep \"com.apple.audio.context32978.preventuseridlesleep\" 00:15:03  id:0x0x100008a81 [System: PrevIdle DeclUser IntPrevDisp kDisp]          "
        let e = try XCTUnwrap(PMSetLogParser.parseLine(line))
        guard case .assertionEdge(let edge) = e.kind else { return XCTFail("kind \(e.kind)") }
        XCTAssertEqual(edge.action, .released)
        XCTAssertEqual(edge.heldSeconds, 903)
    }

    func testMultiDayHeldDuration() throws {
        let edge = PMSetLogParser.parseAssertionEdge(
            "PID 388(EpicGamesLauncher) Released PreventUserIdleSystemSleep \"Running dedicated server\" 66:06:26  id:0x0xdeadbeef")
        XCTAssertEqual(edge?.heldSeconds, TimeInterval(66 * 3600 + 6 * 60 + 26))
    }

    func testSummaryLine() throws {
        let line = "2026-07-23 02:22:34 -0700 Assertions          \tSummary- [System: PrevIdle DeclUser SysAct SRPrevSleep IntPrevDisp kCPU kDisp] Using AC(Charge: 51)          "
        let e = try XCTUnwrap(PMSetLogParser.parseLine(line))
        guard case .assertionSummary(let flags) = e.kind else { return XCTFail("kind \(e.kind)") }
        XCTAssertTrue(flags.contains("PrevIdle"))
        XCTAssertEqual(e.charge?.percent, 51)
        XCTAssertEqual(e.charge?.source, .ac)
    }

    func testWakeRequestsLine() throws {
        let line = "2026-07-23 00:56:32 -0700 Wake Requests       \t[process=mDNSResponder request=Maintenance deltaSecs=6448 wakeAt=2026-07-23 02:44:00 info=\"DHCP lease renewal\"] [*process=dasd request=SleepService deltaSecs=958 wakeAt=2026-07-23 01:12:30 info=\"com.apple.dasd:502:task\"] [process=powerd request=TCPKATurnOff deltaSecs=183011 wakeAt=2026-07-25 03:46:43]           "
        let e = try XCTUnwrap(PMSetLogParser.parseLine(line))
        guard case .wakeRequests(let requests) = e.kind else { return XCTFail("kind \(e.kind)") }
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].process, "mDNSResponder")
        XCTAssertEqual(requests[0].info, "DHCP lease renewal")
        XCTAssertNotNil(requests[0].wakeAt)
        XCTAssertEqual(requests[1].process, "dasd", "starred entries must parse")
        XCTAssertNil(requests[2].info)
    }

    func testChargeAnnotationVariants() {
        XCTAssertEqual(PMSetLogParser.parseCharge("x Using AC(Charge: 7) y")?.source, .ac)
        XCTAssertEqual(PMSetLogParser.parseCharge("x Using AC(Charge: 7) y")?.percent, 7)
        XCTAssertEqual(PMSetLogParser.parseCharge("Using Batt (Charge:51%)")?.source, .battery)
        XCTAssertEqual(PMSetLogParser.parseCharge("Using BATT (Charge:100%)")?.percent, 100)
        XCTAssertNil(PMSetLogParser.parseCharge("no annotation here"))
    }

    func testIgnoresContinuationAndGarbage() {
        XCTAssertNil(PMSetLogParser.parseLine("   pid 646(coreaudiod): [0x1] 00:25:29 PreventUserIdleSystemSleep named: \"x\""))
        XCTAssertNil(PMSetLogParser.parseLine(""))
        XCTAssertNil(PMSetLogParser.parseLine("Total internal assertions: 12"))
        XCTAssertNil(PMSetLogParser.parseLine("2026-07-23"))
    }

    func testEmptyInput() {
        XCTAssertEqual(PMSetLogParser.parse("").count, 0)
    }

    /// The hand-rolled timestamp decoder must agree with DateFormatter
    /// byte-for-byte on every shape pmset emits, including negative and
    /// half-hour offsets, leap days, year boundaries, and midnight.
    func testFastTimestampMatchesDateFormatter() {
        let samples = [
            "2026-07-23 00:56:03 -0700", "2026-10-27 11:52:21 -0700", "2024-02-29 23:59:59 +0000",
            "2025-12-31 23:59:59 -0500", "2026-01-01 00:00:00 +0100", "2026-06-15 12:30:00 +0530",
            "2026-03-08 02:30:00 -0800", "2026-11-01 01:30:00 -0700", "1999-01-01 00:00:00 +0000",
            "2026-10-27 18:00:00 -1000", "2026-10-27 18:00:00 +1345",
        ]
        for s in samples {
            let expected = PMSetLogParser.dateFormatter.date(from: s)
            XCTAssertNotNil(expected, s)
            XCTAssertEqual(PMSetLogParser.parseTimestamp(s), expected, s)
        }
    }

    func testFastTimestampRejectsOddShapes() {
        // Anything not exactly the 25-byte pmset shape falls through to the
        // formatter (or nil) instead of silently producing a wrong date.
        XCTAssertNil(PMSetLogParser.parseTimestamp("2026-10-27 11:52:21 -070"))
        XCTAssertNil(PMSetLogParser.parseTimestamp("2026-10-27T11:52:21 -0700"))
        XCTAssertNil(PMSetLogParser.parseTimestamp("2026-13-27 11:52:21 -0700"))
        XCTAssertNil(PMSetLogParser.parseTimestamp("2026-10-27 24:52:21 -0700"))
        XCTAssertNil(PMSetLogParser.parseTimestamp("2026-10-27 11:52:21 x0700"))
        XCTAssertNil(PMSetLogParser.parseTimestamp("２026-10-27 11:52:21 -0700")) // full-width digit
    }
}

// MARK: - Live assertions parser

final class AssertionsParserTests: XCTestCase {

    func testParsesRealFixture() throws {
        let text = try fixture("pmset_assertions_real.txt")
        let state = AssertionsParser.parse(text)
        XCTAssertGreaterThan(state.assertions.count, 0)
        let audio = state.assertions.first { $0.process == "coreaudiod" }
        XCTAssertNotNil(audio)
        XCTAssertNotNil(audio?.createdForPID, "coreaudiod entries carry Created for PID")
    }

    func testParsesSynthetic() {
        let text = """
        2026-07-23 02:29:25 -0700
        Assertion status system-wide:
           PreventUserIdleSystemSleep     1
        Listed by owning process:
           pid 646(coreaudiod): [0x0001968c00018b1d] 00:25:29 PreventUserIdleSystemSleep named: "com.apple.audio.ctx.preventuseridlesleep"
        \tCreated for PID: 8567.
        \tResources: audio-out BuiltInSpeakerDevice
           pid 27467(Claude): [0x0001898d0001a6b9] 01:20:53 NoIdleSleepAssertion named: "Electron"
        Kernel Assertions: 0x104=USB,MAGICWAKE
        """
        let state = AssertionsParser.parse(text)
        XCTAssertEqual(state.assertions.count, 2)
        XCTAssertEqual(state.assertions[0].createdForPID, 8567)
        XCTAssertEqual(state.assertions[0].heldSeconds, 25 * 60 + 29)
        XCTAssertEqual(state.assertions[1].process, "Claude")
        XCTAssertEqual(state.assertions[1].heldSeconds, 3600 + 20 * 60 + 53)
        XCTAssertEqual(state.kernelAssertions, ["USB", "MAGICWAKE"])
    }
}

// MARK: - Battery sampler

final class BatterySamplerTests: XCTestCase {

    func testParsesRealTextFixture() throws {
        let text = try fixture("ioreg_battery_real.txt")
        let snapshot = BatterySampler.parse(ioregText: text)
        XCTAssertTrue(snapshot.hasBattery)
        XCTAssertNotNil(snapshot.percent)
        XCTAssertNotNil(snapshot.cycleCount)
        if let health = snapshot.healthFraction {
            XCTAssertGreaterThan(health, 0.3)
            XCTAssertLessThanOrEqual(health, 1.2)
        }
    }

    func testNoBattery() {
        let snapshot = BatterySampler.parse(ioregText: "")
        XCTAssertFalse(snapshot.hasBattery)
    }
}

// MARK: - Session builder

final class SessionBuilderTests: XCTestCase {

    /// 10-hour scenario: awake hour, long sleep with a dark wake, morning use, plug in.
    private func makeScenario() -> [PowerLogEvent] {
        [
            event(0, .wake(cause: "lid", tag: nil), charge: (100, .battery)),
            event(30, .assertionSummary(flags: ["PrevIdle"]), charge: (95, .battery)),
            event(60, .sleep(reason: "Clamshell Sleep"), charge: (93, .battery)),
            event(300, .darkWake(cause: "rtc/SleepService", tag: "CDNP"), charge: (92, .battery)),
            event(302, .sleep(reason: "Maintenance Sleep"), charge: (92, .battery)),
            event(540, .wake(cause: "lid HID Activity", tag: "CDNVA"), charge: (90, .battery)),
            event(600, .assertionSummary(flags: ["PrevIdle"]), charge: (85, .battery)),
            event(601, .assertionSummary(flags: ["PrevIdle"]), charge: (85, .ac)),
        ]
    }

    func testSessionSegmentation() {
        let report = SessionBuilder.buildReport(events: makeScenario(), now: minutes(602))
        XCTAssertEqual(report.sessions.count, 1)
        let session = report.sessions[0]
        XCTAssertEqual(session.startPercent, 100)
        XCTAssertEqual(session.endPercent, 85)
        XCTAssertEqual(session.totalDropPercent, 15)
        XCTAssertTrue(session.endedByPlugIn)
        XCTAssertFalse(session.ongoing)
        XCTAssertEqual(session.interval.start, minutes(0))
        XCTAssertEqual(session.interval.end, minutes(601))
    }

    func testStateBreakdown() {
        let report = SessionBuilder.buildReport(events: makeScenario(), now: minutes(602))
        let session = report.sessions[0]
        XCTAssertEqual(session.seconds(in: .awake), TimeInterval((60 + 61) * 60), accuracy: 1)
        XCTAssertEqual(session.seconds(in: .asleep), TimeInterval((240 + 238) * 60), accuracy: 1)
        XCTAssertEqual(session.seconds(in: .darkWake), TimeInterval(2 * 60), accuracy: 1)
    }

    func testDropAllocation() {
        let report = SessionBuilder.buildReport(events: makeScenario(), now: minutes(602))
        let session = report.sessions[0]
        XCTAssertEqual(session.dropByState[.awake] ?? 0, 12.0, accuracy: 0.01)
        XCTAssertEqual(session.dropByState[.asleep] ?? 0, 3.0, accuracy: 0.01)
        XCTAssertEqual(session.dropByState[.darkWake] ?? 0, 0.0, accuracy: 0.01)

        let awakeRate = session.drainRatePerHour(in: .awake)
        XCTAssertNotNil(awakeRate)
        XCTAssertEqual(awakeRate!, 12.0 / (121.0 / 60.0), accuracy: 0.05)
    }

    func testWakeOccurrences() {
        let report = SessionBuilder.buildReport(events: makeScenario(), now: minutes(602))
        XCTAssertEqual(report.wakes.count, 3)
        let dark = report.wakes.filter(\.isDarkWake)
        XCTAssertEqual(dark.count, 1)
        XCTAssertEqual(dark[0].chargePercent, 92)
    }

    func testOngoingSessionExtendsToNow() {
        var events = makeScenario()
        events.removeLast() // drop the AC point — still on battery
        let now = minutes(650)
        let report = SessionBuilder.buildReport(events: events, now: now)
        XCTAssertEqual(report.sessions.count, 1)
        XCTAssertTrue(report.sessions[0].ongoing)
        XCTAssertEqual(report.sessions[0].interval.end, now)
    }

    func testAssertionIntervalPairing() {
        let edgeCreate = AssertionEdge(pid: 1, process: "AppA", action: .created,
                                       type: "PreventUserIdleSystemSleep", name: "work",
                                       heldSeconds: 0, assertionID: "0xA")
        let edgeRelease = AssertionEdge(pid: 1, process: "AppA", action: .released,
                                        type: "PreventUserIdleSystemSleep", name: "work",
                                        heldSeconds: 3600, assertionID: "0xA")
        let orphanRelease = AssertionEdge(pid: 2, process: "AppB", action: .released,
                                          type: "NoIdleSleepAssertion", name: "x",
                                          heldSeconds: 1800, assertionID: "0xB")
        let danglingCreate = AssertionEdge(pid: 3, process: "AppC", action: .created,
                                           type: "PreventUserIdleSystemSleep", name: "y",
                                           heldSeconds: 0, assertionID: "0xC")
        let events = [
            event(10, .assertionEdge(edgeCreate)),
            event(70, .assertionEdge(edgeRelease)),
            event(100, .assertionEdge(orphanRelease)),
            event(110, .assertionEdge(danglingCreate)),
        ]
        let intervals = SessionBuilder.buildAssertionIntervals(events: events, boots: [])

        let a = intervals.first { $0.process == "AppA" }!
        XCTAssertEqual(a.start, minutes(10))
        XCTAssertEqual(a.end, minutes(70))

        let b = intervals.first { $0.process == "AppB" }!
        XCTAssertEqual(b.start, minutes(70), "orphan release reconstructs start from held duration")
        XCTAssertEqual(b.end, minutes(100))

        let c = intervals.first { $0.process == "AppC" }!
        XCTAssertNil(c.end, "unreleased assertion stays open")
    }

    func testBootClosesOpenAssertions() {
        let create = AssertionEdge(pid: 1, process: "AppA", action: .created,
                                   type: "PreventUserIdleSystemSleep", name: "w",
                                   heldSeconds: 0, assertionID: "0xA")
        let events = [
            event(10, .assertionEdge(create)),
            event(50, .boot),
        ]
        let intervals = SessionBuilder.buildAssertionIntervals(events: events, boots: [minutes(50)])
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].end, minutes(50))
    }
}

// MARK: - Culprit analyzer

final class CulpritAnalyzerTests: XCTestCase {

    private func makeReport(intervals: [AssertionInterval]) -> PowerReport {
        PowerReport(generatedAt: minutes(600), logStart: minutes(0), logEnd: minutes(600),
                    events: [], stateSpans: [], assertionIntervals: intervals,
                    chargePoints: [], sessions: [], wakes: [], boots: [])
    }

    func testOverlappingHoldsMergeNotSum() {
        let intervals = [
            AssertionInterval(id: "1", pid: 1, process: "AppA", type: "PreventUserIdleSystemSleep",
                              name: "a", start: minutes(10), end: minutes(40)),
            AssertionInterval(id: "2", pid: 1, process: "AppA", type: "PreventUserIdleSystemSleep",
                              name: "b", start: minutes(20), end: minutes(50)),
        ]
        let culprits = CulpritAnalyzer.culprits(
            in: DateInterval(start: minutes(0), end: minutes(600)),
            report: makeReport(intervals: intervals))
        XCTAssertEqual(culprits.count, 1)
        XCTAssertEqual(culprits[0].heldSeconds, 40 * 60, accuracy: 1)
        XCTAssertEqual(culprits[0].instanceCount, 2)
    }

    func testSystemInternalFiltering() {
        let intervals = [
            AssertionInterval(id: "1", pid: 395, process: "powerd", type: "InternalPreventDisplaySleep",
                              name: "delayDisplayOff", start: minutes(0), end: minutes(500)),
            AssertionInterval(id: "2", pid: 9, process: "Docker", type: "PreventUserIdleSystemSleep",
                              name: "vm", start: minutes(0), end: minutes(300)),
        ]
        let report = makeReport(intervals: intervals)
        let window = DateInterval(start: minutes(0), end: minutes(600))

        let visible = CulpritAnalyzer.culprits(in: window, report: report)
        XCTAssertEqual(visible.map(\.process), ["Docker"])

        let all = CulpritAnalyzer.culprits(in: window, report: report, includeSystemInternal: true)
        XCTAssertEqual(all.count, 2)
    }

    func testSeverityRanking() {
        let intervals = [
            AssertionInterval(id: "1", pid: 1, process: "Docker", type: "PreventUserIdleSystemSleep",
                              name: "vm", start: minutes(0), end: minutes(400)),
            AssertionInterval(id: "2", pid: 2, process: "briefapp", type: "PreventUserIdleSystemSleep",
                              name: "z", start: minutes(0), end: minutes(1)),
        ]
        let culprits = CulpritAnalyzer.culprits(
            in: DateInterval(start: minutes(0), end: minutes(600)),
            report: makeReport(intervals: intervals))
        XCTAssertEqual(culprits.first?.process, "Docker")
        XCTAssertEqual(culprits.first?.explanation.severity, .heavy)
    }

    func testClippingToWindow() {
        let intervals = [
            AssertionInterval(id: "1", pid: 1, process: "AppA", type: "PreventUserIdleSystemSleep",
                              name: "a", start: minutes(-100), end: minutes(100)),
        ]
        let culprits = CulpritAnalyzer.culprits(
            in: DateInterval(start: minutes(0), end: minutes(50)),
            report: makeReport(intervals: intervals))
        XCTAssertEqual(culprits[0].heldSeconds, 50 * 60, accuracy: 1)
    }

    func testAwakeIntersection() {
        // Assertion held the entire window, but the Mac was only awake for the
        // first 100 minutes — only that overlap counts as causally meaningful.
        let intervals = [
            AssertionInterval(id: "1", pid: 1, process: "Docker", type: "PreventUserIdleSystemSleep",
                              name: "vm", start: minutes(0), end: minutes(600)),
        ]
        let spans = [
            StateSpan(state: .awake, start: minutes(0), end: minutes(100)),
            StateSpan(state: .asleep, start: minutes(100), end: minutes(580)),
            StateSpan(state: .darkWake, start: minutes(580), end: minutes(600)),
        ]
        let report = PowerReport(generatedAt: minutes(600), logStart: minutes(0), logEnd: minutes(600),
                                 events: [], stateSpans: spans, assertionIntervals: intervals,
                                 chargePoints: [], sessions: [], wakes: [], boots: [])
        let culprits = CulpritAnalyzer.culprits(
            in: DateInterval(start: minutes(0), end: minutes(600)), report: report)
        XCTAssertEqual(culprits.count, 1)
        XCTAssertEqual(culprits[0].heldSeconds, 600 * 60, accuracy: 1)
        XCTAssertEqual(culprits[0].awakeHeldSeconds, 120 * 60, accuracy: 1,
                       "awake (100m) + darkWake (20m) overlap only")
    }
}

// MARK: - Humanizer

final class HumanizerTests: XCTestCase {

    func testWakeCauses() {
        XCTAssertEqual(Humanizer.describeWakeCause("smc lid HID", matchedRequest: nil).title, "Lid opened")
        XCTAssertEqual(Humanizer.describeWakeCause("NUB.SPMISw3IRQ rtc/SleepService", matchedRequest: nil).title,
                       "Scheduled maintenance (Power Nap)")
        XCTAssertEqual(Humanizer.describeWakeCause("wifibt wake", matchedRequest: nil).title, "Network wake")
    }

    func testMatchedRequestEnrichesDetail() {
        let request = ScheduledWakeRequest(process: "mDNSResponder", requestType: "Maintenance",
                                           wakeAt: minutes(0), info: "DHCP lease renewal")
        let (_, detail) = Humanizer.describeWakeCause("rtc/SleepService", matchedRequest: request)
        XCTAssertTrue(detail.contains("Network discovery (Bonjour)"))
        XCTAssertTrue(detail.contains("DHCP lease renewal"))
    }

    func testKnownProcessExplanation() {
        let (display, explanation, _) = Humanizer.explain(
            process: "EpicGamesLauncher-Mac-Shipping",
            assertionType: "PreventUserIdleSystemSleep",
            assertionName: "Running dedicated server",
            heldSeconds: 66 * 3600, windowSeconds: 100 * 3600)
        XCTAssertEqual(display, "Epic Games Launcher")
        XCTAssertEqual(explanation.severity, .heavy)
        XCTAssertNotNil(explanation.suggestion)
    }

    func testUnknownProcessFallback() {
        let (display, explanation, systemInternal) = Humanizer.explain(
            process: "mysteryd", assertionType: "PreventUserIdleSystemSleep",
            assertionName: "job", heldSeconds: 60, windowSeconds: 3600)
        XCTAssertEqual(display, "mysteryd")
        XCTAssertTrue(explanation.meaning.contains("mysteryd"))
        XCTAssertFalse(systemInternal)
    }

    func testMidSentencePreservesProperNouns() {
        // Regression: a blanket .lowercased() turned "Prevented the Mac from
        // sleeping when idle" into "…the mac…" in CLI and narrative output.
        XCTAssertEqual(Humanizer.midSentence("Prevented the Mac from sleeping when idle"),
                       "prevented the Mac from sleeping when idle")
        XCTAssertEqual(Humanizer.midSentence("Scheduled maintenance (Power Nap)"),
                       "scheduled maintenance (Power Nap)")
        XCTAssertEqual(Humanizer.midSentence("Network wake"), "network wake")
        XCTAssertEqual(Humanizer.midSentence(""), "")
    }

    /// Every assertion-type description is dropped mid-sentence, so none may start
    /// with a word whose capitalization is load-bearing beyond the first character.
    func testAssertionTypeDescriptionsSurviveMidSentence() {
        for type in Humanizer.sleepPreventingTypes {
            let described = Humanizer.describeAssertionType(type)
            let mid = Humanizer.midSentence(described)
            XCTAssertFalse(mid.contains(" mac "), "\(type) lowercases 'Mac': \(mid)")
            XCTAssertEqual(mid.dropFirst(), described.dropFirst(),
                           "\(type) altered beyond its first character")
        }
    }

    func testDurationFormatting() {
        XCTAssertEqual(Humanizer.duration(45), "45s")
        XCTAssertEqual(Humanizer.duration(600), "10m")
        XCTAssertEqual(Humanizer.duration(3660), "1h 1m")
        XCTAssertEqual(Humanizer.duration(66 * 3600 + 6 * 60 + 26), "2d 18h")
    }
}

// MARK: - End-to-end on the real fixture

final class EndToEndTests: XCTestCase {

    func testRealLogProducesCoherentReport() throws {
        let text = try fixture("pmset_log_real.txt")
        let events = PMSetLogParser.parse(text)
        let report = SessionBuilder.buildReport(events: events, now: events.last!.time)

        XCTAssertFalse(report.stateSpans.isEmpty)
        // Spans must tile without overlap.
        for i in 1..<report.stateSpans.count {
            XCTAssertLessThanOrEqual(report.stateSpans[i - 1].end, report.stateSpans[i].start.addingTimeInterval(1))
        }
        // Charge points monotone in time.
        for i in 1..<report.chargePoints.count {
            XCTAssertLessThanOrEqual(report.chargePoints[i - 1].time, report.chargePoints[i].time)
        }
        // Culprit analysis over the whole log window must not crash and produces
        // merged durations no longer than the window.
        if let start = report.logStart, let end = report.logEnd, end > start {
            let window = DateInterval(start: start, end: end)
            let culprits = CulpritAnalyzer.culprits(in: window, report: report, includeSystemInternal: true)
            for culprit in culprits {
                XCTAssertLessThanOrEqual(culprit.heldSeconds, window.duration + 1,
                                         "\(culprit.process) exceeds window")
            }
        }
    }
}
