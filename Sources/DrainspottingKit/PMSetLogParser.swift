import Foundation

/// Parses the output of `pmset -g log` into structured events.
///
/// Line shape (verified on macOS 14–27):
/// `2026-07-23 00:56:03 -0700 Sleep               \tEntering Sleep state due to 'Maintenance Sleep' ... Using Batt (Charge:51%) 642 secs`
/// Continuation lines (indented, no leading date) belong to the trailing
/// current-assertions section and are intentionally ignored here — live state
/// comes from `pmset -g assertions` via `AssertionsParser`.
public enum PMSetLogParser {

    // Nested regex helpers are compiled once.
    private static let chargeRegex = try! NSRegularExpression(
        pattern: #"Using\s+(AC|Batt|BATT)\s*\(\s*Charge:\s*(\d+)\s*%?\s*\)"#)
    private static let sleepReasonRegex = try! NSRegularExpression(
        pattern: #"due to '([^']*)'"#)
    private static let wakeCauseRegex = try! NSRegularExpression(
        pattern: #"due to (.+?)(?:\s+Using\s.*)?$"#)
    private static let wakeTagRegex = try! NSRegularExpression(
        pattern: #"from [^\[\r\n]*\[([^\]]+)\]"#)
    private static let assertionEdgeRegex = try! NSRegularExpression(
        pattern: #"^PID (\d+)\(([^)]*)\) (Created|Released|TimedOut) (\S+) "([^"]*)" (\d+):(\d{2}):(\d{2})\s+id:(\S+)"#)
    private static let summaryRegex = try! NSRegularExpression(
        pattern: #"Summary- \[System: ([^\]]*)\]"#)
    private static let wakeRequestRegex = try! NSRegularExpression(
        pattern: #"\[\*?process=([^\s\]]+) request=([^\s\]]+) deltaSecs=\d+ wakeAt=(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?: info="([^"]*)")?\]"#)

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public static func parse(_ text: String) -> [PowerLogEvent] {
        var events: [PowerLogEvent] = []
        events.reserveCapacity(text.count / 200)

        text.enumerateLines { line, _ in
            if let event = parseLine(line) {
                events.append(event)
            }
        }
        // pmset output is chronological, but powerd restarts can interleave;
        // downstream logic requires strict ordering.
        events.sort { $0.time < $1.time }
        return events
    }

    /// Parses one dated log line; returns nil for continuation/blank/unparseable lines.
    static func parseLine(_ line: String) -> PowerLogEvent? {
        // Fast reject: dated lines start with "20" and are at least date-width long.
        guard line.count > 26, line.hasPrefix("20") else { return nil }

        // Fixed-width timestamp: "yyyy-MM-dd HH:mm:ss +ZZZZ" = 25 chars.
        let dateEnd = line.index(line.startIndex, offsetBy: 25)
        let dateString = String(line[line.startIndex..<dateEnd])
        guard let time = dateFormatter.date(from: dateString) else { return nil }
        let offsetToken = String(dateString.suffix(5))

        var remainder = String(line[dateEnd...])
        if remainder.hasPrefix(" ") { remainder.removeFirst() }

        // Type column is padded then separated from the message by a tab
        // (or, defensively, a run of 2+ spaces).
        let type: String
        var message: String
        if let tabIndex = remainder.firstIndex(of: "\t") {
            type = remainder[remainder.startIndex..<tabIndex].trimmingCharacters(in: .whitespaces)
            message = String(remainder[remainder.index(after: tabIndex)...])
        } else if let range = remainder.range(of: #"\s{2,}"#, options: .regularExpression) {
            type = String(remainder[remainder.startIndex..<range.lowerBound])
            message = String(remainder[range.upperBound...])
        } else {
            type = remainder.trimmingCharacters(in: .whitespaces)
            message = ""
        }
        message = message.trimmingCharacters(in: .whitespaces)

        let charge = parseCharge(message)

        switch type {
        case "Sleep":
            let reason = firstCapture(sleepReasonRegex, in: message) ?? message
            return PowerLogEvent(time: time, kind: .sleep(reason: reason), charge: charge, raw: line)

        case "Wake":
            let (cause, tag) = parseWake(message)
            return PowerLogEvent(time: time, kind: .wake(cause: cause, tag: tag), charge: charge, raw: line)

        case "DarkWake":
            let (cause, tag) = parseWake(message)
            return PowerLogEvent(time: time, kind: .darkWake(cause: cause, tag: tag), charge: charge, raw: line)

        case "Assertions":
            if let edge = parseAssertionEdge(message) {
                return PowerLogEvent(time: time, kind: .assertionEdge(edge), charge: charge, raw: nil)
            }
            if let flags = firstCapture(summaryRegex, in: message) {
                let flagList = flags.split(separator: " ").map(String.init)
                return PowerLogEvent(time: time, kind: .assertionSummary(flags: flagList), charge: charge, raw: nil)
            }
            return PowerLogEvent(time: time, kind: .other(type: type), charge: charge, raw: nil)

        case "Wake Requests":
            let requests = parseWakeRequests(message, offsetToken: offsetToken)
            guard !requests.isEmpty else {
                return PowerLogEvent(time: time, kind: .other(type: type), charge: charge, raw: nil)
            }
            return PowerLogEvent(time: time, kind: .wakeRequests(requests), charge: charge, raw: nil)

        case "Start":
            return PowerLogEvent(time: time, kind: .boot, charge: charge, raw: line)

        default:
            if type.hasPrefix("Kernel Assertions") || message.hasPrefix("Kernel Assertions:") {
                return PowerLogEvent(time: time, kind: .kernelAssertions(raw: message), charge: charge, raw: nil)
            }
            if message.contains("powerd process is started") {
                return PowerLogEvent(time: time, kind: .boot, charge: charge, raw: line)
            }
            return PowerLogEvent(time: time, kind: .other(type: type), charge: charge, raw: nil)
        }
    }

    // MARK: - Component parsers

    static func parseCharge(_ message: String) -> ChargeAnnotation? {
        guard let match = firstMatch(chargeRegex, in: message) else { return nil }
        let sourceToken = match[0].lowercased()
        let source: PowerSource = sourceToken == "ac" ? .ac : .battery
        guard let pct = Int(match[1]), (0...100).contains(pct) else { return nil }
        return ChargeAnnotation(percent: pct, source: source)
    }

    private static func parseWake(_ message: String) -> (cause: String, tag: String?) {
        let cause = firstCapture(wakeCauseRegex, in: message) ?? message
        let tag = firstCapture(wakeTagRegex, in: message)
        return (cause.trimmingCharacters(in: .whitespaces), tag)
    }

    static func parseAssertionEdge(_ message: String) -> AssertionEdge? {
        guard let match = firstMatch(assertionEdgeRegex, in: message),
              let pid = Int(match[0]),
              let action = AssertionAction(rawValue: match[2]),
              let hours = Int(match[5]), let minutes = Int(match[6]), let seconds = Int(match[7])
        else { return nil }
        let held = TimeInterval(hours * 3600 + minutes * 60 + seconds)
        return AssertionEdge(
            pid: pid,
            process: match[1],
            action: action,
            type: match[3],
            name: match[4],
            heldSeconds: held,
            assertionID: match[8]
        )
    }

    static func parseWakeRequests(_ message: String, offsetToken: String) -> [ScheduledWakeRequest] {
        let ns = message as NSString
        let matches = wakeRequestRegex.matches(in: message, range: NSRange(location: 0, length: ns.length))
        return matches.map { m in
            let process = ns.substring(with: m.range(at: 1))
            let request = ns.substring(with: m.range(at: 2))
            let wakeAtString = ns.substring(with: m.range(at: 3)) + " " + offsetToken
            let wakeAt = dateFormatter.date(from: wakeAtString)
            let info = m.range(at: 4).location == NSNotFound ? nil : ns.substring(with: m.range(at: 4))
            return ScheduledWakeRequest(process: process, requestType: request, wakeAt: wakeAt, info: info)
        }
    }

    // MARK: - Regex utilities

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> [String]? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    private static func firstCapture(_ regex: NSRegularExpression, in text: String) -> String? {
        firstMatch(regex, in: text)?.first
    }
}
