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
- **Exact endpoints contacted** (all on `api.nowah.xyz`, or your configured API URL):
  - `GET /trips` and `GET /notifications/unread-count` — authenticated with the device token
  - `GET /flights/:num/status` — public, flight-day only
  - `POST /device-auth/code` and `POST /device-auth/token` — during pairing only
- **Cadence**: one sync per hour normally, every 10 minutes on flight day, plus at most one on panel open (rate-limited to once a minute).
- **Scope**: the device token is read-only — it cannot book, modify, or cancel anything. Revoke it at <https://app.nowah.xyz/settings?section=security>.
- **No third parties, no telemetry**: the plugin talks only to the Nowah API and opens the Nowah web app. Nothing is sent anywhere else.

## Requirements

- Omarchy 4.0 "Quattro" or later (the Quickshell-based shell with plugin support)
- `curl` and `jq` (both ship with Omarchy) for the sync helper

## Install

```bash
omarchy plugin add https://github.com/maslinedwin/nowah-travel --enable
```

Or from the Omarchy menu: **Setup > Plugins**.

To remove:

```bash
omarchy plugin remove xyz.nowah.travel
```

Removing the plugin does not delete `~/.local/state/nowah-omarchy/` — run the panel's "disconnect" first (or delete the directory) if you want the token gone, and revoke the device in the app.

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
| `apiUrl` | string | `https://api.nowah.xyz` | API endpoint for the trip sync (staging: point this at your staging API) |
| `appUrl` | string | `https://app.nowah.xyz` | Web app opened by searches and deep links |
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
- **Staging / self-hosted API** — set the `apiUrl` plugin setting; the sync helper also honors `NOWAH_API_URL` and `NOWAH_STATE_DIR` environment variables when run by hand.
- **Pairing code expired** — codes live 10 minutes; click "get new code" in the panel.

## License

MIT — see [LICENSE](./LICENSE).
