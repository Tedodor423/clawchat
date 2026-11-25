import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons

// Overlay entry point: the chat card in the middle of the focused
// monitor, over a light dim. It holds the keyboard while open; a click outside
// the card closes it. Open state lives in the service (Service.qml), and
// open()/close() below only forward to it.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  readonly property string pluginId: (manifest && manifest.id) ? manifest.id : "theo.clawchat"
  readonly property var svc: service || (shell && typeof shell.serviceFor === "function" ? shell.serviceFor(pluginId) : null)
  readonly property bool opened: !!(svc && svc.overlayOpen)

  property string activeScreen: ""
  readonly property string cardScreen: {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i].name === root.activeScreen) return root.activeScreen
    return screens.length ? screens[0].name : ""
  }

  function pickScreen() {
    var m = Hyprland.focusedMonitor
    root.activeScreen = m ? m.name : (Quickshell.screens.length ? Quickshell.screens[0].name : "")
  }

  // ------------------------------------------------------- plugin contract
  function open(payloadJson) {
    pickScreen()
    if (root.svc && !root.svc.overlayOpen) root.svc.open()
  }

  function close() {
    if (root.svc && root.svc.overlayOpen) root.svc.close()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  onOpenedChanged: if (opened) pickScreen(); else activeScreen = ""

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      readonly property bool isActive: modelData.name === root.cardScreen
      screen: modelData
      visible: root.opened && win.isActive
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "theo-clawchat"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: win.isActive ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

      Rectangle {
        anchors.fill: parent
        color: Util.alpha(Commons.Color.background, 0.45)
        opacity: cardLoader.item ? cardLoader.item.opacity : 0
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: root.close()
      }

      Loader {
        id: cardLoader
        active: win.isActive && root.opened
        anchors.centerIn: parent
        sourceComponent: ChatCard {
          service: root.svc
          availableWidth: win.width
          availableHeight: win.height
          opacity: 0
          scale: 0.97
          Component.onCompleted: { opacity = 1; scale = 1 }
          Behavior on opacity { NumberAnimation { duration: 110 } }
          Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
        }
        onLoaded: item.focusInput()
      }
    }
  }
}
