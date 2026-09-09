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
- The CLI reachable in one of these ways, checked in this order: the LaunchAgent's
  own `node` + entry path (`~/Library/LaunchAgents/com.karpeleslab.teamclaude.plist`),
  `teamclaude` on the login shell's PATH, or a path set in Settings → Proxy.
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

## Security notes

The app reads `proxy.port` and `proxy.apiKey` from the config and sends the key on
every request, so it works with `proxy.trustLoopback: false`. It never reads or
rewrites account tokens: an edit touches one key and writes the file the way the
proxy does (temp file, `fsync`, rename, mode `0600`). Nothing is copied anywhere
else; "Open Dashboard" puts the proxy key on the clipboard because the dashboard
page asks for it once.
