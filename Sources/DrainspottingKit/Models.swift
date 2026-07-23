import Foundation

// MARK: - Primitives

public enum PowerSource: String, Sendable, Equatable {
    case battery
    case ac
    case unknown
}

public enum SystemPowerState: String, Sendable, Equatable, CaseIterable, Hashable {
    /// Screen may be on or off, but the system is fully running.
    case awake
    /// Full system sleep.
    case asleep
    /// Background maintenance wake (Power Nap, network wake). Screen stays off.
    case darkWake
}

public struct ChargeAnnotation: Sendable, Equatable {
    public let percent: Int
    public let source: PowerSource

    public init(percent: Int, source: PowerSource) {
        self.percent = percent
        self.source = source
    }
}

public struct ChargePoint: Sendable, Equatable {
    public let time: Date
    public let percent: Int
    public let source: PowerSource

    public init(time: Date, percent: Int, source: PowerSource) {
        self.time = time
        self.percent = percent
        self.source = source
    }
}

// MARK: - Log events

public enum AssertionAction: String, Sendable, Equatable {
    case created = "Created"
    case released = "Released"
    case timedOut = "TimedOut"
}

public struct AssertionEdge: Sendable, Equatable {
    public let pid: Int
    public let process: String
    public let action: AssertionAction
    public let type: String
    public let name: String
    /// Seconds the assertion had been held when this line was logged (0 for Created).
    public let heldSeconds: TimeInterval
    public let assertionID: String

    public init(pid: Int, process: String, action: AssertionAction, type: String,
                name: String, heldSeconds: TimeInterval, assertionID: String) {
        self.pid = pid
        self.process = process
        self.action = action
        self.type = type
        self.name = name
        self.heldSeconds = heldSeconds
        self.assertionID = assertionID
    }
}

public struct ScheduledWakeRequest: Sendable, Equatable {
    public let process: String
    public let requestType: String
    public let wakeAt: Date?
    public let info: String?

    public init(process: String, requestType: String, wakeAt: Date?, info: String?) {
        self.process = process
        self.requestType = requestType
        self.wakeAt = wakeAt
        self.info = info
    }
}

public enum LogEventKind: Sendable, Equatable {
    case sleep(reason: String)
    case wake(cause: String, tag: String?)
    case darkWake(cause: String, tag: String?)
    case assertionEdge(AssertionEdge)
    case assertionSummary(flags: [String])
    case wakeRequests([ScheduledWakeRequest])
    case boot
    case kernelAssertions(raw: String)
    case other(type: String)
}

public struct PowerLogEvent: Sendable, Equatable {
    public let time: Date
    public let kind: LogEventKind
    public let charge: ChargeAnnotation?
    /// Raw line text, kept only for event kinds that surface in detail UI.
    public let raw: String?

    public init(time: Date, kind: LogEventKind, charge: ChargeAnnotation?, raw: String?) {
        self.time = time
        self.kind = kind
        self.charge = charge
        self.raw = raw
    }
}

// MARK: - Derived timeline

public struct StateSpan: Sendable, Equatable {
    public let state: SystemPowerState
    public let start: Date
    public let end: Date

    public init(state: SystemPowerState, start: Date, end: Date) {
        self.state = state
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
}

public struct AssertionInterval: Sendable, Equatable, Identifiable {
    public let id: String
    public let pid: Int
    public let process: String
    public let type: String
    public let name: String
    public let start: Date
    /// nil = still held at the end of the observed window.
    public let end: Date?

    public init(id: String, pid: Int, process: String, type: String, name: String,
                start: Date, end: Date?) {
        self.id = id
        self.pid = pid
        self.process = process
        self.type = type
        self.name = name
        self.start = start
        self.end = end
    }

