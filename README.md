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

- **What is stored locally**: the read-only device token at `$XDG_STATE_HOME/nowah-omarchy/token` (default `~/.local/state/nowah-omarchy/token`; file mode 600, directory 700; a symlinked state base is followed only when it resolves to a directory you own), a transient `device.json` during pairing only, and the last sync snapshot in `status.json` (trip names/dates/flights — no secrets). Recent searches stay in the shell's own `shell.json` as before.
- **Pinned origins**: the plugin talks only to `https://api.nowah.xyz` and opens only `https://app.nowah.xyz`. Neither is configurable from plugin settings, and the stored token is bound to that origin — a credential can never be presented to another host. (A developer override exists solely for hand-run testing: `NOWAH_DEV_API_ORIGIN` *and* `NOWAH_DEV_CONSENT=1` must both be set in the environment, and it uses a separate `nowah-omarchy-dev` state directory, so no production credential is ever reused.)
- **No PATH resolution, and secrets never touch a command line**: the helper is Python 3 stdlib only — it executes no `curl`, `jq`, `stat`, `mv`, `head` or `timeout`, so a shadowed tool can never observe a credential. HTTPS is done in-process (`urllib` + the system trust store, TLS 1.2+), so the bearer token exists only in this process's memory and in its 0600 file — never in any argv or environment. **HTTP is a closed loop to the pinned origin**: redirects are never followed (any 3xx is treated as a transport failure, so the bearer header can never travel to another origin, a downgraded `http://` URL, or a loopback/private/link-local service), the handler chain is built from an empty `OpenerDirector` (https only — no file/ftp/data/http handlers, no proxy handler, so `https_proxy`/`all_proxy` in the environment are never consulted, no cookies, no auth negotiation), and the peer address is resolved once, vetted against loopback/private/link-local/multicast/reserved ranges, and then pinned for the connection while TLS verification keeps the real hostname — a DNS answer cannot change between the check and the connect. The shell launches only `/usr/bin/python3 -I -B` with the plugin's own absolute script path, **with the process environment cleared** and replaced by an explicit allowlist (fixed `PATH`, `HOME`, locale, and the display/D-Bus/XDG variables the browser launcher needs) — the graphical session's environment is never inherited, so `LD_PRELOAD`, `OPENSSL_CONF`, `SSL_CERT_FILE`/`SSL_CERT_DIR`, resolver variables (`LOCALDOMAIN`, `RES_OPTIONS`, `HOSTALIASES`), `PYTHON*` and proxy settings can never reach the process that holds the token. The helper enforces the same thing itself: it scrubs those variables before `ssl` is imported, re-execs with the clean environment and `-I` if it was started any other way, and builds its TLS context from the system trust store explicitly. Isolated mode means `PYTHONPATH`, `PYTHONHOME`, `sitecustomize` and the user site-packages directory are ignored too. The single external program ever run is the browser opener, resolved from a fixed list of absolute locations (system-wide first, then Omarchy's own `~/.local/share/omarchy/bin`) and verified (regular file, executable, owned by root or by you, not group/world-writable) before `execve` with an allowlisted session environment (display, D-Bus, XDG and locale variables; never `LD_*`, `PYTHON*`, proxies or `NOWAH_*`). It receives no credential material — only a path that is re-validated against the pinned app origin. The pairing request identifies the client only as `"Omarchy"`; no hostname or machine identifier is sent, and the flight number for a status lookup travels in the helper's environment, not argv.
- **Bounded everywhere**: responses are size-capped on the wire and on disk (512 KiB for trips, 32 KiB otherwise), kept in private files rather than shell variables, and reduced through a strict whitelist schema (≤25 trips, ≤12 flights per trip, bounded string lengths, flat weather) before anything reaches `status.json` (≤256 KiB, fail-closed). All API strings are stripped of markup and control characters and every panel `Text` renders as `Text.PlainText`, so nothing from the network is ever interpreted as rich text. On the shell side the snapshot is never loaded through `FileView`: it is read by the helper's `read-snapshot` command through the same no-follow, non-blocking, `fstat`-verified primitive, which reads at most 262144 bytes and **exits with an error (printing nothing) if the file is even one byte larger**, so an oversized file whose first 256 KiB happen to parse can never be mistaken for a valid snapshot. The parsed object is then re-validated (types, string lengths, ≤25 trips / ≤12 flights, numeric finiteness, pairing-URL shape) before it becomes model state. Search queries are capped at 200 characters and stripped of control characters at every entry point (text field, IPC, recents), recents are capped at 4 bounded entries, and only known settings keys are ever written back to the shell's configuration. Each helper run has a 40 s **wall-clock** deadline (a `SIGALRM` timer that interrupts even a blocking TLS handshake or a peer that drips one byte at a time to keep per-operation timeouts alive), is supervised by an in-shell watchdog, and stops on its own if its supervising shell process disappears; on plugin reload or disable any in-flight helper is signalled and in every case bounded to well under a minute. Helper runs are serialised with `flock` on the state directory descriptor.
- **Safe-by-construction state I/O**: there is no check-then-open anywhere. The state directory is opened `O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC` and `fstat`-verified (directory, ours), then `chmod 700` through that descriptor; the run lock is `flock` on that descriptor itself, so no lock file exists. Every leaf is opened **relative to that descriptor** with `O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC` and `fstat`-verified (regular file, ours, exactly one link, within its cap) before a byte is read — a symlink fails the open with `ELOOP` and a FIFO returns immediately and fails the `fstat`, so neither can be substituted between a check and an open, and neither can block a run. Publication opens a fresh `O_CREAT|O_EXCL|O_NOFOLLOW` 0600 temp at the directory descriptor, writes and `fsync`s through it, then renames with **both sides descriptor-relative**; nothing pre-existing is ever opened for writing, so nothing can be truncated, and `rename` replaces a symlink without following it. HTTP bodies never touch the filesystem. The previous snapshot is re-validated through the same schema before any field is carried forward. Other same-UID processes, including other plugins, are inside this threat model.
- **Exact endpoints contacted** (all on `https://api.nowah.xyz`):
  - `GET /trips` and `GET /notifications/unread-count` — authenticated with the device token
  - `GET /flights/:num/status` — public, flight-day only
  - `POST /device-auth/code` and `POST /device-auth/token` — during pairing only
