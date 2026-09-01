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

  // `path` deep-links straight into the app window; `prefix` seeds the search
  // box instead, since flight/hotel search has no URL of its own — it runs
  // through the AI chat via /?q=.
  readonly property var quickLinks: [
    { icon: "\uf072", label: "Flights", prefix: "Flights to " },
    { icon: "\uf236", label: "Hotels", prefix: "Hotels in " },
    { icon: "\uf5a0", label: "Trips", path: "/trips" },
    { icon: "\uf279", label: "Plans", path: "/plan" },
    { icon: "\uf7c0", label: "eSIM", path: "/esim" },
    { icon: "\uf2c2", label: "Visa", path: "/visa" }
  ]

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

  function submitQuery() {
    var q = queryInput.text.trim()
    if (q === "") return
    root.launch("/?q=" + encodeURIComponent(q))
  }

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
            running: root.opened && queryInput.text === ""
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

        Text {
          width: parent.width
          text: "↵ search in the Nowah app  ·  esc close"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
