import Foundation

/// Translates raw power-management identifiers into plain English.
/// This is the product's soul: every mapping states what it means and what
/// (if anything) the user can do about it.
public enum Humanizer {

    // MARK: - Process knowledge base

    struct ProcessInfo {
        let displayName: String
        let meaning: String
        let suggestion: String?
        let systemInternal: Bool

        init(_ displayName: String, meaning: String, suggestion: String? = nil,
             systemInternal: Bool = false) {
            self.displayName = displayName
            self.meaning = meaning
            self.suggestion = suggestion
            self.systemInternal = systemInternal
        }
    }

    static let knownProcesses: [String: ProcessInfo] = [
        "coreaudiod": ProcessInfo("Audio playback",
            meaning: "An app was playing (or capturing) audio, which keeps the Mac awake. macOS logs this against its audio engine, coreaudiod, on behalf of the real app.",
            suggestion: "Pause playback or quit the app that was using audio when you step away."),
        "powerd": ProcessInfo("macOS power manager",
            meaning: "The system's own bookkeeping — usually \"keep awake while the display is on.\" A symptom of the display being on, not a misbehaving app.",
            systemInternal: true),
        "WindowServer": ProcessInfo("Display / input activity",
            meaning: "You were actively using the Mac (keyboard, trackpad, or display activity).",
            systemInternal: true),
        "loginwindow": ProcessInfo("Login window",
            meaning: "Session management held a brief assertion; routine.",
            systemInternal: true),
        "sharingd": ProcessInfo("AirDrop / Handoff / Continuity",
            meaning: "Sharing services (AirDrop, Handoff, Instant Hotspot) briefly kept the Mac available.",
            suggestion: "Turn off AirDrop/Handoff in System Settings > General > AirDrop & Handoff if you never use them."),
        "apsd": ProcessInfo("Apple push notifications",
            meaning: "The push-notification service checked in with Apple's servers.",
            systemInternal: true),
        "mDNSResponder": ProcessInfo("Network discovery (Bonjour)",
            meaning: "Network services renewed leases or answered discovery traffic — a common cause of scheduled wakes while asleep.",
            suggestion: "Consider disabling \"Wake for network access\" in System Settings > Battery > Options."),
        "bluetoothd": ProcessInfo("Bluetooth",
            meaning: "A Bluetooth accessory interaction kept the system available.",
            suggestion: "Disconnect unused Bluetooth accessories before closing the lid."),
        "installd": ProcessInfo("Software installation",
            meaning: "macOS was installing or updating software.",
            systemInternal: true),
        "softwareupdated": ProcessInfo("macOS software update",
            meaning: "The system was downloading or preparing a macOS update."),
        "mds": ProcessInfo("Spotlight indexing",
            meaning: "Spotlight was indexing files, which can prevent sleep during heavy churn.",
            suggestion: "Usually settles on its own. If constant, check what's writing lots of files."),
        "mds_stores": ProcessInfo("Spotlight indexing",
            meaning: "Spotlight was indexing files.",
            suggestion: "Usually settles on its own."),
        "corespotlightd": ProcessInfo("Spotlight indexing",
            meaning: "App-content indexing for Spotlight."),
        "photoanalysisd": ProcessInfo("Photos analysis",
            meaning: "Photos was scanning your library (faces, scenes, memories). It's supposed to run while idle on power — on battery it can eat real percentage.",
            suggestion: "Plug in overnight once to let it finish, or pause by opening Photos (it yields while the app is frontmost)."),
        "mediaanalysisd": ProcessInfo("Media analysis",
            meaning: "System machine-learning pass over photos/videos.",
            suggestion: "Same as Photos analysis — let it finish on AC power."),
        "backupd": ProcessInfo("Time Machine",
            meaning: "A Time Machine backup was running or waiting on a destination.",
            suggestion: "If backups run on battery, consider limiting them to power via Time Machine options."),
        "cloudd": ProcessInfo("iCloud sync",
            meaning: "iCloud was syncing data.",
            suggestion: "Large first-time syncs are best done on AC power."),
        "bird": ProcessInfo("iCloud Drive",
            meaning: "iCloud Drive was uploading or downloading files."),
        "nsurlsessiond": ProcessInfo("Background downloads",
            meaning: "A background transfer (App Store, iCloud, app downloads) was in flight."),
        "dasd": ProcessInfo("Background task scheduler",
            meaning: "macOS's Duet scheduler ran queued background activities — a normal source of DarkWake maintenance activity.",
            systemInternal: true),
        "caffeinate": ProcessInfo("caffeinate (Terminal)",
            meaning: "Someone ran the `caffeinate` command to keep the Mac awake on purpose.",
            suggestion: "Find the Terminal window running it, or `killall caffeinate`."),
        "Amphetamine": ProcessInfo("Amphetamine",
            meaning: "The Amphetamine utility was intentionally keeping your Mac awake.",
            suggestion: "End the Amphetamine session when you're done."),
        "KeepingYouAwake": ProcessInfo("KeepingYouAwake",
            meaning: "The KeepingYouAwake utility was intentionally keeping your Mac awake.",
            suggestion: "Click its menu bar icon to deactivate."),
        "Docker": ProcessInfo("Docker Desktop",
            meaning: "Docker Desktop's VM held the system awake — containers keep running with the lid open.",
            suggestion: "Quit Docker Desktop when you're not using containers; it's a heavy idle consumer."),
        "com.docker.backend": ProcessInfo("Docker Desktop",
            meaning: "Docker Desktop's VM held the system awake.",
            suggestion: "Quit Docker Desktop when you're not using containers."),
        "zoom.us": ProcessInfo("Zoom",
            meaning: "Zoom held the Mac awake — typically an active or backgrounded meeting.",
            suggestion: "Fully quit Zoom after meetings; it sometimes lingers."),
        "Teams": ProcessInfo("Microsoft Teams",
            meaning: "Teams held the Mac awake.",
            suggestion: "Quit Teams fully when done; the tray process can hold assertions."),
        "Spotify": ProcessInfo("Spotify",
            meaning: "Spotify was playing (or paused holding an audio session).",
            suggestion: "Quit Spotify rather than just pausing before unplugging."),
        "EpicGamesLauncher-Mac-Shipping": ProcessInfo("Epic Games Launcher",
            meaning: "Epic's launcher declared itself a \"dedicated server\" and can hold your Mac awake for days.",
            suggestion: "Quit Epic Games Launcher when not gaming — it's a notorious multi-day sleep blocker."),
        "steam_osx": ProcessInfo("Steam",
            meaning: "Steam (often downloading updates) kept the Mac awake.",
            suggestion: "Quit Steam or pause downloads when on battery."),
        "obs": ProcessInfo("OBS",
            meaning: "OBS was recording, streaming, or holding a capture session."),
        "xcodebuild": ProcessInfo("Xcode build",
            meaning: "A command-line Xcode build was running.",
            systemInternal: false),
        "Xcode": ProcessInfo("Xcode",
            meaning: "Xcode was building, indexing, or running.",
            suggestion: "Long indexing passes are normal after big checkouts; they block sleep until done."),
        "screensharingd": ProcessInfo("Screen Sharing",
            meaning: "Someone was connected to this Mac over Screen Sharing."),
        "AddressBookSourceSync": ProcessInfo("Contacts sync",
            meaning: "Contacts was syncing.",
            systemInternal: true),
        "PowerChime": ProcessInfo("Power chime", meaning: "Charging chime helper.", systemInternal: true),
    ]

