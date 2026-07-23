import Foundation

/// Turns a flat event stream into the derived timeline: state spans, assertion
/// intervals, charge curve, wake occurrences, and per-discharge sessions.
public enum SessionBuilder {

    public static func buildReport(events: [PowerLogEvent], now: Date = Date()) -> PowerReport {
        let logStart = events.first?.time
        let logEnd = events.last?.time
        let boots = events.compactMap { event -> Date? in
            if case .boot = event.kind { return event.time }
            return nil
        }

        let chargePoints = buildChargePoints(events: events)
        let stateSpans = buildStateSpans(events: events, now: now, chargePoints: chargePoints)
        let assertionIntervals = buildAssertionIntervals(events: events, boots: boots)
        let wakes = buildWakes(events: events)
        let sessions = buildSessions(
            chargePoints: chargePoints, stateSpans: stateSpans, wakes: wakes,
            boots: boots, logEnd: logEnd, now: now)

        return PowerReport(
            generatedAt: now,
            logStart: logStart,
            logEnd: logEnd,
            events: events,
            stateSpans: stateSpans,
            assertionIntervals: assertionIntervals,
            chargePoints: chargePoints,
            sessions: sessions,
            wakes: wakes,
            boots: boots
        )
    }

    // MARK: - Charge curve

    static func buildChargePoints(events: [PowerLogEvent]) -> [ChargePoint] {
        var points: [ChargePoint] = []
        points.reserveCapacity(events.count / 2)
        for event in events {
            guard let charge = event.charge else { continue }
            let point = ChargePoint(time: event.time, percent: charge.percent, source: charge.source)
            // Collapse identical consecutive readings to keep the curve light.
            if let last = points.last, last.percent == point.percent, last.source == point.source,
               point.time.timeIntervalSince(last.time) < 60 {
                continue
            }
            points.append(point)
        }
        return points
    }

    // MARK: - State machine

    static func buildStateSpans(events: [PowerLogEvent], now: Date,
                                chargePoints: [ChargePoint]) -> [StateSpan] {
        guard let first = events.first else { return [] }
        var spans: [StateSpan] = []
        var currentState: SystemPowerState = .awake
        var currentStart = first.time

        func transition(to newState: SystemPowerState, at time: Date) {
            guard newState != currentState else { return }
            if time > currentStart {
                spans.append(StateSpan(state: currentState, start: currentStart, end: time))
            }
            currentState = newState
            currentStart = time
        }

        for event in events {
            switch event.kind {
            case .sleep:
                transition(to: .asleep, at: event.time)
            case .wake:
                transition(to: .awake, at: event.time)
            case .darkWake:
                transition(to: .darkWake, at: event.time)
            case .boot:
                // powerd restart: close the previous state; machine is awake post-boot.
                transition(to: .awake, at: event.time)
            default:
                break
            }
        }

        let end = max(now, currentStart)
        if end > currentStart {
            spans.append(StateSpan(state: currentState, start: currentStart, end: end))
        }
        return spans
    }

    // MARK: - Assertions

    static func buildAssertionIntervals(events: [PowerLogEvent], boots: [Date]) -> [AssertionInterval] {
        struct Open {
            let start: Date
            let edge: AssertionEdge
        }
        var open: [String: Open] = [:]
        var intervals: [AssertionInterval] = []
        var counter = 0

        func close(_ o: Open, at end: Date) {
            counter += 1
            intervals.append(AssertionInterval(
                id: "\(o.edge.assertionID)-\(counter)",
                pid: o.edge.pid, process: o.edge.process,
                type: o.edge.type, name: o.edge.name,
                start: o.start, end: end))
        }

        for event in events {
            switch event.kind {
            case .assertionEdge(let edge):
                switch edge.action {
                case .created:
                    open[edge.assertionID] = Open(start: event.time, edge: edge)
                case .released, .timedOut:
                    if let o = open.removeValue(forKey: edge.assertionID) {
                        close(o, at: event.time)
                    } else {
                        // Creation predates the log window; reconstruct from held duration.
                        let start = event.time.addingTimeInterval(-edge.heldSeconds)
                        counter += 1
                        intervals.append(AssertionInterval(
                            id: "\(edge.assertionID)-\(counter)",
                            pid: edge.pid, process: edge.process,
                            type: edge.type, name: edge.name,
                            start: start, end: event.time))
                    }
                }
            case .boot:
                // Assertions do not survive a reboot / powerd restart.
                for o in open.values { close(o, at: event.time) }
                open.removeAll()
            default:
                break
            }
        }

        // Still held at end of log.
        for o in open.values {
            counter += 1
            intervals.append(AssertionInterval(
                id: "\(o.edge.assertionID)-open-\(counter)",
                pid: o.edge.pid, process: o.edge.process,
                type: o.edge.type, name: o.edge.name,
                start: o.start, end: nil))
        }

        intervals.sort { $0.start < $1.start }
        return intervals
    }