- **Cadence**: one sync per hour normally, every 10 minutes on flight day, plus at most one on panel open (rate-limited to once a minute).
- **Scope**: the device token is read-only — it cannot book, modify, or cancel anything. Revoke it at <https://app.nowah.xyz/settings?section=security>.
- **No third parties, no telemetry**: the plugin talks only to the Nowah API and opens the Nowah web app. Nothing is sent anywhere else.

## Requirements

- Omarchy 4.0 "Quattro" or later (the Quickshell-based shell with plugin support)
- `python3` (Arch/Omarchy base) — the sync helper is a single Python 3 stdlib script; it needs no other program, no third-party module, and no compilation

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
node --test tests/                     # pure-JS trip state machine (25 tests)
python3 tests/state_io_test.py         # adversarial state I/O, lock semantics, UTC handling, process boundaries
python3 tests/http_boundary_test.py    # redirects/credential/proxy/address/deadline/environment boundary vs a real TLS server
python3 -m py_compile bin/nowah-sync   # helper syntax
```

`tests/state_io_test.py` plants FIFOs, symlinks and hardlinks over the state directory and its leaves, runs the helper with an **empty `PATH`**, and checks the exact-size snapshot boundary. `tests/http_boundary_test.py` starts a real TLS server in-process (self-signed cert via `openssl`) and proves that same-origin, cross-origin, `http://` downgrade, loopback, private and looping redirects are all refused after exactly one request, that the bearer never reaches a second origin, that environment proxies are ignored, that non-public resolutions of the production origin are refused, that a byte-dripping peer is cut off by the wall-clock deadline, and that `SSL_CERT_FILE`/`OPENSSL_CONF`/`LD_PRELOAD` in the environment have no effect on the TLS trust store or the process. The whole security posture is reproducible without an Omarchy shell.

The state machine (`Model.js`) is a `.pragma library` port of the mobile app's widget engine and is fully unit-tested without a running shell. The sync helper (`bin/nowah-sync`, Python 3 stdlib) owns all network, secret and filesystem handling; QML never sees the token and never resolves a program name.

## Troubleshooting

- **"Session expired — reconnect."** — the device token was revoked (from the app's security settings or server-side). Click **Connect Nowah** to pair again.
- **Stale data marker** (small warning glyph next to UPCOMING TRIPS) — the last sync failed; the panel keeps showing the previous snapshot and retries on schedule, or use the `refresh` IPC call.
- **Testing against a staging API** — origins are pinned and not configurable from the plugin, and the plugin explicitly unsets the override variables for the helper. For hand-run helper testing only, export `NOWAH_DEV_API_ORIGIN=https://<staging-host>` together with `NOWAH_DEV_CONSENT=1`; the helper then uses a separate `~/.local/state/nowah-omarchy-dev/` directory (which the panel does not watch) and never reuses a production credential.
- **Pairing code expired** — codes live 10 minutes; click "get new code" in the panel.

## License

MIT — see [LICENSE](./LICENSE).