    public func overlapSeconds(with window: DateInterval, openEndsAt fallbackEnd: Date) -> TimeInterval {
        let effectiveEnd = end ?? fallbackEnd
        guard effectiveEnd > start else { return 0 }
        let s = max(start, window.start)
        let e = min(effectiveEnd, window.end)
        return max(0, e.timeIntervalSince(s))
    }
}

public struct WakeOccurrence: Sendable, Equatable, Identifiable {
    public let time: Date
    public let isDarkWake: Bool
    public let rawCause: String
    public let tag: String?
    public let chargePercent: Int?
    public let matchedRequest: ScheduledWakeRequest?

    public init(time: Date, isDarkWake: Bool, rawCause: String, tag: String?,
                chargePercent: Int?, matchedRequest: ScheduledWakeRequest?) {
        self.time = time
        self.isDarkWake = isDarkWake
        self.rawCause = rawCause
        self.tag = tag
        self.chargePercent = chargePercent
        self.matchedRequest = matchedRequest
    }

    public var id: String { "\(time.timeIntervalSince1970)-\(isDarkWake ? "dw" : "w")" }
}

public struct DischargeSession: Sendable, Equatable, Identifiable {
    public let id: String
    public let interval: DateInterval
    public let startPercent: Int
    public let endPercent: Int
    /// true when the session ended because power was plugged in; false = log ended / boot.
    public let endedByPlugIn: Bool
    /// true when the machine is still on battery and this is the current session.
    public let ongoing: Bool
    public let chargePoints: [ChargePoint]
    public let stateSeconds: [SystemPowerState: TimeInterval]
    /// Percent drop attributed to each state via linear allocation between charge points.
    public let dropByState: [SystemPowerState: Double]
    public let wakes: [WakeOccurrence]
    public let bootsDuring: [Date]

    public init(id: String, interval: DateInterval, startPercent: Int, endPercent: Int,
                endedByPlugIn: Bool, ongoing: Bool, chargePoints: [ChargePoint],
                stateSeconds: [SystemPowerState: TimeInterval],
                dropByState: [SystemPowerState: Double],
                wakes: [WakeOccurrence], bootsDuring: [Date]) {
        self.id = id
        self.interval = interval
        self.startPercent = startPercent
        self.endPercent = endPercent
        self.endedByPlugIn = endedByPlugIn
        self.ongoing = ongoing
        self.chargePoints = chargePoints
        self.stateSeconds = stateSeconds
        self.dropByState = dropByState
        self.wakes = wakes
        self.bootsDuring = bootsDuring
    }

    public var totalDropPercent: Int { max(0, startPercent - endPercent) }
    public var duration: TimeInterval { interval.duration }

    public func seconds(in state: SystemPowerState) -> TimeInterval {
        stateSeconds[state] ?? 0
    }

    /// Percent-per-hour drain while in the given state; nil when the state barely occurred.
    public func drainRatePerHour(in state: SystemPowerState) -> Double? {
        let secs = seconds(in: state)
        guard secs >= 300 else { return nil }
        let drop = dropByState[state] ?? 0
        return drop / (secs / 3600)
    }
}

// MARK: - Culprits

public struct CulpritExplanation: Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case info = 0
        case notable = 1
        case heavy = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let title: String
    public let meaning: String
    public let suggestion: String?
    public let severity: Severity

    public init(title: String, meaning: String, suggestion: String?, severity: Severity) {
        self.title = title
        self.meaning = meaning
        self.suggestion = suggestion
        self.severity = severity
    }
}

public struct Culprit: Sendable, Equatable, Identifiable {
    public let id: String
    public let process: String
    public let displayName: String
    public let assertionType: String
    public let sampleAssertionName: String
    /// Total time the assertion was held within the window.
    public let heldSeconds: TimeInterval
    /// Held time that overlapped the Mac actually being awake or in DarkWake —
    /// the causally meaningful number (an idle-sleep assertion can't drain a
    /// Mac that's already asleep; clamshell sleep overrides it).
    public let awakeHeldSeconds: TimeInterval
    public let instanceCount: Int
    /// System plumbing (powerd display assertions, WindowServer user-activity ticks) that
    /// reflects normal use rather than a misbehaving app.
    public let isSystemInternal: Bool
    public let explanation: CulpritExplanation

