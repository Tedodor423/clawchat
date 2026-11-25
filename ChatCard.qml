import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The chat card: recent messages, the agent's reply as it streams in, and the
// input box that Voxtype dictation lands in. No window types here.
// Keys: Enter send · Shift+Enter new line · Esc close.
BorderSurface {
  id: root

  property var service: null
  property real availableWidth: 1280
  property real availableHeight: 800

  readonly property var svc: root.service
  readonly property var messages: svc ? svc.messages : []
  readonly property string voice: svc ? svc.voice : "idle"
  readonly property bool running: !!(svc && svc.running)
  readonly property string streamText: svc ? svc.streamText : ""
  readonly property string agentName: svc && svc.agentName ? svc.agentName : "OpenClaw"
  readonly property string key: svc && svc.keyLabel ? svc.keyLabel : "F8"

  readonly property color fg: Commons.Color.menu.text
  readonly property color bg: Commons.Color.menu.background
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property color muted: Util.alpha(fg, 0.6)
  readonly property color faint: Util.alpha(fg, 0.38)
  readonly property string fontFamily: Style.font.family
  readonly property int pad: Math.round(Style.spacing.panelPadding * 1.4)
  readonly property int gap: Style.spacing.panelGap
  readonly property real innerWidth: width - contentLeftInset - contentRightInset
  readonly property real maxListHeight: Math.max(Style.space(120),
    availableHeight * 0.74 - header.height - input.height - footer.height - gap * 3 - pad * 2)

  width: Math.min(Style.space(780), Math.max(Style.space(420), availableWidth - Style.space(96)))
  height: column.implicitHeight + topPadding + bottomPadding + borderTop + borderBottom
  radius: Style.cornerRadius
  color: root.bg
  borderSpec: Border.surfaceSpec("menu", "border", Commons.Color.menu.border, Math.max(1, Style.space(2)))
  padding: root.pad

  // Swallow clicks so they don't reach the "click outside closes" area.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    onClicked: input.forceActiveFocus()
  }

  function focusInput() { input.forceActiveFocus() }

  // Qt draws Markdown links in the application palette's blue whatever
  // linkColor says, so colour the link text itself.
  function md(text) {
    var c = String(root.accent)
    return String(text).replace(/\[([^\]\n]+)\]\((https?:[^)\s]+)\)/g, function(m, label, url) {
      return "[<font color=\"" + c + "\">" + label + "</font>](" + url + ")"
    })
  }

  function timeLabel(ts) {
    if (!ts) return ""
    var d = new Date(ts)
    var now = new Date()
    var hm = Qt.formatTime(d, "HH:mm")
    return d.toDateString() === now.toDateString() ? hm : Qt.formatDate(d, "d MMM") + " " + hm
  }

  Connections {
    target: root.svc
    ignoreUnknownSignals: true
    function onDraftAppend(text) {
      var cur = input.text
      input.text = cur + (cur && !/\s$/.test(cur) ? " " : "") + text
      input.cursorPosition = input.length
    }
    function onDraftSet(text) {
      input.text = text
      input.cursorPosition = input.length
    }
  }

  Column {
    id: column
    x: root.contentLeftInset
    y: root.contentTopInset
    width: root.innerWidth
    spacing: root.gap

    // ---------------------------------------------------------------- header
    Item {
      id: header
      width: parent.width
      height: Math.max(title.implicitHeight, state.implicitHeight)

      Text {
        id: title
        anchors.verticalCenter: parent.verticalCenter
        text: root.agentName
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
      }

      Row {
        id: state
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.sm

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: !root.svc ? "" : root.svc.connected ? (root.running ? "working" : "online")
            : (root.svc.connError ? "offline" : "connecting…")
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(8); height: width; radius: width / 2
          color: root.svc && root.svc.connected ? root.accent : (root.svc && root.svc.connError ? root.urgent : root.faint)
          SequentialAnimation on opacity {
            running: root.running
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { to: 0.25; duration: 600 }
            NumberAnimation { to: 1; duration: 600 }
          }
        }
      }
    }

    // --------------------------------------------------------------- messages
    Flickable {
      id: flick
      width: parent.width
      height: Math.min(list.implicitHeight, root.maxListHeight)
      contentWidth: width
      contentHeight: list.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      visible: list.implicitHeight > 0

      // Stay on the newest message unless the user scrolled up.
      property bool stick: true
      function toEnd() { contentY = Math.max(0, contentHeight - height) }
      onContentHeightChanged: if (stick) toEnd()
      onHeightChanged: if (stick) toEnd()
      onMovementEnded: stick = contentY >= contentHeight - height - Style.space(24)

      QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

      Column {
        id: list
        width: flick.width
        spacing: Style.spacing.sm

        Repeater {
          model: root.messages

          Item {
            id: row
            required property var modelData
            readonly property bool mine: modelData.role === "user"
            width: list.width
            height: bubble.height + stamp.height

            Rectangle {
              id: bubble
              anchors.right: row.mine ? parent.right : undefined
              anchors.left: row.mine ? undefined : parent.left
              width: Math.min(body.implicitWidth, list.width * 0.86 - Style.spacing.lg * 2) + Style.spacing.lg * 2
              height: body.height + Style.spacing.sm * 2
              radius: Style.cornerRadius
              color: row.mine ? Util.alpha(root.accent, 0.22) : Util.alpha(root.fg, 0.07)
              opacity: row.modelData.local ? 0.7 : 1

              Text {
                id: body
                x: Style.spacing.lg
                y: Style.spacing.sm
                width: Math.min(implicitWidth, list.width * 0.86 - Style.spacing.lg * 2)
                text: row.mine ? row.modelData.text : root.md(row.modelData.text)
                textFormat: row.mine ? Text.PlainText : Text.MarkdownText
                wrapMode: Text.Wrap
                color: root.fg
                linkColor: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                onLinkActivated: function(link) { Qt.openUrlExternally(link) }
              }
            }

            Text {
              id: stamp
              anchors.top: bubble.bottom
              anchors.right: row.mine ? parent.right : undefined
              anchors.left: row.mine ? undefined : parent.left
              anchors.leftMargin: Style.spacing.sm
              anchors.rightMargin: Style.spacing.sm
              text: row.modelData.local ? "sending…" : root.timeLabel(row.modelData.ts)
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // The reply in flight.
        Rectangle {
          visible: root.running
          width: Math.min(live.implicitWidth, list.width * 0.86 - Style.spacing.lg * 2) + Style.spacing.lg * 2
          height: live.height + Style.spacing.sm * 2
          radius: Style.cornerRadius
          color: Util.alpha(root.fg, 0.07)

          Text {
            id: live
            x: Style.spacing.lg
            y: Style.spacing.sm
            width: Math.min(implicitWidth, list.width * 0.86 - Style.spacing.lg * 2)
            text: root.streamText ? root.md(root.streamText) : "● ● ●"
            textFormat: root.streamText ? Text.MarkdownText : Text.PlainText
            wrapMode: Text.Wrap
            color: root.fg
            linkColor: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            opacity: root.streamText ? 1 : thinking.level
          }

          QtObject {
            id: thinking
            property real level: 0.55
            property SequentialAnimation pulse: SequentialAnimation {
              running: root.running && !root.streamText
              loops: Animation.Infinite
              NumberAnimation { target: thinking; property: "level"; to: 0.2; duration: 500 }
              NumberAnimation { target: thinking; property: "level"; to: 0.55; duration: 500 }
            }
          }
        }
      }
    }

    // --------------------------------------------------------------- composer
    QQC.TextArea {
      id: input
      width: parent.width

      readonly property var _borderSpec: Border.controlSpec(activeFocus ? "focus" : (hovered ? "hover-cursor" : "normal"),
        root.fg, root.voice === "recording" ? root.urgent : root.accent)

      focus: true
      wrapMode: TextEdit.Wrap
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      color: root.fg
      selectionColor: Style.selectionFillFor(root.fg, root.accent)
      selectedTextColor: root.fg
      placeholderText: root.voice === "recording" ? "Listening…"
        : root.voice === "transcribing" ? "Transcribing…" : "Hold " + root.key + " and speak, or type"
      placeholderTextColor: root.voice === "recording" ? root.urgent : root.faint
      selectByMouse: true

      leftPadding: Style.spacing.controlPaddingX + Border.left(_borderSpec)
      rightPadding: Style.spacing.controlPaddingX + Border.right(_borderSpec)
      topPadding: Style.spacing.inputPaddingY + Border.top(_borderSpec)
      bottomPadding: Style.spacing.inputPaddingY + Border.bottom(_borderSpec)
      implicitHeight: Math.min(Math.max(contentHeight, metrics.height * 2), metrics.height * 8) + topPadding + bottomPadding

      FontMetrics { id: metrics; font: input.font }

      Component.onCompleted: {
        // A draft survives closing the window.
        if (root.svc && root.svc.draft) { text = root.svc.draft; cursorPosition = length }
      }
      onTextChanged: if (root.svc && root.svc.draft !== text) root.svc.draft = text

      Keys.onPressed: function(event) {
        var enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
        if (enter && !(event.modifiers & Qt.ShiftModifier)) {
          if (root.svc) root.svc.send()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          if (root.svc) root.svc.close()
          event.accepted = true
        } else if (event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
          var step = flick.height * 0.8 * (event.key === Qt.Key_PageUp ? -1 : 1)
          flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + step))
          flick.stick = flick.contentY >= flick.contentHeight - flick.height - Style.space(24)
          event.accepted = true
        }
      }

      background: BorderSurface {
        color: Style.controlFill(input.activeFocus, input.hovered, root.fg, root.accent)
        borderSpec: input._borderSpec
        radius: Style.cornerRadius
      }
    }

    // ----------------------------------------------------------------- footer
    Item {
      id: footer
      width: parent.width
      height: hint.implicitHeight

      Row {
        id: voiceRow
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.sm
        visible: root.voice !== "idle"

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(10); height: width; radius: width / 2
          color: root.voice === "recording" ? root.urgent : root.accent
          SequentialAnimation on opacity {
            running: voiceRow.visible
            loops: Animation.Infinite
            NumberAnimation { to: 0.25; duration: 450; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1; duration: 450; easing.type: Easing.InOutQuad }
          }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.voice === "recording" ? "Listening: release " + root.key + " when you're done" : "Transcribing…"
          color: root.voice === "recording" ? root.urgent : root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        id: hint
        width: parent.width
        visible: root.voice === "idle"
        elide: Text.ElideRight
        readonly property string problem: !root.svc ? "" : root.svc.notice ? root.svc.notice
          : (!root.svc.connected && root.svc.connError ? "Can't reach " + root.agentName + ": " + root.svc.connError : "")
        text: problem || root.key + " hold: speak  ·  " + root.key + " tap: " + (input.text.trim() ? "send" : "close") + "  ·  Enter: send  ·  Esc: close"
        color: problem ? root.urgent : root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
