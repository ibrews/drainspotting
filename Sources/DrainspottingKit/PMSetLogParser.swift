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
        // DateFormatter was 83% of a full parse on a 155k-line log (sampled
        // 2026-10-27: 25 s total, ~12 s in dateFromString). The timestamp is
        // fixed-width ASCII, so decode it by hand and keep the formatter only
        // as the fallback for anything that doesn't fit the shape exactly.
        guard let time = parseTimestamp(dateString) ?? dateFormatter.date(from: dateString) else { return nil }
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

    /// Decodes exactly "yyyy-MM-dd HH:mm:ss ±HHMM" (25 ASCII bytes) without
    /// going through DateFormatter/ICU. Returns nil for anything else so the
    /// caller can fall back to the formatter; never guesses.
    static func parseTimestamp(_ s: String) -> Date? {
        var utf8 = Array(s.utf8)
        guard utf8.count == 25 else { return nil }
        // Byte layout: 0123-56-89 12:45:78 +1234 (spaces/dashes/colons fixed).
        guard utf8[4] == 0x2D, utf8[7] == 0x2D, utf8[10] == 0x20,
              utf8[13] == 0x3A, utf8[16] == 0x3A, utf8[19] == 0x20,
              utf8[20] == 0x2B || utf8[20] == 0x2D else { return nil }
        let sign: Int = utf8[20] == 0x2D ? -1 : 1
        utf8[20] = 0x30 // neutralize the sign so the digit scan below is uniform
        for i in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 21, 22, 23, 24] {
            guard utf8[i] >= 0x30, utf8[i] <= 0x39 else { return nil }
        }
        @inline(__always) func num(_ a: Int, _ b: Int) -> Int {
            var v = 0
            for i in a...b { v = v * 10 + Int(utf8[i] - 0x30) }
            return v
        }
        let year = num(0, 3), month = num(5, 6), day = num(8, 9)
        let hour = num(11, 12), minute = num(14, 15), second = num(17, 18)
        let offsetHours = num(21, 22), offsetMinutes = num(23, 24)
        guard (1...12).contains(month), (1...31).contains(day), hour < 24,
              minute < 60, second < 61, offsetHours < 24, offsetMinutes < 60 else { return nil }

        // Days since 1970-01-01 for a proleptic Gregorian civil date
        // (Howard Hinnant's days_from_civil) — exact, no calendar object.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468

        let local = days * 86400 + hour * 3600 + minute * 60 + second
        let offset = sign * (offsetHours * 3600 + offsetMinutes * 60)
        return Date(timeIntervalSince1970: TimeInterval(local - offset))
    }

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
