import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "xyz.nowah.travel"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property string appUrl: "https://app.nowah.xyz"
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

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
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
