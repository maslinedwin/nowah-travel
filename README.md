# Nowah for Omarchy

An [Omarchy](https://omarchy.org) shell plugin for [Nowah](https://app.nowah.xyz), the AI travel booking app. Version 1.0 keeps the "Where to?" search panel and adds **your live trips**: pair the plugin with your Nowah account (read-only) and the panel shows your upcoming trips with a countdown, the bar icon counts down to departure, and on flight day the widget switches into a live flight-status mode.

<p align="center">
  <img src="assets/preview.svg" width="560" alt="Nowah panel: search input, upcoming trips with a Tokyo hero card and jade countdown chip, quick-link tiles"/>
</p>

## Features

- **Live trips in the panel** — an UPCOMING TRIPS section with a hero card (destination, dates, weather, jade countdown chip) plus compact rows for the next trips; every card deep-links into the app
- **Bar countdown** — the bar icon shows `12d` / `1d` / `today` when your next trip is inside the countdown window (configurable)
- **Flight-day mode** — from T-3h through landing the hero card becomes flight number, route, and a colored status dot (on time / delayed / cancelled / landed), refreshed every 10 minutes from the public flight-status endpoint; a matching dot appears on the bar icon
- **Device pairing** — connect with a short code approved in the Nowah app; the plugin only ever holds a read-only token
- **Notifications** — optional quiet jade dot + unread count pill (toggle in settings)
- **AI travel search retained** — Enter still opens the Nowah app window with your query running through the AI chat; quick-link tiles, rotating suggestions, and recent searches all work exactly as before
- **Theme-native** — layout colors derive from your active Omarchy theme; Nowah jade is used only for brand accents
- **Scriptable** — IPC target `xyz.nowah.travel` with `toggle`, `open`, `close`, `search`, `refresh`, and `connect`

All real flows (results, booking, payment, account management) run in the Nowah web app via `omarchy-launch-webapp` — nothing is re-implemented in the shell.

## How pairing works

1. Click **Connect Nowah** in the panel. The plugin requests a device code and opens `app.nowah.xyz/device` in a Nowah window.
2. The panel shows a short **user code**; verify it matches the one in the Nowah window and approve.
3. The plugin polls until approval, stores a **read-only** device token, and syncs your trips. Codes expire after 10 minutes — the panel offers "get new code" if you miss the window.

Disconnect any time from the panel footer ("disconnect"), or revoke the device from the app at <https://app.nowah.xyz/settings?section=security>. A revoked token simply flips the panel back to the connect state.

## Privacy & disclosure

- **What is stored locally**: the read-only device token at `~/.local/state/nowah-omarchy/token` (file mode 600, directory 700), a transient `device.json` during pairing only, and the last sync snapshot in `status.json` (trip names/dates/flights — no secrets). Recent searches stay in the shell's own `shell.json` as before.
- **Pinned origins**: the plugin talks only to `https://api.nowah.xyz` and opens only `https://app.nowah.xyz`. Neither is configurable from plugin settings, and the stored token is bound to that origin — a credential can never be presented to another host. (A developer override exists solely for hand-run testing: `NOWAH_DEV_API_ORIGIN` *and* `NOWAH_DEV_CONSENT=1` must both be set in the environment, and it uses a separate `nowah-omarchy-dev` state directory, so no production credential is ever reused.)
- **Secrets never touch any command line**: the bearer header reaches `curl` through a private pipe descriptor (`-K /dev/fd/N`), request bodies through stdin, and secret material is fed to `jq` on stdin (never `--arg`), so nothing sensitive is visible in process metadata (`~/.curlrc` is ignored with `-q`). The helper validates the token format and the pairing code before use and builds the verification URL itself from the pinned app origin — a server-supplied URL is never launched. The pairing request identifies the client only as `"Omarchy"`; no hostname or machine identifier is sent. The current flight number for a flight-day status lookup is passed to the helper through its environment, not argv.
- **Bounded everywhere**: responses are size-capped on the wire and on disk (512 KiB for trips, 32 KiB otherwise), kept in private files rather than shell variables, and reduced through a strict whitelist schema (≤25 trips, ≤12 flights per trip, bounded string lengths, flat weather) before anything reaches `status.json` (≤256 KiB, fail-closed). All API strings are stripped of markup and control characters and every panel `Text` renders as `Text.PlainText`, so nothing from the network is ever interpreted as rich text. Each helper run has a 40 s absolute deadline shared across all its requests, runs under `timeout -k 5 60`, is supervised by an in-shell watchdog, and stops on its own if its supervising shell process disappears; on plugin reload or disable any in-flight helper is signalled and in every case bounded to well under a minute. Helper runs are serialised with `flock`.
- **Private state I/O**: the state directory must be a real directory we own (mode 700); every leaf is checked for type, owner, and no-symlink before use and published via `O_EXCL` temp file + rename. (Check-then-use in a shell is inherently racy, but only a same-UID process can race inside a 0700 directory we own — and that process already holds everything the token protects.)
- **Exact endpoints contacted** (all on `https://api.nowah.xyz`):
  - `GET /trips` and `GET /notifications/unread-count` — authenticated with the device token
  - `GET /flights/:num/status` — public, flight-day only
  - `POST /device-auth/code` and `POST /device-auth/token` — during pairing only
- **Cadence**: one sync per hour normally, every 10 minutes on flight day, plus at most one on panel open (rate-limited to once a minute).
- **Scope**: the device token is read-only — it cannot book, modify, or cancel anything. Revoke it at <https://app.nowah.xyz/settings?section=security>.
- **No third parties, no telemetry**: the plugin talks only to the Nowah API and opens the Nowah web app. Nothing is sent anywhere else.

## Requirements

- Omarchy 4.0 "Quattro" or later (the Quickshell-based shell with plugin support)
- `curl`, `jq`, and `flock` (util-linux) — all in the Omarchy base — for the sync helper

## Install

```bash
omarchy plugin add https://github.com/maslinedwin/nowah-travel --enable
```

Or from the Omarchy menu: **Setup > Plugins**.

To remove:

```bash
omarchy plugin remove xyz.nowah.travel
```

Removing the plugin does not delete `~/.local/state/nowah-omarchy/` — run the panel's "disconnect" first (or delete the directory) if you want the token gone, and revoke the device in the app. A revoked or origin-mismatched token is deleted by the helper on its next run; a bare token written by v1.0.0 is migrated into the origin-bound format on first use.

## Usage

- **Left click** the bar icon — open the panel (`↵` search, `→` use suggestion, `esc` close)
- **Right click** — open the Nowah app window directly
- **Trip cards / rows** — open that trip in the app; **All trips →** opens the trips list
- **Flights / Hotels tiles** — seed the search box; **Trips / Plans / eSIM / Visa** — deep-link into the app

### Global hotkey

```ini
# ~/.config/hypr/bindings.conf
bindd = SUPER SHIFT N, Nowah, exec, omarchy-shell shell toggle xyz.nowah.travel
```

### IPC

```bash
omarchy-shell ipc call xyz.nowah.travel toggle    # summon/dismiss the panel
omarchy-shell ipc call xyz.nowah.travel refresh   # force a trip sync
omarchy-shell ipc call xyz.nowah.travel connect   # start device pairing
```

### Settings

In **Setup > Plugins > Nowah**:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `showRecent` | boolean | `true` | Recent searches as one-click pills |
| `rotateExamples` | boolean | `true` | Rotating example queries in the placeholder |
| `showNotifications` | boolean | `true` | Poll unread count; jade dot on the bar icon |
| `countdownDays` | integer | `14` (1–60) | Show the bar countdown when departure is within this many days |

## Develop locally

```bash
git clone https://github.com/maslinedwin/nowah-travel ~/.config/omarchy/plugins/xyz.nowah.travel
omarchy-shell shell rescanPlugins
omarchy-shell shell setPluginEnabled xyz.nowah.travel true
```

Edits under `~/.config/omarchy/plugins/` hot-reload automatically. Lint, validate, and test:

```bash
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml NowahService.qml Service.qml
omarchy plugin validate ~/.config/omarchy/plugins/xyz.nowah.travel
node --test tests/          # pure-JS trip state machine
bash -n bin/nowah-sync      # sync helper syntax
```

The state machine (`Model.js`) is a `.pragma library` port of the mobile app's widget engine and is fully unit-tested without a running shell. The sync helper (`bin/nowah-sync`) owns all network and secret handling; QML never sees the token.

## Troubleshooting

- **"Session expired — reconnect."** — the device token was revoked (from the app's security settings or server-side). Click **Connect Nowah** to pair again.
- **Stale data marker** (small warning glyph next to UPCOMING TRIPS) — the last sync failed; the panel keeps showing the previous snapshot and retries on schedule, or use the `refresh` IPC call.
- **Testing against a staging API** — origins are pinned and not configurable from the plugin, and the plugin explicitly unsets the override variables for the helper. For hand-run helper testing only, export `NOWAH_DEV_API_ORIGIN=https://<staging-host>` together with `NOWAH_DEV_CONSENT=1`; the helper then uses a separate `~/.local/state/nowah-omarchy-dev/` directory (which the panel does not watch) and never reuses a production credential.
- **Pairing code expired** — codes live 10 minutes; click "get new code" in the panel.

## License

MIT — see [LICENSE](./LICENSE).
