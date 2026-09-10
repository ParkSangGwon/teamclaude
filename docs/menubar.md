# Menu bar app (macOS)

`macos/` holds **TeamClaude Bar**, a native menu bar client for a running proxy: the
account rotation is on right now, how much of each account's 5-hour and weekly
quota is left, and the settings screen — without switching to a terminal.

It is a pure client of the control plane the proxy already exposes
(`GET /teamclaude/status`, `GET /teamclaude/quota`, `POST /teamclaude/switch`,
`POST /teamclaude/reload`) and of the `teamclaude` CLI for everything that writes
the config. It adds no server endpoint, and `files` in `package.json` keeps it out
of the npm package.

## Requirements

- macOS 14 (Sonoma) or newer.
- A running proxy: `teamclaude service install`, or `teamclaude server` in a
  terminal.
- The CLI reachable in one of these ways, checked in this order: a path set in
  Settings → Proxy, the LaunchAgent's own `node` + entry path
  (`~/Library/LaunchAgents/com.karpeleslab.teamclaude.plist`), then `teamclaude`
  on the login shell's PATH.
- To build: Xcode 16 or newer (Swift 6).

## Build and install

```bash
make -C macos app        # dist/TeamClaude Bar.app, ad-hoc signed
make -C macos install    # copies it to /Applications
```

The bundle is signed ad hoc, not notarized: on first launch macOS asks you to
confirm in System Settings → Privacy & Security → *Open Anyway* (or run
`xattr -dr com.apple.quarantine "/Applications/TeamClaude Bar.app"`). The version
shown in *About* is the proxy release the app was built from.

## What it shows

- **Current account** — the 5-hour and weekly bars with the reset countdown, the
  per-family weeks the account meters separately, overage spend against its limit,
  and a *Next* line: where the next unrouted request goes and why (priority, the
  old account's reason, expiry routing, or the adaptive scorer's own line).
- **Fleet** — tier-weighted aggregates coloured by the same pace rule as the
  account bars, every account's coming window resets (`↑` marks one that brings an
  account back into rotation), and the keep-warm state.
- **Accounts** — one row per account: session / weekly / per-family bars with the
  number and reset under each, the sessions pinned to it by model family, and the
  row menu (make current, enable, priority, remove). The tooltip carries expiry
  pressure and, in adaptive mode, the scorer's weight and headroom.
- **Sessions** — with `proxy.sessionDetail` on, which Claude Code session is pinned
  to which account, what is in flight, and which one is starving.
- **Rotation** — the last five rotations with the router's reason; the full log
  (fifty entries) is under Settings → Rotation.
- **History** (Settings) — seven days of samples the app took itself, one a minute:
  a fleet sparkline and a state strip per account, kept in
  `~/Library/Application Support/TeamClaudeBar/history.json`.

Global shortcuts (no Accessibility permission): `⌃⌥⌘N` moves traffic to the next
account that can serve, `⌃⌥⌘T` opens the popover. Both can be turned off in
Settings → General.

Notifications cover fleet thresholds, a rotation (with its reason), an account
leaving or re-entering rotation, a re-login needed, the quota probe failing, a
hold, the proxy going away, and overage billing. Polling slows to every five
minutes while the display is off or the session is locked and halves in Low Power
Mode.

## What applies live and what needs a restart

A change made in the app goes through the CLI when a command exists
(`threshold`, `probe`, `warmup`, `distribute`, `priority`, `enable`/`disable`,
`route`, `login`, `import`, `remove`) and through an atomic edit of
`~/.config/teamclaude.json` otherwise, followed by `POST /teamclaude/reload`.
Every control shows whether the proxy picks the change up live or on its next
start; startup-only keys (`proxy.port`, `holdSeconds`, `logDir`, …) collect in a
bar with a *Restart service* button. See [Configuration](configuration.md) for
the per-field rule.

## Service health

Settings → Proxy & Service shows what `launchctl` knows about the LaunchAgent and
who actually holds the proxy port. The case it is built for: a `teamclaude server`
left running in a terminal keeps the port, and the LaunchAgent installed later
crash-loops behind it (`Port 3456 is already in use` every few seconds in
`~/Library/Logs/teamclaude.log`). The pane names the foreground process so you can
quit it and let the agent take over.

## Editing the file directly

Settings → Advanced → *Edit as JSON…* opens the whole config with every secret
replaced by a placeholder; the placeholders are swapped back on save, unknown keys
are kept, and the proxy is reloaded. *Export diagnostics…* writes `status.json`,
`quota.json`, the config with secrets removed, `launchctl print` and the app's own
state to a folder in Downloads.

Writes take the advisory lock the proxy and the CLI share from 1.1.19 on,
`<config>.lock` beside the configured path (created exclusively with the writer's
pid, stale after ten seconds, waited for at most two seconds and then bypassed —
it coordinates, it never blocks forever). Older proxies ignore it; the app still
detects their concurrent writes by re-checking the file before its rename.

## Security notes

The app reads `proxy.port`, `proxy.host` and `proxy.apiKey` from the config and
sends the key on every request, so it works with `proxy.trustLoopback: false`. An
edit reads the whole file, changes one key and writes it back the way the proxy
does (temp file, `fsync`, rename, mode `0600`); token values pass through
unchanged and the app never edits them, nor does it write them anywhere else.
"Open Dashboard" puts the proxy key on the clipboard because the dashboard page
asks for it once; the item is marked concealed and transient so clipboard
managers skip it and Universal Clipboard does not sync it.
