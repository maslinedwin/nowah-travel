import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "."
import "Model.js" as Model

Panel {
  id: root
  moduleName: "xyz.nowah.travel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property string appUrl: NowahService.appUrl && NowahService.appUrl.length > 0
    ? NowahService.appUrl
    : "https://app.nowah.xyz"
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color dim: Qt.alpha(fg, 0.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string iconFamily: Style.bar.iconFont || fontFamily
  readonly property int bodySize: Math.max(12, Math.round(Style.font.subtitle * 0.9))

  readonly property var placeholders: [
    "Weekend in Lisbon under $600",
    "Flights to Tokyo in March",
    "Hotels near Shibuya crossing",
    "eSIM for two weeks in Vietnam",
    "5-day Rome itinerary with kids"
  ]
  property int placeholderIndex: 0
  property var recents: []

  // `path` deep-links straight into the app window; `prefix` seeds the search
  // box instead, since flight/hotel search has no URL of its own — it runs
  // through the AI chat via /?q=.
  readonly property var quickLinks: [
    { icon: "\uf072", label: "Flights", prefix: "Flights to " },
    { icon: "\uf236", label: "Hotels", prefix: "Hotels in " },
    { icon: "\uf5a0", label: "Trips", path: "/trips" },
    { icon: "\uf279", label: "Plans", path: "/plan" },
    { icon: "\uf7c4", label: "eSIM", path: "/esim" },
    { icon: "\uf2c2", label: "Visa", path: "/visa" }
  ]

  function cfg(key, fallback) {
    var s = root.hostWidget ? root.hostWidget.settings : null
    return s && s[key] !== undefined ? s[key] : fallback
  }

  function syncRecents() {
    var s = root.hostWidget ? root.hostWidget.settings : null
    if (s && s.recentSearches && s.recentSearches.length !== undefined)
      root.recents = s.recentSearches
  }

  onHostWidgetChanged: syncRecents()

  Connections {
    target: root.hostWidget
    ignoreUnknownSignals: true
    function onSettingsChanged() { root.syncRecents() }
  }

  function open() {
    root.controller.show()
    NowahService.refreshNow()
    Qt.callLater(function() { queryInput.forceActiveFocus() })
  }

  function close() { root.controller.hide() }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function launch(path) {
    Quickshell.execDetached(["omarchy-launch-webapp", root.appUrl + path])
    queryInput.text = ""
    root.close()
  }

  function rememberSearch(q) {
    var next = [q]
    for (var i = 0; i < root.recents.length && next.length < 4; i++)
      if (root.recents[i] !== q) next.push(root.recents[i])
    root.recents = next
    if (root.hostWidget && typeof root.hostWidget.saveRecents === "function")
      root.hostWidget.saveRecents(next)
  }

  function clearRecents() {
    root.recents = []
    if (root.hostWidget && typeof root.hostWidget.saveRecents === "function")
      root.hostWidget.saveRecents([])
  }

  function searchFor(query) {
    var q = String(query || "").trim()
    if (q === "") return
    root.rememberSearch(q)
    root.launch("/?q=" + encodeURIComponent(q))
  }

  function submitQuery() { root.searchFor(queryInput.text) }

  function seedQuery(prefix) {
    queryInput.text = prefix
    queryInput.cursorPosition = queryInput.text.length
    queryInput.forceActiveFocus()
  }

  // Weather on the slim trip shape is best-effort; tolerate a few key names.
  function weatherTemp(trip) {
    if (!trip || !trip.weather) return ""
    var w = trip.weather
    var t = w.temp !== undefined ? w.temp
      : (w.temperature !== undefined ? w.temperature
      : (w.tempC !== undefined ? w.tempC : undefined))
    if (t === undefined || t === null || isNaN(Number(t))) return ""
    return Math.round(Number(t)) + "°"
  }

  function weatherCondition(trip) {
    if (!trip || !trip.weather) return ""
    return String(trip.weather.condition || trip.weather.summary || "")
  }

  function flightHeroLabel() {
    var c = NowahService.heroCard
    if (!c) return ""
    if (c.minutesToDep > 0) {
      var h = Math.floor(c.minutesToDep / 60)
      var m = c.minutesToDep % 60
      var when = h > 0 ? h + "h " + m + "m" : m + "m"
      var extra = c.statusLabel && c.statusLabel !== "Scheduled" ? "  ·  " + c.statusLabel : ""
      return "Departs in " + when + extra
    }
    if (c.progressPercent > 0 && c.progressPercent < 100)
      return c.statusLabel + "  ·  " + c.progressPercent + "%"
    return c.statusLabel
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        Row {
          spacing: Style.space(6)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf072"
            color: root.accent
            font.family: root.iconFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Nowah"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.5
            font.capitalization: Font.AllUppercase
          }
        }

        Text {
          text: "Where to?"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Math.round(Style.font.subtitle * 1.5)
          font.bold: true
        }

        Rectangle {
          id: inputBox
          width: parent.width
          height: Style.space(44)
          radius: Style.space(10)
          color: queryInput.activeFocus ? Qt.alpha(root.accent, 0.08) : Qt.alpha(root.fg, 0.05)
          border.width: 1
          border.color: queryInput.activeFocus ? root.accent : Qt.alpha(root.fg, 0.18)

          Behavior on color { ColorAnimation { duration: 140 } }
          Behavior on border.color { ColorAnimation { duration: 140 } }

          Text {
            id: searchGlyph
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf002"
            color: queryInput.activeFocus ? root.accent : root.dim
            font.family: root.iconFamily
            font.pixelSize: root.bodySize

            Behavior on color { ColorAnimation { duration: 140 } }
          }

          TextInput {
            id: queryInput
            anchors.left: searchGlyph.right
            anchors.leftMargin: Style.space(8)
            anchors.right: enterBadge.visible ? enterBadge.left : parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            color: root.fg
            selectionColor: Qt.alpha(root.accent, 0.35)
            font.family: root.fontFamily
            font.pixelSize: root.bodySize
            clip: true
            Keys.onReturnPressed: root.submitQuery()
            Keys.onEnterPressed: root.submitQuery()
            Keys.onEscapePressed: root.close()
            Keys.onRightPressed: function(event) {
              if (queryInput.text === "") root.seedQuery(placeholderText.text)
              else event.accepted = false
            }
            Keys.onDownPressed: function(event) {
              if (queryInput.text === "") placeholderSwap.restart()
              else event.accepted = false
            }

            Text {
              id: placeholderText
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              visible: queryInput.text === ""
              text: root.placeholders[root.placeholderIndex]
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: root.bodySize
              elide: Text.ElideRight
            }
          }

          Rectangle {
            id: enterBadge
            visible: queryInput.text.trim() !== ""
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: enterLabel.implicitWidth + Style.space(14)
            height: inputBox.height - Style.space(14)
            radius: height / 2
            color: enterMouse.containsMouse ? Qt.alpha(root.accent, 0.30) : Qt.alpha(root.accent, 0.16)

            Behavior on color { ColorAnimation { duration: 120 } }

            Text {
              id: enterLabel
              anchors.centerIn: parent
              text: "Search ↵"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              id: enterMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.submitQuery()
            }
          }

          Timer {
            interval: 3200
            running: root.opened && queryInput.text === "" && root.cfg("rotateExamples", true)
            repeat: true
            onTriggered: placeholderSwap.restart()
          }

          SequentialAnimation {
            id: placeholderSwap
            NumberAnimation { target: placeholderText; property: "opacity"; to: 0; duration: 220 }
            ScriptAction { script: root.placeholderIndex = (root.placeholderIndex + 1) % root.placeholders.length }
            NumberAnimation { target: placeholderText; property: "opacity"; to: 1; duration: 220 }
          }
        }

        // ------------------------------------------------------------------
        // Nowah account section — exactly one of the three states shows:
        // signed_out (connect CTA), pairing (device code), signed_in (trips).
        // ------------------------------------------------------------------

        // (1) signed out — jade connect CTA
        Rectangle {
          visible: NowahService.authState === "signed_out"
          width: parent.width
          height: connectCol.implicitHeight + Style.space(24)
          radius: Style.space(12)
          color: Qt.alpha(root.fg, 0.04)
          border.width: 1
          border.color: Qt.alpha(root.fg, 0.10)

          Column {
            id: connectCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: NowahService.authError === "revoked"
                ? "Session expired — reconnect."
                : "See your trips here — connect your Nowah account."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Rectangle {
              width: connectLabel.implicitWidth + Style.space(24)
              height: connectLabel.implicitHeight + Style.space(14)
              radius: height / 2
              color: connectMouse.containsMouse ? Model.BRAND.jadeHover : Model.BRAND.jade
              scale: connectMouse.pressed ? 0.96 : 1

              Behavior on color { ColorAnimation { duration: 120 } }
              Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }

              Text {
                id: connectLabel
                anchors.centerIn: parent
                text: "Connect Nowah"
                color: "#F4FBF7"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                id: connectMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: NowahService.startPairing()
              }
            }
          }
        }

        // (2) pairing — big user code + live expiry countdown
        Rectangle {
          id: pairingCard
          visible: NowahService.authState === "pairing"
          width: parent.width
          height: pairingCol.implicitHeight + Style.space(24)
          radius: Style.space(12)
          color: Qt.alpha(root.fg, 0.04)
          border.width: 1
          border.color: Qt.alpha(root.fg, 0.10)

          readonly property real msLeft: {
            var p = NowahService.pairing
            if (!p || !p.expiresAt) return 0
            var exp = Date.parse(p.expiresAt)
            return isNaN(exp) ? 0 : exp - NowahService.now.getTime()
          }
          readonly property bool expired: msLeft <= 0

          Column {
            id: pairingCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(6)

            Text {
              text: NowahService.pairing && NowahService.pairing.userCode
                ? NowahService.pairing.userCode
                : "· · · ·"
              color: Model.BRAND.jadeText
              font.family: root.fontFamily
              font.pixelSize: Math.round(Style.font.subtitle * 1.6)
              font.letterSpacing: 4
              font.bold: true
            }

            Text {
              width: parent.width
              text: "Approve in the Nowah window — check the code matches"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(12)

              Text {
                text: {
                  if (pairingCard.expired) return "code expired"
                  var s = Math.floor(pairingCard.msLeft / 1000)
                  return "expires in " + Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
                }
                color: pairingCard.expired ? "#FBBF24" : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: pairingCard.expired
                text: "get new code"
                color: newCodeMouse.containsMouse ? root.fg : Model.BRAND.jadeText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                Behavior on color { ColorAnimation { duration: 120 } }

                MouseArea {
                  id: newCodeMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: NowahService.startPairing()
                }
              }

              Text {
                text: "cancel"
                color: cancelMouse.containsMouse ? root.fg : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                Behavior on color { ColorAnimation { duration: 120 } }

                MouseArea {
                  id: cancelMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: NowahService.cancelPairing()
                }
              }
            }
          }
        }

        // (3) signed in — upcoming trips
        Column {
          id: tripsSection
          visible: NowahService.authState === "signed_in"
          width: parent.width
          spacing: Style.space(8)

          readonly property var heroTrip: (NowahService.monitor && NowahService.monitor.trip)
            ? NowahService.monitor.trip
            : (NowahService.upcoming.length > 0 ? NowahService.upcoming[0] : null)
          readonly property int heroDays: {
            var m = NowahService.monitor
            if (m && m.trip && m.daysUntil !== undefined) return m.daysUntil
            if (!heroTrip) return -1
            var st = Model.parseBookingDate(heroTrip.startDate)
            return st ? Model.calendarDaysUntil(st, NowahService.now) : -1
          }
          readonly property var moreTrips: {
            var out = []
            var up = NowahService.upcoming || []
            for (var i = 0; i < up.length && out.length < 3; i++)
              if (!heroTrip || up[i].id !== heroTrip.id) out.push(up[i])
            return out
          }
          readonly property bool flightHero: NowahService.flightDay && NowahService.heroCard !== null

          // header: UPCOMING TRIPS · stale marker · unread pill
          Item {
            width: parent.width
            height: Math.max(upcomingLabel.implicitHeight, unreadPill.height)

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                id: upcomingLabel
                text: "Upcoming trips"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.2
                font.capitalization: Font.AllUppercase
              }

              Text {
                visible: NowahService.stale
                anchors.verticalCenter: parent.verticalCenter
                text: "\uf071"
                color: Qt.alpha(root.fg, 0.30)
                font.family: root.iconFamily
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              id: unreadPill
              visible: NowahService.showNotifications && NowahService.unreadCount > 0
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: unreadRow.implicitWidth + Style.space(12)
              height: unreadRow.implicitHeight + Style.space(6)
              radius: height / 2
              color: unreadMouse.containsMouse
                ? Qt.alpha(Model.BRAND.jade, 0.28)
                : Qt.alpha(Model.BRAND.jade, 0.14)

              Behavior on color { ColorAnimation { duration: 120 } }

              Row {
                id: unreadRow
                anchors.centerIn: parent
                spacing: Style.space(4)

                Text {
                  text: "\uf0f3"
                  color: Model.BRAND.jadeText
                  font.family: root.iconFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  text: String(NowahService.unreadCount)
                  color: Model.BRAND.jadeText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              MouseArea {
                id: unreadMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.launch("/notifications")
              }
            }
          }

          // hero card — trip countdown or flight-day variant
          Rectangle {
            visible: tripsSection.heroTrip !== null
            width: parent.width
            height: (tripsSection.flightHero ? flightHeroCol.implicitHeight : tripHeroCol.implicitHeight) + Style.space(20)
            radius: Style.space(12)
            color: heroMouse.containsMouse ? Qt.alpha(root.accent, 0.10) : Qt.alpha(root.fg, 0.04)
            border.width: 1
            border.color: heroMouse.containsMouse ? Qt.alpha(root.accent, 0.85) : Qt.alpha(root.fg, 0.10)

            Behavior on color { ColorAnimation { duration: 120 } }
            Behavior on border.color { ColorAnimation { duration: 120 } }

            Rectangle {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: 3
              height: parent.height - Style.space(16)
              radius: 1.5
              color: Model.BRAND.jade
            }

            Column {
              id: tripHeroCol
              visible: !tripsSection.flightHero
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(16)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(4)

              Item {
                width: parent.width
                height: heroCity.implicitHeight

                Text {
                  id: heroCity
                  anchors.left: parent.left
                  anchors.right: heroWeather.visible ? heroWeather.left : parent.right
                  anchors.rightMargin: Style.space(8)
                  text: tripsSection.heroTrip
                    ? (tripsSection.heroTrip.destinationCity || tripsSection.heroTrip.destination || "")
                    : ""
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Math.round(Style.font.subtitle * 1.15)
                  font.bold: true
                  elide: Text.ElideRight
                }

                Row {
                  id: heroWeather
                  visible: root.weatherCondition(tripsSection.heroTrip) !== ""
                    || root.weatherTemp(tripsSection.heroTrip) !== ""
                  anchors.right: parent.right
                  anchors.verticalCenter: heroCity.verticalCenter
                  spacing: Style.space(4)

                  Text {
                    text: Model.weatherGlyph(root.weatherCondition(tripsSection.heroTrip))
                    color: root.dim
                    font.family: root.iconFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    visible: text !== ""
                    text: root.weatherTemp(tripsSection.heroTrip)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Text {
                visible: text !== ""
                text: tripsSection.heroTrip ? (tripsSection.heroTrip.destinationCountry || "") : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Row {
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: Model.tripDateRange(tripsSection.heroTrip)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Rectangle {
                  visible: heroChip.text !== ""
                  anchors.verticalCenter: parent.verticalCenter
                  width: heroChip.implicitWidth + Style.space(14)
                  height: heroChip.implicitHeight + Style.space(6)
                  radius: height / 2
                  color: Qt.alpha(Model.BRAND.jade, 0.16)

                  Text {
                    id: heroChip
                    anchors.centerIn: parent
                    text: NowahService.monitor && NowahService.monitor.state === "in_destination"
                      ? "Now"
                      : Model.countdownLabel(tripsSection.heroDays)
                    color: Model.BRAND.jadeText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }
            }

            Column {
              id: flightHeroCol
              visible: tripsSection.flightHero
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(16)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(6)

              Row {
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: NowahService.heroCard ? NowahService.heroCard.flightNumber : ""
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Row {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Text {
                    text: NowahService.heroCard ? NowahService.heroCard.depCode : ""
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "\uf178"
                    color: root.dim
                    font.family: root.iconFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    text: NowahService.heroCard ? NowahService.heroCard.arrCode : ""
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                  }
                }
              }

              Row {
                spacing: Style.space(6)

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: 8
                  height: 8
                  radius: 4
                  color: NowahService.heroCard ? NowahService.heroCard.statusColor : Model.BRAND.jade
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.flightHeroLabel()
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            MouseArea {
              id: heroMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (tripsSection.heroTrip) root.launch("/trips/" + tripsSection.heroTrip.id)
              }
            }
          }

          // compact rows for the next few trips
          Repeater {
            model: tripsSection.moreTrips

            Rectangle {
              id: tripRow
              required property var modelData
              readonly property int rowDays: {
                var st = Model.parseBookingDate(modelData.startDate)
                return st ? Model.calendarDaysUntil(st, NowahService.now) : -1
              }
              width: tripsSection.width
              height: rowCity.implicitHeight + Style.space(12)
              radius: Style.space(8)
              color: rowMouse.containsMouse ? Qt.alpha(root.accent, 0.08) : "transparent"

              Behavior on color { ColorAnimation { duration: 120 } }

              Text {
                id: rowCity
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.right: rowChip.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: (tripRow.modelData.destinationCity || tripRow.modelData.destination || "")
                  + "  ·  " + Model.tripDateRange(tripRow.modelData)
                color: rowMouse.containsMouse ? root.fg : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight

                Behavior on color { ColorAnimation { duration: 120 } }
              }

              Text {
                id: rowChip
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: Model.countdownLabel(tripRow.rowDays)
                color: Model.BRAND.jadeText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.launch("/trips/" + tripRow.modelData.id)
              }
            }
          }

          // all trips link
          Text {
            visible: tripsSection.heroTrip !== null
            text: "All trips →"
            color: allTripsMouse.containsMouse ? root.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption

            Behavior on color { ColorAnimation { duration: 120 } }

            MouseArea {
              id: allTripsMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.launch("/trips")
            }
          }

          // empty state
          Row {
            visible: tripsSection.heroTrip === null
            spacing: Style.space(8)

            Text {
              text: "No upcoming trips"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              text: "Plan one →"
              color: planOneMouse.containsMouse ? root.fg : Model.BRAND.jadeText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              Behavior on color { ColorAnimation { duration: 120 } }

              MouseArea {
                id: planOneMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.launch("/plan")
              }
            }
          }

          // footer: account + disconnect
          Row {
            width: parent.width
            spacing: 0

            Text {
              id: connectedAs
              width: Math.min(implicitWidth, tripsSection.width - footerSep.implicitWidth - disconnectLink.implicitWidth)
              text: NowahService.profile && NowahService.profile.email
                ? "Connected as " + NowahService.profile.email
                : "Connected"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              id: footerSep
              text: "  ·  "
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              id: disconnectLink
              text: "disconnect"
              color: disconnectMouse.containsMouse ? root.fg : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              Behavior on color { ColorAnimation { duration: 120 } }

              MouseArea {
                id: disconnectMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: NowahService.disconnect()
              }
            }
          }
        }

        Grid {
          id: grid
          width: parent.width
          columns: 3
          columnSpacing: Style.space(8)
          rowSpacing: Style.space(8)

          readonly property real cellW: (width - columnSpacing * (columns - 1)) / columns

          Repeater {
            model: root.quickLinks

            Rectangle {
              id: tile
              required property var modelData
              width: grid.cellW
              height: Style.space(56)
              radius: Style.space(10)
              color: tileMouse.containsMouse ? Qt.alpha(root.accent, 0.10) : Qt.alpha(root.fg, 0.04)
              border.width: 1
              border.color: tileMouse.containsMouse ? Qt.alpha(root.accent, 0.85) : Qt.alpha(root.fg, 0.10)
              scale: tileMouse.pressed ? 0.96 : 1

              Behavior on color { ColorAnimation { duration: 120 } }
              Behavior on border.color { ColorAnimation { duration: 120 } }
              Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }

              Column {
                anchors.centerIn: parent
                spacing: Style.space(4)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: tile.modelData.icon
                  color: tileMouse.containsMouse ? root.accent : root.fg
                  font.family: root.iconFamily
                  font.pixelSize: Math.round(root.bodySize * 1.25)

                  Behavior on color { ColorAnimation { duration: 120 } }
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: tile.modelData.label
                  color: tileMouse.containsMouse ? root.fg : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption

                  Behavior on color { ColorAnimation { duration: 120 } }
                }
              }

              MouseArea {
                id: tileMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (tile.modelData.path) root.launch(tile.modelData.path)
                  else root.seedQuery(tile.modelData.prefix)
                }
              }
            }
          }
        }

        Column {
          visible: root.cfg("showRecent", true) && root.recents.length > 0
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            height: recentLabel.implicitHeight

            Text {
              id: recentLabel
              anchors.left: parent.left
              text: "Recent"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
              font.capitalization: Font.AllUppercase
            }

            Text {
              anchors.right: parent.right
              text: "clear"
              color: clearMouse.containsMouse ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              Behavior on color { ColorAnimation { duration: 120 } }

              MouseArea {
                id: clearMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.clearRecents()
              }
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.recents

              Rectangle {
                id: recentPill
                required property string modelData
                width: Math.min(recentText.implicitWidth + Style.space(16), grid.width)
                height: recentText.implicitHeight + Style.space(10)
                radius: height / 2
                color: recentMouse.containsMouse ? Qt.alpha(root.accent, 0.10) : "transparent"
                border.width: 1
                border.color: recentMouse.containsMouse ? Qt.alpha(root.accent, 0.85) : Qt.alpha(root.fg, 0.14)

                Behavior on color { ColorAnimation { duration: 120 } }
                Behavior on border.color { ColorAnimation { duration: 120 } }

                Text {
                  id: recentText
                  anchors.centerIn: parent
                  width: Math.min(implicitWidth, recentPill.width - Style.space(14))
                  text: recentPill.modelData
                  color: recentMouse.containsMouse ? root.fg : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight

                  Behavior on color { ColorAnimation { duration: 120 } }
                }

                MouseArea {
                  id: recentMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.searchFor(recentPill.modelData)
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          text: "→ use suggestion  ·  ↵ search  ·  esc close"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