    /// Assertion names that identify intent better than the owning process does.
    static let assertionNameRules: [(fragment: String, info: ProcessInfo)] = [
        ("Electron", ProcessInfo("An Electron app",
            meaning: "An Electron-based app (Slack, Discord, VS Code, Notion, Claude, etc.) used the stock \"Electron\" power assertion, which hides its real name at this layer.",
            suggestion: "Check the Live view while it happens — the process column names the actual app.")),
        ("prevent app nap", ProcessInfo("App Nap opt-out",
            meaning: "An app asked macOS not to throttle it in the background.")),
        ("Running dedicated server", ProcessInfo("Epic Games Launcher",
            meaning: "Epic's launcher declares a \"dedicated server\" assertion and can hold your Mac awake for days.",
            suggestion: "Quit Epic Games Launcher when not gaming.")),
        ("com.apple.audio", ProcessInfo("Audio playback",
            meaning: "An app was playing or capturing audio via the system audio engine.",
            suggestion: "Pause playback or quit the app before stepping away.")),
        ("Time Machine", ProcessInfo("Time Machine",
            meaning: "A backup was in progress.")),
        ("Handoff", ProcessInfo("Handoff",
            meaning: "Continuity features briefly kept the system available.")),
    ]

    // MARK: - Assertion types

    public static func describeAssertionType(_ type: String) -> String {
        switch type {
        case "PreventUserIdleSystemSleep":
            return "Prevented the Mac from sleeping when idle"
        case "PreventUserIdleDisplaySleep":
            return "Kept the display awake"
        case "NoIdleSleepAssertion":
            return "Prevented idle sleep"
        case "NoDisplaySleepAssertion":
            return "Kept the display awake"
        case "PreventSystemSleep":
            return "Blocked sleep entirely (even the power button's schedule)"
        case "InternalPreventDisplaySleep":
            return "System kept the display from sleeping"
        case "UserIsActive":
            return "Registered you as actively using the Mac"
        case "BackgroundTask":
            return "Ran a background task"
        case "ApplePushServiceTask":
            return "Checked for push notifications"
        case "NetworkClientActive":
            return "A network client was connected"
        case "ExternalMedia":
            return "External media was mounted"
        case "SystemIsActive", "DeclareSystemActivity":
            return "Declared system activity"
        default:
            return type
        }
    }

