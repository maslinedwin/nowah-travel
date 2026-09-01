pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// NowahService — singleton bridge between bin/nowah-sync (which owns all
// network and secret handling) and the QML surfaces. It watches the atomic
// status.json snapshot, derives trip state through Model.js, and schedules
// refresh / pairing-poll runs. No token ever passes through QML.
Item {
  id: root

  // ---- configuration (injected late via configure(settings); idempotent) ----

  property string apiUrl: "https://api.nowah.xyz"
  property string appUrl: "https://app.nowah.xyz"
  property bool showNotifications: true
  property int countdownDays: 14

  function configure(settings) {
    if (!settings) return
    if (settings.apiUrl !== undefined && String(settings.apiUrl) !== "")
      root.apiUrl = String(settings.apiUrl)
    if (settings.appUrl !== undefined && String(settings.appUrl) !== "")
      root.appUrl = String(settings.appUrl)
    if (settings.showNotifications !== undefined)
      root.showNotifications = settings.showNotifications === true
    if (settings.countdownDays !== undefined) {
      var days = Number(settings.countdownDays)
      if (!isNaN(days)) root.countdownDays = Math.max(1, Math.min(60, Math.round(days)))
    }
  }

  // ---- status snapshot (written by bin/nowah-sync, watched here) ----

  readonly property string stateDir: {
    var override = Quickshell.env("NOWAH_STATE_DIR")
    if (override && override.length > 0) return override
    var xdg = Quickshell.env("XDG_STATE_HOME")
    if (!xdg || xdg.length === 0) xdg = Quickshell.env("HOME") + "/.local/state"
    return xdg + "/nowah-omarchy"
  }

  property var status: null
  property date now: new Date()

  readonly property string authState: (status && status.auth && status.auth.state) ? status.auth.state : "signed_out"
  readonly property string authError: (status && status.auth && status.auth.error) ? String(status.auth.error) : ""
  readonly property var pairing: (status && status.auth) ? (status.auth.pairing || null) : null
  readonly property var profile: (status && status.auth) ? (status.auth.profile || null) : null
  readonly property var trips: (status && status.trips) ? status.trips : []
  readonly property int unreadCount: (status && status.unreadCount !== undefined && status.unreadCount !== null) ? status.unreadCount : 0
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

  function reparseStatus() {
    try {
      root.status = JSON.parse(statusFile.text())
      root.now = new Date()
    } catch (e) {
      // partially-written or missing file — keep the previous snapshot
    }
  }

  FileView {
    id: statusFile
    path: root.stateDir + "/status.json"
    watchChanges: true
    onFileChanged: statusFile.reload()
    onLoaded: root.reparseStatus()
  }

  // ---- helper process plumbing ----

  readonly property string syncBin: {
    var url = Qt.resolvedUrl("bin/nowah-sync").toString()
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  readonly property var syncEnv: ({
    NOWAH_API_URL: root.apiUrl,
    NOWAH_SHOW_NOTIFICATIONS: root.showNotifications ? "1" : "0"
  })

  property double lastRefreshMs: 0

  function currentFlightArgs() {
    var m = root.monitor
    if (!root.flightDay || !m || !m.seg || !m.seg.flight || !m.seg.flight.flightNumber) return []
    return ["--flight", m.seg.flight.flightNumber, "--date", Model.localISODate(m.seg.dep)]
  }

  function runRefresh() {
    if (refreshProc.running) return
    root.lastRefreshMs = Date.now()
    refreshProc.command = [root.syncBin, "refresh"].concat(root.currentFlightArgs())
    refreshProc.running = true
  }

  /** Refresh with a 60s minimum interval so panel opens can't hammer the API. */
  function refreshNow() {
    if (Date.now() - root.lastRefreshMs < 60000) return
    root.runRefresh()
  }

  function startPairing() {
    if (pairStartProc.running) return
    pairStartProc.command = [root.syncBin, "pair-start"]
    pairStartProc.running = true
  }

  function runDisconnect() {
    if (disconnectProc.running) return
    disconnectProc.command = [root.syncBin, "disconnect"]
    disconnectProc.running = true
  }

  function cancelPairing() { root.runDisconnect() }
  function disconnect() { root.runDisconnect() }

  // First sight of a signed-in snapshot (e.g. shell start with a stored
  // token) gets fresh data instead of waiting out the refresh timer.
  onAuthStateChanged: if (authState === "signed_in") refreshNow()

  Process {
    id: refreshProc
    environment: root.syncEnv
    onExited: statusFile.reload()
  }

  Process {
    id: pairStartProc
    environment: root.syncEnv
    onExited: statusFile.reload()
    stdout: StdioCollector {
      onStreamFinished: {
        // pair-start prints verificationUriComplete on success only.
        var url = String(text || "").trim()
        if (url.indexOf("http") === 0)
          Quickshell.execDetached(["omarchy-launch-webapp", url])
      }
    }
  }

  Process {
    id: pairPollProc
    environment: root.syncEnv
    // exit 10 = authorization pending; pairTimer simply polls again.
    onExited: statusFile.reload()
  }

  Process {
    id: disconnectProc
    environment: root.syncEnv
    onExited: statusFile.reload()
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
    interval: (root.pairing && root.pairing.interval ? root.pairing.interval : 5) * 1000
    running: root.pairingLive
    repeat: true
    onTriggered: {
      if (pairPollProc.running) return
      pairPollProc.command = [root.syncBin, "pair-poll"]
      pairPollProc.running = true
    }
  }
}
