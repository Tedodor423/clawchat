import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import ".." as M

// Renders ChatCard with a fake service in a few states and saves PNGs.
Item {
  id: h
  readonly property string dir: Quickshell.env("CLAWCHAT_DEV_DIR") || "/tmp/theo-clawchat-dev"

  QtObject {
    id: fake
    property bool connected: true
    property string connError: ""
    property bool running: false
    property string streamText: ""
    property string voice: "idle"
    property string draft: ""
    property string notice: ""
    property string agentName: "Marvin"
    property string keyLabel: "F8"
    property var messages: [
      { id: "1", role: "user", text: "remind me to water the plants tmr morning", ts: Date.now() - 7200000 },
      { id: "2", role: "assistant", text: "I've set a reminder to water the plants **tomorrow at 09:00**.", ts: Date.now() - 7190000 },
      { id: "3", role: "user", text: "🎙 Put a weekly team lunch in my calendar, every Thursday at noon until the end of June, and don't let it block my calendar.", ts: Date.now() - 600000 },
      { id: "4", role: "assistant", text: "I've added **Team lunch** to your calendar:\n\n- **When:** Thursdays 12:00–13:00\n- **Until:** 24 June\n- **Shows as:** free, no reminder\n\nSee [the calendar](https://example.com/calendar).", ts: Date.now() - 590000 }
    ]
    signal draftAppend(string text)
    signal draftSet(string text)
    function send() {}
    function close() {}
  }

  Rectangle { anchors.fill: parent; color: "#556070" }
  Rectangle { anchors.fill: parent; color: Util.alpha(Commons.Color.background, 0.45) }

  M.ChatCard { id: card; anchors.centerIn: parent; service: fake; availableWidth: h.width; availableHeight: h.height }

  property var steps: ["idle", "recording", "draft", "running", "stream", "offline"]
  property int i: 0
  property bool grabNext: false

  function apply(s) {
    fake.voice = "idle"; fake.running = false; fake.streamText = ""; fake.connected = true; fake.connError = ""
    if (s === "recording") fake.voice = "recording"
    else if (s === "draft") fake.draftSet("What's on my calendar tomorrow morning, and do I have time for a run before my first meeting?")
    else if (s === "running") { fake.draftSet(""); fake.running = true }
    else if (s === "stream") { fake.running = true; fake.streamText = "Tomorrow morning you have **one thing**: stand-up at 09:30. A run before" }
    else if (s === "offline") { fake.connected = false; fake.connError = "connection closed" }
  }

  Timer {
    interval: 500; repeat: true; running: true
    onTriggered: {
      if (h.grabNext) {
        var s = h.steps[h.i]
        h.grabToImage(function(r) { r.saveToFile(h.dir + "/shots/" + s + ".png") })
        h.grabNext = false
        h.i++
        return
      }
      if (h.i >= h.steps.length) { Qt.quit(); return }
      h.apply(h.steps[h.i])
      console.log("card " + h.steps[h.i] + ": " + card.width + "x" + card.height)
      h.grabNext = true
    }
  }
}
