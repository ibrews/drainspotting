import Foundation

/// Parses the output of `pmset -g assertions` (live, current state).
///
/// ```
/// 2026-07-23 02:29:25 -0700
/// Assertion status system-wide:
///    BackgroundTask                 0
///    ...
/// Listed by owning process:
///    pid 646(coreaudiod): [0x0001968c00018b1d] 00:25:29 PreventUserIdleSystemSleep named: "com.apple.audio..."
///        Created for PID: 8567.
///        Resources: audio-out BuiltInSpeakerDevice
/// Kernel Assertions: 0x104=USB,MAGICWAKE
/// ```
public enum AssertionsParser {

    private static let pidLineRegex = try! NSRegularExpression(
        pattern: #"^\s*pid (\d+)\(([^)]*)\):\s*\[(\S+)\]\s*(\d+):(\d{2}):(\d{2})\s+(\S+)\s+named:\s+"([^"]*)""#)
    private static let createdForRegex = try! NSRegularExpression(
        pattern: #"Created for PID:\s*(\d+)"#)
    private static let resourcesRegex = try! NSRegularExpression(
        pattern: #"Resources:\s*(.+)$"#)
    private static let kernelRegex = try! NSRegularExpression(
        pattern: #"Kernel Assertions:\s*(.+)$"#)

    public static func parse(_ text: String, capturedAt: Date = Date()) -> LiveAssertionsState {
        var assertions: [ActiveAssertion] = []
        var kernel: [String] = []

        var pending: (pid: Int, process: String, type: String, name: String, held: TimeInterval)?
        var pendingCreatedFor: Int?
        var pendingResources: String?

        func flush() {
            if let p = pending {
                assertions.append(ActiveAssertion(
                    pid: p.pid, process: p.process, type: p.type, name: p.name,
                    heldSeconds: p.held, createdForPID: pendingCreatedFor,
                    resources: pendingResources))
            }
            pending = nil
            pendingCreatedFor = nil
            pendingResources = nil
        }

        text.enumerateLines { line, _ in
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            if let m = pidLineRegex.firstMatch(in: line, range: full) {
                flush()
                let pid = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let process = ns.substring(with: m.range(at: 2))
                let h = Int(ns.substring(with: m.range(at: 4))) ?? 0
                let mm = Int(ns.substring(with: m.range(at: 5))) ?? 0
                let ss = Int(ns.substring(with: m.range(at: 6))) ?? 0
                let type = ns.substring(with: m.range(at: 7))
                let name = ns.substring(with: m.range(at: 8))
                pending = (pid, process, type, name, TimeInterval(h * 3600 + mm * 60 + ss))
                return
            }
            if let m = createdForRegex.firstMatch(in: line, range: full) {
                pendingCreatedFor = Int(ns.substring(with: m.range(at: 1)))
                return
            }
            if let m = resourcesRegex.firstMatch(in: line, range: full), pending != nil {
                pendingResources = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                return
            }
            if let m = kernelRegex.firstMatch(in: line, range: full) {
                let raw = ns.substring(with: m.range(at: 1))
                // "0x104=USB,MAGICWAKE" → ["USB", "MAGICWAKE"]
                if let eq = raw.firstIndex(of: "=") {
                    kernel = raw[raw.index(after: eq)...]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                } else if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    kernel = [raw.trimmingCharacters(in: .whitespaces)]
                }
                return
            }
        }
        flush()

        return LiveAssertionsState(capturedAt: capturedAt, assertions: assertions, kernelAssertions: kernel)
    }
}
