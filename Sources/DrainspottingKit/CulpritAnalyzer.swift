import Foundation

/// Ranks which processes kept the Mac awake during a window, with human explanations.
public enum CulpritAnalyzer {

    /// Groups assertion intervals by process + assertion type, merges overlapping
    /// holds (an app holding five parallel assertions isn't 5× as guilty), clips
    /// to the window, and intersects with the time the Mac was actually awake or
    /// in DarkWake — an assertion can't drain a Mac that's already asleep.
    public static func culprits(in window: DateInterval, report: PowerReport,
                                includeSystemInternal: Bool = false) -> [Culprit] {
        let fallbackEnd = report.generatedAt

        // Awake/DarkWake coverage inside the window. When a log has no state
        // spans at all (synthetic edge cases), fall back to the whole window.
        var activeSpans: [(Date, Date)] = report.stateSpans.compactMap { span in
            guard span.state != .asleep,
                  let overlap = span.interval.intersection(with: window),
                  overlap.duration > 0 else { return nil }
            return (overlap.start, overlap.end)
        }
        if report.stateSpans.isEmpty {
            activeSpans = [(window.start, window.end)]
        }
        let awakeWindowSeconds = mergedDuration(activeSpans)

        struct GroupKey: Hashable {
            let process: String
            let type: String
        }

        var groups: [GroupKey: (intervals: [(Date, Date)], names: [String], count: Int)] = [:]

        for interval in report.assertionIntervals {
            let end = interval.end ?? fallbackEnd
            guard end > window.start, interval.start < window.end else { continue }
            let clippedStart = max(interval.start, window.start)
            let clippedEnd = min(end, window.end)
            guard clippedEnd > clippedStart else { continue }

            let key = GroupKey(process: interval.process, type: interval.type)
            groups[key, default: ([], [], 0)].intervals.append((clippedStart, clippedEnd))
            groups[key]?.names.append(interval.name)
            groups[key]?.count += 1
        }

        var culprits: [Culprit] = []
        for (key, value) in groups {
            let merged = mergeIntervals(value.intervals)
            let totalSeconds = merged.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
            let awakeSeconds = overlapDuration(merged, activeSpans)
            guard totalSeconds >= 5 else { continue }
            let sampleName = mostCommon(value.names) ?? ""
            let (display, explanation, systemInternal) = Humanizer.explain(
                process: key.process,
                assertionType: key.type,
                assertionName: sampleName,
                heldSeconds: awakeSeconds,
                windowSeconds: max(awakeWindowSeconds, 60))

            if systemInternal && !includeSystemInternal { continue }

            culprits.append(Culprit(
                id: "\(key.process)|\(key.type)",
                process: key.process,
                displayName: display,
                assertionType: key.type,
                sampleAssertionName: sampleName,
                heldSeconds: totalSeconds,
                awakeHeldSeconds: awakeSeconds,
                instanceCount: value.count,
                isSystemInternal: systemInternal,
                explanation: explanation))
        }

        return culprits.sorted {
            if $0.explanation.severity != $1.explanation.severity {
                return $0.explanation.severity > $1.explanation.severity
            }
            return $0.awakeHeldSeconds > $1.awakeHeldSeconds
        }
    }

    // MARK: - Interval math

    /// Merges possibly-overlapping intervals into a disjoint, sorted set.
    static func mergeIntervals(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var result: [(Date, Date)] = []
        var currentStart = sorted[0].0
        var currentEnd = sorted[0].1
        for (start, end) in sorted.dropFirst() {
            if start > currentEnd {
                result.append((currentStart, currentEnd))
                currentStart = start
                currentEnd = end
            } else if end > currentEnd {
                currentEnd = end
            }
        }
        result.append((currentStart, currentEnd))
        return result
    }

    static func mergedDuration(_ intervals: [(Date, Date)]) -> TimeInterval {
        mergeIntervals(intervals).reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
    }

    /// Total overlap between two disjoint-interval sets.
    static func overlapDuration(_ a: [(Date, Date)], _ b: [(Date, Date)]) -> TimeInterval {
        let bMerged = mergeIntervals(b)
        var total: TimeInterval = 0
        for (startA, endA) in a {
            for (startB, endB) in bMerged {
                let s = max(startA, startB)
                let e = min(endA, endB)
                if e > s { total += e.timeIntervalSince(s) }
            }
        }
        return total
    }

    static func mostCommon(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }
}