    public init(id: String, process: String, displayName: String, assertionType: String,
                sampleAssertionName: String, heldSeconds: TimeInterval,
                awakeHeldSeconds: TimeInterval, instanceCount: Int,
                isSystemInternal: Bool, explanation: CulpritExplanation) {
        self.id = id
        self.process = process
        self.displayName = displayName
        self.assertionType = assertionType
        self.sampleAssertionName = sampleAssertionName
        self.heldSeconds = heldSeconds
        self.awakeHeldSeconds = awakeHeldSeconds
        self.instanceCount = instanceCount
        self.isSystemInternal = isSystemInternal
        self.explanation = explanation
    }
}

// MARK: - Live data

public struct ActiveAssertion: Sendable, Equatable, Identifiable {
    public let pid: Int
    public let process: String
    public let type: String
    public let name: String
    public let heldSeconds: TimeInterval
    public let createdForPID: Int?
    public let resources: String?

    public init(pid: Int, process: String, type: String, name: String,
                heldSeconds: TimeInterval, createdForPID: Int?, resources: String?) {
        self.pid = pid
        self.process = process
        self.type = type
        self.name = name
        self.heldSeconds = heldSeconds
        self.createdForPID = createdForPID
        self.resources = resources
    }

    public var id: String { "\(pid)-\(type)-\(name)" }
}

public struct LiveAssertionsState: Sendable, Equatable {
    public let capturedAt: Date
    public let assertions: [ActiveAssertion]
    public let kernelAssertions: [String]

    public init(capturedAt: Date, assertions: [ActiveAssertion], kernelAssertions: [String]) {
        self.capturedAt = capturedAt
        self.assertions = assertions
        self.kernelAssertions = kernelAssertions
    }
}

public struct BatterySnapshot: Sendable, Equatable {
    public let capturedAt: Date
    public let percent: Int?
    public let isCharging: Bool
    public let externalPowerConnected: Bool
    public let cycleCount: Int?
    public let designCapacitymAh: Int?
    public let fullChargeCapacitymAh: Int?
    public let hasBattery: Bool

    public init(capturedAt: Date, percent: Int?, isCharging: Bool, externalPowerConnected: Bool,
                cycleCount: Int?, designCapacitymAh: Int?, fullChargeCapacitymAh: Int?,
                hasBattery: Bool) {
        self.capturedAt = capturedAt
        self.percent = percent
        self.isCharging = isCharging
        self.externalPowerConnected = externalPowerConnected
        self.cycleCount = cycleCount
        self.designCapacitymAh = designCapacitymAh
        self.fullChargeCapacitymAh = fullChargeCapacitymAh
        self.hasBattery = hasBattery
    }

    /// Battery health as a fraction of design capacity (e.g. 0.81), when known.
    public var healthFraction: Double? {
        guard let design = designCapacitymAh, design > 0,
              let full = fullChargeCapacitymAh else { return nil }
        return Double(full) / Double(design)
    }
}

// MARK: - Report

public struct PowerReport: Sendable, Equatable {
    public let generatedAt: Date
    public let logStart: Date?
    public let logEnd: Date?
    public let events: [PowerLogEvent]
    public let stateSpans: [StateSpan]
    public let assertionIntervals: [AssertionInterval]
    public let chargePoints: [ChargePoint]
    /// Newest first.
    public let sessions: [DischargeSession]
    public let wakes: [WakeOccurrence]
    public let boots: [Date]

    public init(generatedAt: Date, logStart: Date?, logEnd: Date?, events: [PowerLogEvent],
                stateSpans: [StateSpan], assertionIntervals: [AssertionInterval],
                chargePoints: [ChargePoint], sessions: [DischargeSession],
                wakes: [WakeOccurrence], boots: [Date]) {
        self.generatedAt = generatedAt
        self.logStart = logStart
        self.logEnd = logEnd
        self.events = events
        self.stateSpans = stateSpans
        self.assertionIntervals = assertionIntervals
        self.chargePoints = chargePoints
        self.sessions = sessions
        self.wakes = wakes
        self.boots = boots
    }
}
