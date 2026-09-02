pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// NowahService — singleton bridge between bin/nowah-sync (which owns all
// network and secret handling) and the QML surfaces. It watches the atomic
// status.json snapshot, derives trip state through Model.js, and schedules
// bounded, supervised helper runs. No token ever passes through QML.
Item {
  id: root

  // ---- pinned origins (deliberately NOT configurable from plugin settings) ----

  readonly property string apiUrl: "https://api.nowah.xyz"
  readonly property string appUrl: "https://app.nowah.xyz"

  // ---- configuration (injected late via configure(settings); idempotent) ----

  property bool showNotifications: true
  property int countdownDays: 14

  function configure(settings) {
    if (!settings) return
    if (settings.showNotifications !== undefined)
      root.showNotifications = settings.showNotifications === true
    if (settings.countdownDays !== undefined) {
      var days = Number(settings.countdownDays)
      if (!isNaN(days)) root.countdownDays = Math.max(1, Math.min(60, Math.round(days)))
    }
  }

  // ---- status snapshot (written by bin/nowah-sync, watched here) ----

  readonly property string stateDir: {
    var xdg = Quickshell.env("XDG_STATE_HOME")
    if (!xdg || String(xdg).indexOf("/") !== 0) {
      var home = Quickshell.env("HOME")
      if (!home || String(home).indexOf("/") !== 0) return ""
      xdg = home + "/.local/state"
    }
    return xdg + "/nowah-omarchy"
  }
  // Mirrors the helper's MAX_STATUS_BYTES; anything larger is never parsed.
  readonly property int maxStatusBytes: 262144

  property var status: null
  property date now: new Date()

  readonly property string authState: (status && status.auth && status.auth.state) ? status.auth.state : "signed_out"
  readonly property string authError: (status && status.auth && status.auth.error) ? String(status.auth.error) : ""
  readonly property var pairing: (status && status.auth) ? (status.auth.pairing || null) : null
  readonly property var profile: (status && status.auth) ? (status.auth.profile || null) : null
  readonly property var trips: (status && Array.isArray(status.trips)) ? status.trips : []
  readonly property int unreadCount: (status && typeof status.unreadCount === "number") ? status.unreadCount : 0
  readonly property bool stale: !!(status && status.lastSync && status.lastSync.ok === false)

  // ---- derived trip state (Model.js is the single source of truth) ----

  readonly property var monitor: Model.deriveTripMonitor(root.trips, root.now)
  readonly property var upcoming: Model.upcomingTrips(root.trips, root.now)
  readonly property bool flightDay: !!(monitor && (monitor.state === "active_flight"
    || (monitor.state === "prep" && monitor.daysUntil === 0)))
  readonly property var heroCard: (root.flightDay && monitor.seg)
    ? Model.buildFlightCard(monitor.seg, status ? status.flightStatus : null, root.now)
    : null

  readonly property bool pairingLive: {
    if (root.authState !== "pairing" || !root.pairing) return false
    if (!root.pairing.expiresAt) return true
    var exp = Date.parse(root.pairing.expiresAt)
    return !isNaN(exp) && root.now.getTime() < exp
  }

  // ---- bounded snapshot reader ----
  // The snapshot is never loaded through FileView: `head -c` bounds the
  // producer to maxStatusBytes before a single byte reaches QML, and the
  // parsed object is re-validated by Model.sanitizeSnapshot (types, string
  // lengths, trip/flight cardinality, numeric finiteness, pairing URL shape)
  // before it is assigned to any model. FileView is used only as a change
  // watcher (preload: false — it never reads the file itself).

  readonly property string statusPath: root.stateDir ? root.stateDir + "/status.json" : ""

  function applySnapshotText(raw) {
    var text = String(raw || "")
    if (text.length === 0 || text.length > root.maxStatusBytes) return
    var parsed = null
    try { parsed = JSON.parse(text) } catch (e) { return }
    var snapshot = Model.sanitizeSnapshot(parsed)
    if (!snapshot) return
    root.status = snapshot
    root.now = new Date()
    root.maybeLaunchVerification()
  }

  function readSnapshot() {
    if (!root.statusPath) return
    if (readerProc.running) { readAgain.restart(); return }
    readerProc.command = ["head", "-c", String(root.maxStatusBytes), root.statusPath]
    readerProc.running = true
  }

  Process {
    id: readerProc
    // Producer-bounded: head -c caps the stream, so this collector can never
    // hold more than maxStatusBytes.
    stdout: StdioCollector { onStreamFinished: root.applySnapshotText(text) }
  }
  Timer { interval: root.watchdogMs; running: readerProc.running; onTriggered: readerProc.running = false }
  Timer { id: readAgain; interval: 150; onTriggered: root.readSnapshot() }

  FileView {
    id: statusFile
    path: root.statusPath
    preload: false
    watchChanges: true
    onFileChanged: readAgain.restart()
  }

  // Watcher fallback: atomic renames and first creation of the state dir can
  // slip past a path watcher, so also re-read periodically and on startup.
  Timer { interval: 300000; running: true; repeat: true; onTriggered: root.readSnapshot() }
  Component.onCompleted: root.readSnapshot()

  // ---- pairing hand-off: the URL is built by the helper from the validated
  //      user code + pinned app origin and re-validated here before launch.
  //      Nothing from helper stdout is ever parsed.

  property bool launchPending: false
  property string launchPriorCode: ""
  readonly property var verifyUrlPattern: /^https:\/\/app\.nowah\.xyz\/device\?code=[A-Z0-9]{4}-[A-Z0-9]{4}$/

  function maybeLaunchVerification() {
    if (!root.launchPending) return
    if (root.authState !== "pairing" || !root.pairing) return
    // Ignore a snapshot that still carries the previous pairing code.
    if (String(root.pairing.userCode || "") === root.launchPriorCode) return
    root.launchPending = false
    var url = String(root.pairing.verificationUrl || "")
    if (root.verifyUrlPattern.test(url))
      Quickshell.execDetached(["omarchy-launch-webapp", url])
  }

  // ---- helper process plumbing (every run bounded + supervised) ----

  readonly property string syncBin: {
    var url = Qt.resolvedUrl("bin/nowah-sync").toString()
    var path = url.indexOf("file://") === 0 ? url.substring(7) : url
    try { return decodeURIComponent(path) } catch (e) { return path }
  }

  // Null entries are UNSET in the helper's environment: the developer
  // override can only ever be engaged by hand, never inherited from the
  // graphical session.
  readonly property var syncEnv: ({
    NOWAH_SHOW_NOTIFICATIONS: root.showNotifications ? "1" : "0",
    NOWAH_DEV_API_ORIGIN: null,
    NOWAH_DEV_CONSENT: null,
    NOWAH_FLIGHT: null,
    NOWAH_FLIGHT_DATE: null
  })

  // Flight identity travels to the refresh run through its environment,
  // never argv (a flight number reveals the user's travel to `ps`).
  property var refreshEnv: root.syncEnv

  // timeout(1) is the whole-tree deadline (TERM at 60s, KILL 5s later); the
  // per-process watchdog Timers below are the in-shell backstop.
  function helperCommand(args) {
    return ["timeout", "-k", "5", "60", root.syncBin].concat(args)
  }

  readonly property int watchdogMs: 75000

  property double lastRefreshMs: 0

  function currentFlightEnv() {
    var env = {}
    for (var k in root.syncEnv) env[k] = root.syncEnv[k]
    var m = root.monitor
    if (root.flightDay && m && m.seg && m.seg.flight && m.seg.flight.flightNumber) {
      env.NOWAH_FLIGHT = String(m.seg.flight.flightNumber)
      env.NOWAH_FLIGHT_DATE = Model.localISODate(m.seg.dep)
    }
    return env
  }

  function runRefresh() {
    if (refreshProc.running) return
    root.lastRefreshMs = Date.now()
    root.refreshEnv = root.currentFlightEnv()
    refreshProc.command = root.helperCommand(["refresh"])
    refreshProc.running = true
  }

  /** Refresh with a 60s minimum interval so panel opens can't hammer the API. */
  function refreshNow() {
    if (Date.now() - root.lastRefreshMs < 60000) return
    root.runRefresh()
  }

  function startPairing() {
    if (pairStartProc.running) return
    root.launchPriorCode = root.pairing ? String(root.pairing.userCode || "") : ""
    root.launchPending = true
    pairStartProc.command = root.helperCommand(["pair-start"])
    pairStartProc.running = true
  }

  function runDisconnect() {
    if (disconnectProc.running) return
    root.launchPending = false
    disconnectProc.command = root.helperCommand(["disconnect"])
    disconnectProc.running = true
  }

  function cancelPairing() { root.runDisconnect() }
  function disconnect() { root.runDisconnect() }

  // First sight of a signed-in snapshot (e.g. shell start with a stored
  // token) gets fresh data instead of waiting out the refresh timer.
  onAuthStateChanged: if (authState === "signed_in") refreshNow()

  Process {
    id: refreshProc
    environment: root.refreshEnv
    onExited: root.readSnapshot()
  }
  Timer { interval: root.watchdogMs; running: refreshProc.running; onTriggered: refreshProc.running = false }

  Process {
    id: pairStartProc
    environment: root.syncEnv
    onExited: function(code) {
      if (code !== 0) root.launchPending = false
      root.readSnapshot()
    }
  }
  Timer { interval: root.watchdogMs; running: pairStartProc.running; onTriggered: pairStartProc.running = false }

  Process {
    id: pairPollProc
    environment: root.syncEnv
    // exit 10 = authorization pending; pairTimer simply polls again.
    // exit 0 after approval already ran a refresh inside the helper.
    onExited: function(code) {
      if (code === 0) root.lastRefreshMs = Date.now()
      root.readSnapshot()
    }
  }
  Timer { interval: root.watchdogMs; running: pairPollProc.running; onTriggered: pairPollProc.running = false }

  Process {
    id: disconnectProc
    environment: root.syncEnv
    onExited: root.readSnapshot()
  }
  Timer { interval: root.watchdogMs; running: disconnectProc.running; onTriggered: disconnectProc.running = false }

  // Replacement/destruction (hot reload, plugin disable) must not orphan a
  // helper tree.
  Component.onDestruction: {
    readerProc.running = false
    refreshProc.running = false
    pairStartProc.running = false
    pairPollProc.running = false
    disconnectProc.running = false
  }

  // ---- timers ----

  // Clock driving all "now"-derived state. Second-resolution only while a
  // pairing code countdown is on screen.
  Timer {
    interval: root.authState === "pairing" ? 1000 : 60000
    running: root.authState === "signed_in" || root.authState === "pairing"
    repeat: true
    onTriggered: root.now = new Date()
  }

  // Background refresh: hourly normally, every 10 minutes on flight day.
  Timer {
    interval: root.flightDay ? 600000 : 3600000
    running: root.authState === "signed_in"
    repeat: true
    onTriggered: root.runRefresh()
  }

  // Pairing poll at the server-suggested interval while the code is valid.
  Timer {
    interval: Math.min(60, Math.max(1, Number(root.pairing && root.pairing.interval) || 5)) * 1000
    running: root.pairingLive
    repeat: true
    onTriggered: {
      if (pairPollProc.running) return
      pairPollProc.command = root.helperCommand(["pair-poll"])
      pairPollProc.running = true
    }
  }
}
