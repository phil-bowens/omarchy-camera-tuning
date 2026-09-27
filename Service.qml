import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Keeps the camera list current and puts remembered controls back when a
// camera is plugged in or the machine wakes. The work is done by webcam-ctl;
// this service runs it once at startup and then follows its watch output.
Item {
  id: root

  // Injected by the shell.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "io.github.phil-bowens.camera-tuning"
  // A plugin is not told where it lives; installed plugins are always here.
  readonly property string tool: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + pluginId + "/webcam-ctl"

  property var cameras: []
  property bool camerasLoaded: false
  property bool refreshPending: false
  // True when the helper could not run at all (a tool missing, say): an empty
  // camera list then means nothing, and the panel says so.
  property bool toolFailed: false

  // Fires after remembered controls were re-applied, so an open panel can
  // re-read the camera it is showing. Camera comings and goings are visible
  // through the cameras property itself.
  signal reapplied()

  function refresh() {
    if (listProc.running) { refreshPending = true; return }
    listProc.running = true
  }

  Process {
    id: listProc
    command: ["/bin/bash", root.tool, "list"]
    // webcam-ctl caps its list at 256 KiB before the collector sees it.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.cameras = Model.parseCameraList(text)
        root.camerasLoaded = true
      }
    }
    stderr: SplitParser { onRead: function(line) { if (line) console.warn("webcam: " + line) } }
    onExited: function(code) {
      root.toolFailed = code !== 0
      if (code !== 0) console.warn("webcam: list exited " + code)
      if (root.refreshPending) { root.refreshPending = false; root.refresh() }
    }
  }

  Process {
    id: applyProc
    command: ["/bin/bash", root.tool, "apply"]
    stderr: SplitParser { onRead: function(line) { if (line) console.warn("webcam: " + line) } }
    onExited: root.reapplied()
  }

  Process {
    id: watchProc
    command: ["/bin/bash", root.tool, "watch"]
    property double startedAt: 0
    onStarted: startedAt = Date.now()
    stdout: SplitParser {
      onRead: function(line) {
        var event = String(line || "").trim()
        if (event.indexOf("added ") === 0 || event.indexOf("removed ") === 0 || event === "changed") root.refresh()
        if (event.indexOf("added ") === 0 || event === "resumed") root.reapplied()
      }
    }
    stderr: SplitParser { onRead: function(line) { if (line) console.warn("webcam: " + line) } }
    onExited: function(code) {
      // A run that lasted a while was healthy; only a watcher that keeps
      // dying at once backs off.
      if (Date.now() - startedAt > 60000) watchRestart.interval = 5000
      if (code !== 0) console.warn("webcam: watch exited " + code)
      watchRestart.restart()
    }
  }

  // The watcher is meant to run for the life of the shell; if it dies, come
  // back after 5 s, and if it keeps dying (a tool missing, say) come back
  // less often, doubling up to 10 minutes, rather than spawn a shell every
  // few seconds forever. The wait goes back to 5 s after a healthy run.
  Timer {
    id: watchRestart
    interval: 5000
    repeat: false
    onTriggered: {
      if (!watchProc.running) watchProc.running = true
      interval = Math.min(interval * 2, 600000)
    }
  }

  Component.onCompleted: {
    refresh()
    applyProc.running = true
    watchProc.running = true
  }
}