    // MARK: - Wakes

    static func buildWakes(events: [PowerLogEvent]) -> [WakeOccurrence] {
        var pendingRequests: [ScheduledWakeRequest] = []
        var wakes: [WakeOccurrence] = []

        for event in events {
            switch event.kind {
            case .wakeRequests(let requests):
                pendingRequests = requests
            case .wake(let cause, let tag), .darkWake(let cause, let tag):
                let isDark: Bool
                if case .darkWake = event.kind { isDark = true } else { isDark = false }
                let matched = pendingRequests.first { request in
                    guard let at = request.wakeAt else { return false }
                    return abs(at.timeIntervalSince(event.time)) <= 180
                }
                wakes.append(WakeOccurrence(
                    time: event.time,
                    isDarkWake: isDark,
                    rawCause: cause,
                    tag: tag,
                    chargePercent: event.charge?.percent,
                    matchedRequest: matched))
            default:
                break
            }
        }
        return wakes
    }

    // MARK: - Discharge sessions

    static func buildSessions(chargePoints: [ChargePoint], stateSpans: [StateSpan],
                              wakes: [WakeOccurrence], boots: [Date],
                              logEnd: Date?, now: Date) -> [DischargeSession] {
        guard !chargePoints.isEmpty else { return [] }

        struct Run {
            var points: [ChargePoint] = []
            var endedByPlugIn = false
            var endTime: Date?
        }

        var runs: [Run] = []
        var current: Run? = nil

        for point in chargePoints {
            switch point.source {
            case .battery:
                if current == nil { current = Run() }
                current?.points.append(point)
            case .ac, .unknown:
                if var run = current {
                    run.endedByPlugIn = point.source == .ac
                    run.endTime = point.time
                    runs.append(run)
                    current = nil
                }
            }
        }
        var lastRunIsOngoing = false
        if let run = current {
            runs.append(run)
            lastRunIsOngoing = true
        }

        var sessions: [DischargeSession] = []
        for (index, run) in runs.enumerated() {
            guard let firstPoint = run.points.first, let lastPoint = run.points.last else { continue }
            let ongoing = lastRunIsOngoing && index == runs.count - 1
            let end = run.endTime ?? (ongoing ? max(now, lastPoint.time) : lastPoint.time)
            let interval = DateInterval(start: firstPoint.time, end: max(firstPoint.time, end))
            guard interval.duration >= 600, run.points.count >= 2 else { continue }

            let stateSeconds = secondsByState(spans: stateSpans, window: interval)
            let dropByState = allocateDrop(points: run.points, spans: stateSpans)
            let sessionWakes = wakes.filter { interval.contains($0.time) }
            let sessionBoots = boots.filter { interval.contains($0) }

            let formatterID = ISO8601DateFormatter()
            sessions.append(DischargeSession(
                id: formatterID.string(from: firstPoint.time),
                interval: interval,
                startPercent: firstPoint.percent,
                endPercent: lastPoint.percent,
                endedByPlugIn: run.endedByPlugIn,
                ongoing: ongoing,
                chargePoints: run.points,
                stateSeconds: stateSeconds,
                dropByState: dropByState,
                wakes: sessionWakes,
                bootsDuring: sessionBoots))
        }

        return sessions.sorted { $0.interval.start > $1.interval.start }
    }

    static func secondsByState(spans: [StateSpan], window: DateInterval) -> [SystemPowerState: TimeInterval] {
        var result: [SystemPowerState: TimeInterval] = [:]
        for span in spans {
            guard let overlap = span.interval.intersection(with: window), overlap.duration > 0 else { continue }
            result[span.state, default: 0] += overlap.duration
        }
        return result
    }

    /// Distributes the percent drop between consecutive charge points across the
    /// power states active in that gap, proportional to time spent in each.
    static func allocateDrop(points: [ChargePoint], spans: [StateSpan]) -> [SystemPowerState: Double] {
        var result: [SystemPowerState: Double] = [:]
        guard points.count >= 2 else { return result }

        for i in 1..<points.count {
            let previous = points[i - 1]
            let point = points[i]
            let drop = Double(previous.percent - point.percent)
            guard drop > 0, point.time > previous.time else { continue }
            let gap = DateInterval(start: previous.time, end: point.time)
            var stateTime = secondsByState(spans: spans, window: gap)
            if stateTime.isEmpty { stateTime = [.awake: gap.duration] }
            let total = stateTime.values.reduce(0, +)
            guard total > 0 else { continue }
            for (state, seconds) in stateTime {
                result[state, default: 0] += drop * (seconds / total)
            }
        }
        return result
    }
}
