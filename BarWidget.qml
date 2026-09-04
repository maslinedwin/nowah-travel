import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "."
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "xyz.nowah.travel"

  // Shape contract for shell summon/hide/toggle routing: Bar.findPanelWidget
  // requires opened/open/close on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  // Applied locally first so the panel updates on the action itself; the
  // shell.json write comes back through the bar as the same value.
  // Only known settings keys are carried into the shell.json entry, and the
  // recents list is re-bounded (count, length, charset) before persisting —
  // an aggregate cap on what this plugin can ever write there.
  // Values are coerced to their declared types (never copied raw), so a
  // poisoned entry can never be re-persisted by this plugin.
  function boundedSettings() {
    var s = root.settings || {}
    var out = {}
    if (s.showRecent !== undefined) out.showRecent = s.showRecent === true
    if (s.rotateExamples !== undefined) out.rotateExamples = s.rotateExamples === true
    if (s.showNotifications !== undefined) out.showNotifications = s.showNotifications === true
    if (s.countdownDays !== undefined) {
      var days = Number(s.countdownDays)
      out.countdownDays = isNaN(days) ? 14 : Math.max(1, Math.min(60, Math.round(days)))
    }
    return out
  }

  function saveRecents(list) {
    var entry = root.boundedSettings()
    entry.id = root.moduleName
    entry.recentSearches = Model.sanitizeRecents(list)
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: {
    injectPanel()
    NowahService.configure(root.settings)
  }

  Component.onCompleted: NowahService.configure(root.settings)

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "xyz.nowah.travel"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function search(query: string): void {
      // IPC is an untrusted producer: reject anything that is not a
      // reasonably sized string before it reaches the panel.
      if (typeof query !== "string" || query.length === 0 || query.length > 2000) return
      if (panelLoader.item && panelLoader.item.searchFor) panelLoader.item.searchFor(query)
    }
    function refresh(): void { NowahService.refreshNow() }
    function connect(): void { NowahService.startPairing() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: {
      var base = "\uf072"
      var m = NowahService.monitor
      if (m && (m.state === "countdown" || m.state === "prep")
          && m.daysUntil !== undefined && m.daysUntil >= 0
          && m.daysUntil <= NowahService.countdownDays)
        return base + " " + Model.countdownShort(m.daysUntil)
      return base
    }
    active: root.opened
    tooltipText: {
      var base = "Nowah — flights, hotels, eSIM, trip plans"
      var m = NowahService.monitor
      var trip = m && m.trip ? m.trip
        : (NowahService.upcoming.length > 0 ? NowahService.upcoming[0] : null)
      if (!trip) return base
      var place = trip.destinationCity || trip.destination || trip.name || "trip"
      if (m && m.state === "active_flight") return base + "\nIn flight · " + place
      if (m && m.state === "in_destination") return base + "\nIn " + place
      var days = -1
      if (m && m.trip && m.daysUntil !== undefined) days = m.daysUntil
      else {
        var st = Model.parseBookingDate(trip.startDate)
        if (st) days = Model.calendarDaysUntil(st, NowahService.now)
      }
      if (days < 0) return base
      return base + "\nNext: " + place + " " + Model.countdownLabel(days).toLowerCase()
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton)
        NowahService.launch("/")
      else
        root.toggle()
    }

    // Flight-day status dot (bottom right) — mirrors the hero card color.
    Rectangle {
      visible: NowahService.flightDay && NowahService.heroCard !== null
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: 2
      width: 6
      height: 6
      radius: 3
      color: NowahService.heroCard ? NowahService.heroCard.statusColor : Model.BRAND.jade
    }

    // Quiet unread-notifications dot (top right) — yields to the flight dot.
    Rectangle {
      visible: NowahService.showNotifications && NowahService.unreadCount > 0 && !NowahService.flightDay
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: 2
      width: 4
      height: 4
      radius: 2
      color: Model.BRAND.jadeText
    }
  }
}
