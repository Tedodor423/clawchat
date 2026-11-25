import QtQuick
import Quickshell
import Quickshell.Io

// Headless half of theo.clawchat: the gateway bridge process, the chat state,
// voice capture through Voxtype and the F8 key logic. Overlay.qml only draws.
//
// The key (F8 by default; bindings.lua calls `omarchy-shell theo.clawchat press` / `release`):
//   hidden:  press opens the window and starts recording straight away;
//            releasing within tapMs throws that recording away (window stays).
//   open:    a tap sends the draft, or closes the window when the draft is
//            empty; holding records more and appends it to the draft.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "theo.clawchat"
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string bridgePath: _local("bridge/clawchat-bridge.mjs")
  readonly property string voicePath: _local("bridge/voice")
  readonly property int tapMs: 280

  function _local(rel) {
    return decodeURIComponent(String(Qt.resolvedUrl(rel)).replace(/^file:\/\//, ""))
  }

  // ------------------------------------------------------------ public state
  property bool overlayOpen: false
  property bool connected: false
  property string connError: ""
  property var history: []          // [{id, role, text, ts}] from the gateway
  property var pending: []          // sent, not yet in the history: [{id, role, text, ts, failed}]
  readonly property var messages: history.concat(pending)
  property bool running: false      // the agent is working on a turn
  property string streamText: ""    // his reply so far
  property string voice: "idle"     // idle | recording | transcribing
  property string draft: ""         // mirror of the overlay's input box
  property string notice: ""
  property string agentName: "OpenClaw"   // from config.json, via the bridge
  property string keyLabel: "F8"

  signal draftAppend(string text)
  signal draftSet(string text)

  // ------------------------------------------------------------------ bridge
  Process {
    id: bridge
    command: [root._local("bridge/run"), root.bridgePath]
    running: true
    stdinEnabled: true
    stdout: SplitParser { onRead: line => root._bridgeLine(line) }
    stderr: SplitParser { onRead: line => console.warn("theo.clawchat bridge: " + line) }
    onExited: function(code, status) {
      root.connected = false
      if (!root.connError) root.connError = "bridge stopped (exit " + code + ")"
      bridgeRestart.restart()
    }
  }

  Timer {
    id: bridgeRestart
    interval: 8000
    onTriggered: bridge.running = true
  }

  function _tell(obj) {
    if (bridge.running) bridge.write(JSON.stringify(obj) + "\n")
  }

  function _bridgeLine(line) {
    var m
    try { m = JSON.parse(line) } catch (e) { return }
    if (m.t === "config") {
      root.agentName = m.agentName || "OpenClaw"
      root.keyLabel = m.keyLabel || "F8"
    } else if (m.t === "conn") {
      root.connected = !!m.ok
      root.connError = m.error ? String(m.error) : ""
      if (m.ok && root.overlayOpen) root._tell({ cmd: "visible", on: true })
    } else if (m.t === "history") {
      root.history = m.messages || []
      root.running = !!m.running
      if (!m.running) root.streamText = ""
      else if (m.inflight && !root.streamText) root.streamText = m.inflight
      root._dropDelivered()
    } else if (m.t === "delta") {
      root.running = true
      root.streamText = m.text || ""
    } else if (m.t === "final") {
      root.streamText = ""
      if (m.state !== "final") root._flash(m.error ? root.agentName + ": " + m.error : root.agentName + " stopped")
    } else if (m.t === "sent") {
      if (m.ok) root.running = true
      else root._sendFailed(m.id, m.error || "send failed")
    }
  }

  // A pending message leaves the list once the history holds it.
  function _dropDelivered() {
    if (!root.pending.length) return
    var recent = root.history.slice(-12)
    var keep = []
    for (var i = 0; i < root.pending.length; i++) {
      var p = root.pending[i]
      var found = false
      for (var j = 0; j < recent.length && !found; j++)
        found = recent[j].role === "user" && recent[j].text.trim() === p.text && recent[j].ts >= p.ts - 60000
      if (!found) keep.push(p)
    }
    if (keep.length !== root.pending.length) root.pending = keep
  }

  function _sendFailed(id, error) {
    var keep = []
    var text = ""
    for (var i = 0; i < root.pending.length; i++) {
      if (root.pending[i].id === id) text = root.pending[i].text
      else keep.push(root.pending[i])
    }
    root.pending = keep
    // Give the text back rather than losing it.
    if (text && !root.draft.trim()) root.draftSet(text)
    root._flash("Not sent: " + error)
  }

  function _uuid() {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c) {
      var r = Math.random() * 16 | 0
      return (c === "x" ? r : (r & 0x3 | 0x8)).toString(16)
    })
  }

  function send() {
    var text = root.draft.trim()
    if (!text) return false
    if (!root.connected) {
      root._flash(root.connError ? root.agentName + " is unreachable: " + root.connError : "Not connected yet")
      return false
    }
    var id = root._uuid()
    root.pending = root.pending.concat([{ id: id, role: "user", text: text, ts: Date.now(), local: true }])
    root._tell({ cmd: "send", id: id, text: text })
    root.draftSet("")
    return true
  }

  // ------------------------------------------------------------------- voice
  property double _recStoppedAt: 0
  property bool _sendAfterTranscript: false

  function _voice(args) { Quickshell.execDetached([root.voicePath].concat(args)) }

  function startRecording() {
    if (root.voice !== "idle") return
    root.voice = "recording"
    root.notice = ""
    root._voice(["start"])
  }

  function stopRecording() {
    if (root.voice !== "recording") return
    root.voice = "transcribing"
    root._recStoppedAt = Date.now()
    root._voice(["stop"])
    voicePoll.restart()
  }

  function cancelRecording() {
    if (root.voice === "idle") return
    root._voice(["cancel"])
    voicePoll.stop()
    root.voice = "idle"
    root._sendAfterTranscript = false
  }

  Timer {
    id: voicePoll
    interval: 200
    repeat: true
    onTriggered: if (!pollProc.running) pollProc.running = true
  }

  Process {
    id: pollProc
    command: [root.voicePath, "poll"]
    stdout: StdioCollector { onStreamFinished: root._voicePolled(text) }
  }

  function _voicePolled(out) {
    if (root.voice !== "transcribing") { voicePoll.stop(); return }
    var nl1 = out.indexOf("\n")
    var nl2 = out.indexOf("\n", nl1 + 1)
    if (nl1 < 0 || nl2 < 0) return
    var status = out.slice(0, nl1).trim()
    var outcome = null
    try { outcome = JSON.parse(out.slice(nl1 + 1, nl2)) } catch (e) {}
    var text = out.slice(nl2 + 1).trim()
    var age = Date.now() - root._recStoppedAt
    // Done once voxtype is idle again and has reported on a recording that
    // ended after we asked it to stop.
    var reported = outcome && Number(outcome.at_ms) >= root._recStoppedAt - 500
    if (status !== "idle" || (!reported && !text && age < 4000)) {
      if (age > 120000) { voicePoll.stop(); root.voice = "idle"; root._flash("Transcription timed out") }
      return
    }
    voicePoll.stop()
    root.voice = "idle"
    if (text) {
      root.draftAppend(text)
      if (root._sendAfterTranscript) Qt.callLater(root.send)
    } else {
      root._flash("Didn't catch anything")
    }
    root._sendAfterTranscript = false
  }

  // --------------------------------------------------------------- key logic
  property bool _held: false
  property bool _pressOpened: false
  property double _pressAt: 0

  Timer {
    id: holdTimer
    interval: root.tapMs
    onTriggered: if (root._held && root.overlayOpen) root.startRecording()
  }

  function press() {
    if (root._held) return            // key repeat
    root._held = true
    root._pressAt = Date.now()
    if (!root.overlayOpen) {
      root._pressOpened = true
      root.open()
      root.startRecording()
    } else {
      root._pressOpened = false
      holdTimer.restart()
    }
  }

  function release() {
    if (!root._held) return
    root._held = false
    var quick = Date.now() - root._pressAt < root.tapMs
    holdTimer.stop()
    if (root._pressOpened) {
      if (quick) root.cancelRecording()
      else root.stopRecording()
      return
    }
    if (root.voice === "recording") { root.stopRecording(); return }
    root.tap()
  }

  // A tap while the window is open: send, or close when there is nothing to send.
  function tap() {
    if (root.voice === "transcribing") { root._sendAfterTranscript = true; return }
    if (root.draft.trim()) root.send()
    else root.close()
  }

  // ------------------------------------------------------------ open / close
  function open() {
    if (root.overlayOpen) return true
    root.overlayOpen = true
    root.notice = ""
    root._tell({ cmd: "visible", on: true })
    if (!bridge.running) { bridgeRestart.stop(); bridge.running = true }
    try {
      if (root.shell && typeof root.shell.isPluginOpen === "function" && root.shell.isPluginOpen(root.pluginId)) return true
      if (root.shell && typeof root.shell.summon === "function" && root.shell.summon(root.pluginId, "{}")) return true
    } catch (e) {
      console.warn("theo.clawchat: summon threw: " + e)
    }
    console.warn("theo.clawchat: could not show the overlay")
    root.overlayOpen = false
    return false
  }

  property bool _closing: false
  function close() {
    if (root._closing || !root.overlayOpen) return
    root._closing = true
    root.overlayOpen = false
    root._held = false
    holdTimer.stop()
    root.cancelRecording()
    root._tell({ cmd: "visible", on: false })
    try {
      if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    } catch (e) { console.warn("theo.clawchat: hide threw: " + e) }
    root._closing = false
  }

  function toggle() {
    if (root.overlayOpen) root.close()
    else root.open()
  }

  function _flash(text) {
    root.notice = text
    noticeTimer.restart()
  }

  Timer {
    id: noticeTimer
    interval: 6000
    onTriggered: root.notice = ""
  }

  // ------------------------------------------------------------------- IPC
  IpcHandler {
    target: "theo.clawchat"

    function press(): void { root.press() }
    function release(): void { root.release() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root._tell({ cmd: "refresh" }) }
    function status(): string {
      return JSON.stringify({
        open: root.overlayOpen, connected: root.connected, error: root.connError, running: root.running,
        voice: root.voice, messages: root.history.length, pending: root.pending.length,
        draftChars: root.draft.length, notice: root.notice
      })
    }
  }
}
