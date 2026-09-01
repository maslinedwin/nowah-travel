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
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Quick actions: `path` deep-links straight into the app window; `prefix`
  // seeds the search box instead, since flight/hotel search has no URL of its
  // own — it runs through the AI chat via /?q=.
  readonly property var quickLinks: [
    { label: "Flights", prefix: "Flights to " },
    { label: "Hotels", prefix: "Hotels in " },
    { label: "Trips", path: "/trips" },
    { label: "Plans", path: "/plan" },
    { label: "eSIM", path: "/esim" },
    { label: "Visa", path: "/visa" }
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
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Text {
          text: "Where to?"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Rectangle {
          width: parent.width
          height: queryInput.implicitHeight + Style.space(12)
          radius: Style.space(6)
          color: "transparent"
          border.width: 1
          border.color: queryInput.activeFocus ? Color.accent : root.dim

          TextInput {
            id: queryInput
            anchors.fill: parent
            anchors.margins: Style.space(6)
            verticalAlignment: TextInput.AlignVCenter
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            clip: true
            Keys.onReturnPressed: root.submitQuery()
            Keys.onEnterPressed: root.submitQuery()
            Keys.onEscapePressed: root.close()
          }

          Text {
            anchors.fill: queryInput
            verticalAlignment: Text.AlignVCenter
            visible: queryInput.text === "" && !queryInput.activeFocus
            text: "Tokyo in March, hotels near Shibuya…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.quickLinks

            Rectangle {
              required property var modelData
              width: chipLabel.implicitWidth + Style.space(16)
              height: chipLabel.implicitHeight + Style.space(10)
              radius: height / 2
              color: chipMouse.containsMouse ? Qt.alpha(Color.accent, 0.18) : "transparent"
              border.width: 1
              border.color: chipMouse.containsMouse ? Color.accent : root.dim

              Text {
                id: chipLabel
                anchors.centerIn: parent
                text: parent.modelData.label
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: chipMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (parent.modelData.path) root.launch(parent.modelData.path)
                  else root.seedQuery(parent.modelData.prefix)
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          text: "Enter to search — opens in the Nowah app window"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