    public static let sleepPreventingTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "PreventSystemSleep",
        "BackgroundTask", "NetworkClientActive",
    ]

    // MARK: - Culprit explanation

    public static func explain(process: String, assertionType: String, assertionName: String,
                               heldSeconds: TimeInterval, windowSeconds: TimeInterval)
    -> (displayName: String, explanation: CulpritExplanation, systemInternal: Bool) {

        var info = knownProcesses[process]
        if info == nil {
            for rule in assertionNameRules where assertionName.localizedCaseInsensitiveContains(rule.fragment) {
                info = rule.info
                break
            }
        }
        // Second pass: a name rule can refine a generic process (coreaudiod → real intent).
        if process == "coreaudiod" {
            info = knownProcesses["coreaudiod"]
        }

        let display = info?.displayName ?? process
        let systemInternal = info?.systemInternal ?? false

        let meaning = info?.meaning ??
            "\(process) held a \"\(describeAssertionType(assertionType).lowercased())\" assertion. It isn't in Drainspotting's knowledge base yet — the assertion name below is the best clue to what it was doing."
        let suggestion = info?.suggestion

        let severity: CulpritExplanation.Severity
        let significant = heldSeconds > max(1800, windowSeconds * 0.25)
        if systemInternal {
            severity = .info
        } else if significant && sleepPreventingTypes.contains(assertionType) {
            severity = .heavy
        } else if heldSeconds > 300 {
            severity = .notable
        } else {
            severity = .info
        }

        let title = describeAssertionType(assertionType)
        return (display, CulpritExplanation(title: title, meaning: meaning,
                                            suggestion: suggestion, severity: severity),
                systemInternal)
    }

    // MARK: - Wake causes

    public static func describeWakeCause(_ raw: String, matchedRequest: ScheduledWakeRequest?) -> (title: String, detail: String) {
        let lower = raw.lowercased()

        var title: String
        var detail: String

        if lower.contains("lid") || lower.contains("ec.lidopen") {
            title = "Lid opened"
            detail = "You (or someone) opened the MacBook's lid."
        } else if lower.contains("hid activity") || lower.contains("hid.") {
            title = "Keyboard / trackpad"
            detail = "Input activity woke the Mac."
        } else if lower.contains("powerbutton") {
            title = "Power button"
            detail = "The power button was pressed."
        } else if lower.contains("ec.acattach") || lower.contains("acattach") {
            title = "Power connected"
            detail = "The charger was plugged in, which wakes the machine briefly."
        } else if lower.contains("rtc/sleepservice") || lower.contains("sleepservice") {
            title = "Scheduled maintenance (Power Nap)"
            detail = "macOS woke itself on a timer to run background maintenance in the dark — the screen stays off."
        } else if lower.contains("rtc") {
            title = "Scheduled wake"
            detail = "A timer set by the system or an app woke the Mac."
        } else if lower.contains("wifibt") || lower.contains("magicwake") || lower.contains("network") {
            title = "Network wake"
            detail = "Network traffic (Wake-on-LAN / Bonjour) woke the Mac. Controlled by \"Wake for network access\" in System Settings > Battery > Options."
        } else if lower.contains("smc.outboxnotempty") {
            title = "Internal controller"
            detail = "The system-management controller had pending events to deliver (often accompanies lid/input wakes)."
        } else if lower.contains("nub.spmi") {
            title = "Hardware timer"
            detail = "A low-level hardware interrupt (often the RTC pathway on Apple Silicon) triggered the wake."
        } else if lower.contains("tcpkeepalive") {
            title = "Network keep-alive"
            detail = "A TCP keep-alive timer fired to maintain connections (push email, messaging)."
        } else if lower.contains("notification") {
            title = "Notification"
            detail = "A system notification pathway woke the Mac."
        } else {
            title = "Wake"
            detail = raw
        }

        if let request = matchedRequest {
            let requester = knownProcesses[request.process]?.displayName ?? request.process
            var extra = "Scheduled by \(requester)"
            if let info = request.info, !info.isEmpty {
                extra += " (\(friendlyRequestInfo(info)))"
            }
            detail += " " + extra + "."
        }
        return (title, detail)
    }

    static func friendlyRequestInfo(_ info: String) -> String {
        if info.contains("DHCP") { return "DHCP lease renewal" }
        if info.contains("com.apple.alarm") { return "system alarm" }
        if info.contains("backup") { return "backup schedule" }
        return info
    }

    // MARK: - Formatting helpers

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let remM = m % 60
        if h < 48 { return remM > 0 ? "\(h)h \(remM)m" : "\(h)h" }
        let d = h / 24
        return "\(d)d \(h % 24)h"
    }
}
