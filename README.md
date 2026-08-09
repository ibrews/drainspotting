# ⚡ Drainspotting — the engine

**The analysis engine and free CLI behind [Drainspotting.app](https://drainspotting.app), the battery autopsy your Mac never gave you.**

Your MacBook lost 40% overnight and Apple's Battery settings shrug. macOS actually logs everything — every sleep, wake, and "who's holding the machine awake" record — it just never shows you. `DrainspottingKit` reads that log and turns it into an autopsy: what drained your battery, which app blocked sleep, and what woke your Mac at 3 AM.

This repo is the whole analysis engine, open source and MIT-licensed:

- **`DrainspottingKit`** — pure-Swift parsing + analysis, zero dependencies, 100% unit-tested against real captured `pmset` fixtures
- **`drainspot`** — the free CLI built on it: same engine, in your terminal

The **menu bar app** (charts, culprit UI, live sleep-blocker view, one-time purchase after a 14-day trial) is closed-source and lives in a separate private repo — it's built on this engine via a normal Swift Package dependency, nothing special. This repo is what does the actual work; the app is a UI on top of it.

## Install the CLI

```bash
git clone https://github.com/ibrews/drainspotting && cd drainspotting
swift build -c release --product drainspot
cp .build/release/drainspot /usr/local/bin/
```

`drainspot` is always free and full-featured — no trial, no license, nothing gated. Ever.

## Things to Try

1. **Run your first autopsy** — `drainspot` in a terminal. It reads ~1 week of history from your Mac's own power log and prints what drained the battery in your last unplugged session.
2. **Catch a sleep-blocker red-handed** — start a YouTube video, then run `drainspot --live`. Watch the audio assertion appear with the app that owns it; pause, run again, watch it clear.
3. **Find your multi-day squatter** — `drainspot --sessions 10`, look for the longest-held assertion. Epic Games Launcher's 66-hour "Running dedicated server" assertion was found on the very first Mac this ran on.
4. **Pipe it** — `drainspot --json | jq '.[0].culprits[0]'` for scripting, dashboards, or nagging your coworker about Docker.
5. **Read the parser** — `Sources/DrainspottingKit/PMSetLogParser.swift` turns `pmset -g log`'s ~60,000-line text dump into structured events. `swift test` runs the full suite against real captured logs, not synthetic toy data.

## How it works

macOS's `powerd` keeps a detailed rolling log (`pmset -g log`): sleep/wake transitions with causes, battery percentage over time, and every power assertion any process created or released — with PID, duration, and name. `DrainspottingKit` parses that log, reconstructs per-charge discharge sessions, attributes awake-time to the processes that held assertions, and translates the identifiers into human explanations with fixes (`Humanizer.swift`).

No kernel extensions, no root, no helpers — it reads the same data `pmset` shows, just made legible.

## Architecture

```
Sources/DrainspottingKit/   the engine: parsers, session builder, culprit analyzer, humanizer, license verifier
Sources/drainspot/          free CLI, same engine
Tests/                      real pmset/ioreg fixtures + synthetic edge cases
```

`swift test` runs the suite.

`LicenseVerifier.swift` is included here (not in the private app repo) because it only *verifies* a license signature against an embedded public key — no secret, nothing to hide, and it's the kind of code you'd want to audit before trusting a "fully offline, no network call" claim. The private signing key lives server-side and is never in any repo.

## License

MIT — see [LICENSE](LICENSE). This repo is the engine and CLI only; the menu bar app is a separate, closed-source product.

---

An **Alex Coulombe Presents** production · [drainspotting.app](https://drainspotting.app)

## Support

If you like seeing this kind of thing get built and shared, [donations are always welcome](https://www.alexcoulombepresents.com/support) — they buy hardware, render time, and the freedom to keep giving most of this away.
