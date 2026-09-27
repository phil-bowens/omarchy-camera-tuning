import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar button with a popup listing whatever controls the camera reports:
// switches for booleans, a slider for each range, a row that steps through
// the entries of a menu. Every change goes through webcam-ctl, which sets the
// control and remembers it for that camera.
Panel {
  id: root
  moduleName: "io.github.phil-bowens.camera-tuning"
  ipcTarget: "io.github.phil-bowens.camera-tuning"

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string tool: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + moduleName + "/webcam-ctl"

  // The service keeps the camera list current and re-applies remembered
  // controls. A replacement bar hands out a facade without services; the
  // panel then lists cameras itself, on open and every half minute.
  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  property var ownCameras: []
  readonly property var cameras: service ? service.cameras : ownCameras
  property string selectedCameraId: ""
  readonly property var camera: {
    for (var i = 0; i < cameras.length; i++)
      if (cameras[i].id === selectedCameraId) return cameras[i]
    return cameras.length > 0 ? cameras[0] : null
  }
  readonly property bool hasCamera: camera !== null
  readonly property bool cameraOff: Model.isOff(camera)
  readonly property bool cameraOn: hasCamera && !cameraOff
  readonly property bool canSwitch: Model.canSwitch(camera)
  // Only a video node is ever handed to the helper; anything else the list
  // could carry is treated as no device.
  readonly property string cameraDevice: cameraOn && /^\/dev\/video[0-9]+$/.test(String(camera.device)) ? String(camera.device) : ""

  property var controls: []
  // The listing was cut by webcam-ctl's byte cap, the model's control cap,
  // or a deadline; the panel says so rather than show a shorter camera.
  property bool controlsTruncated: false
  // The helper could not run (a tool missing): said in the empty state.
  property bool toolFailed: false
  readonly property bool toolBroken: service ? service.toolFailed : toolFailed

  // The live frame is opt-in and lives no longer than the panel is open:
  // opening the panel must not light the camera or take it from a call.
  property bool previewing: false
  readonly property var sections: Model.sections(controls)
  readonly property bool showCameraRows: cameras.length > 1

  // Cursor targets in reading order, addressed by a stable key rather than a
  // row index: switching an auto mode makes rows appear and disappear, and
  // the cursor should stay on the row it was on.
  readonly property var cursorKeys: {
    var keys = []
    if (canSwitch) keys.push("power")
    if (cameraOn) keys.push("preview")
    if (cameraOn) keys.push("reset")
    if (showCameraRows)
      for (var c = 0; c < cameras.length; c++) keys.push("camera:" + cameras[c].id)
    for (var s = 0; s < sections.length; s++)
      for (var i = 0; i < sections[s].controls.length; i++)
        if (Model.isEditable(sections[s].controls[i])) keys.push("control:" + sections[s].controls[i].name)
    return keys
  }
  property bool cursorActive: false
  property string cursorKey: "power"
  readonly property string activeKey: cursorActive ? cursorKey : ""

  property var pendingSets: Model.emptyMap()
  // Values sent to the camera and not yet read back. Rows show these so a
  // switch throws at once, and a second keypress builds on the first rather
  // than on the value the camera reported before either. Keyed by control
  // names from the driver, so no prototype.
  property var sentValues: Model.emptyMap()
  property bool reloadPending: false

  function controlByName(name) {
    for (var i = 0; i < controls.length; i++)
      if (controls[i].name === name) return controls[i]
    return null
  }

  function shownValue(ctrl) {
    if (!ctrl) return 0
    var sent = sentValues[ctrl.name]
    return sent === undefined ? ctrl.value : sent
  }

  function setCursor(key) {
    cursorActive = true
    cursorKey = key
  }

  function moveCursor(delta) {
    var keys = cursorKeys
    if (keys.length === 0) return
    var index = keys.indexOf(cursorKey)
    if (index < 0) index = delta > 0 ? -1 : 0
    cursorKey = keys[Math.max(0, Math.min(keys.length - 1, index + delta))]
  }

  function activateCursor() {
    if (cursorKey === "power") { togglePower(); return }
    if (cursorKey === "preview") { previewing = !previewing; return }
    if (cursorKey === "reset") { resetCamera(); return }
    if (cursorKey.indexOf("camera:") === 0) { selectedCameraId = cursorKey.slice(7); return }
    if (cursorKey.indexOf("control:") === 0) {
      var ctrl = controlByName(cursorKey.slice(8))
      if (!ctrl || !Model.isEditable(ctrl)) return
      if (ctrl.type === "bool") setControl(ctrl.name, shownValue(ctrl) ? 0 : 1)
      else if (ctrl.type === "menu" || ctrl.type === "intmenu") setControl(ctrl.name, Model.menuStep(current(ctrl), 1))
    }
  }

  // The control as the panel is showing it: the camera's record with the
  // value that was last sent, when one is still in flight.
  function current(ctrl) {
    if (!ctrl || sentValues[ctrl.name] === undefined) return ctrl
    var copy = {}
    for (var k in ctrl) copy[k] = ctrl[k]
    copy.value = sentValues[ctrl.name]
    return copy
  }

  // h/l: a switch goes off/on, a menu steps, a range moves by a keyboard nudge.
  function adjustCursor(delta) {
    if (cursorKey.indexOf("control:") !== 0) return
    var ctrl = controlByName(cursorKey.slice(8))
    if (!ctrl || !Model.isEditable(ctrl)) return
    if (ctrl.type === "bool") setControl(ctrl.name, delta > 0 ? 1 : 0)
    else if (ctrl.type === "menu" || ctrl.type === "intmenu") setControl(ctrl.name, Model.menuStep(current(ctrl), delta))
    else setControl(ctrl.name, Model.clampValue(ctrl, shownValue(ctrl) + delta * Model.keyStep(ctrl)))
  }

  // One set at a time, latest value per control wins: a slider drag produces
  // more events than v4l2-ctl calls are worth, and the camera only needs the
  // last one. When the queue drains, re-read the camera, which is the truth.
  function setControl(name, value) {
    if (!cameraOn) return
    var next = Model.emptyMap()
    for (var k in pendingSets) next[k] = pendingSets[k]
    next[name] = value
    pendingSets = next
    var sent = Model.emptyMap()
    for (var s in sentValues) sent[s] = sentValues[s]
    sent[name] = value
    sentValues = sent
    pumpSets()
  }

  function pumpSets() {
    if (setProc.running) return
    var names = Object.keys(pendingSets)
    if (names.length === 0) { reload(); return }
    var name = names[0]
    var value = pendingSets[name]
    var rest = Model.emptyMap()
    for (var k in pendingSets) if (k !== name) rest[k] = pendingSets[k]
    pendingSets = rest
    if (!cameraDevice) return
    setProc.command = ["/bin/bash", tool, "set", cameraDevice, name + "=" + value]
    setProc.running = true
  }

  function resetCamera() {
    if (!cameraDevice || resetProc.running) return
    resetProc.command = ["/bin/bash", tool, "reset", cameraDevice]
    resetProc.running = true
  }

  // Off de-authorizes the USB device, so the camera is gone from the system
  // until it is switched back on; both directions go through polkit, which
  // asks for the password in the shell's own dialog.
  function togglePower() {
    if (!canSwitch || powerProc.running) return
    selectedCameraId = camera.id
    powerProc.command = cameraOff
      ? ["/bin/bash", tool, "on", String(camera.id)]
      : ["/bin/bash", tool, "off", cameraDevice]
    powerProc.running = true
  }

  function reload() {
    if (!cameraDevice) { controls = []; controlsTruncated = false; return }
    if (controlsProc.running) { reloadPending = true; return }
    controlsProc.command = ["/bin/bash", tool, "controls", cameraDevice]
    controlsProc.running = true
  }

  function finishReload(code) {
    // A deadline (124) or any other failure means the listing is not the
    // whole camera.
    if (code !== 0) { controlsTruncated = true; console.warn("webcam: controls exited " + code) }
    if (reloadPending) { reloadPending = false; reload(); return }
    // Nothing left in flight: what the camera reports is the truth again.
    if (Object.keys(pendingSets).length === 0 && !setProc.running) sentValues = Model.emptyMap()
  }

  function refreshCameras() {
    if (service) service.refresh()
    else if (!listProc.running) listProc.running = true
  }

  // Keep the keyboard cursor inside the scroll viewport.
  function ensureCursorVisible(item) {
    var flick = scrollArea.contentItem
    if (!item || !flick || panelColumn.implicitHeight <= scrollArea.height) return
    var top = item.mapToItem(panelColumn, 0, 0).y
    var bottom = top + item.height
    if (top < flick.contentY) flick.contentY = Math.max(0, top - Style.space(8))
    else if (bottom > flick.contentY + flick.height) flick.contentY = bottom - flick.height + Style.space(8)
  }

  onOpenedChanged: {
    // Each opening starts at the top, so the first keypress lands somewhere
    // predictable rather than on the row that was current last time.
    if (opened) { cursorActive = false; cursorKey = cursorKeys.length > 0 ? cursorKeys[0] : "power"; refreshCameras(); reload() }
    else { pendingSets = Model.emptyMap(); sentValues = Model.emptyMap(); previewing = false }
  }
  onCameraDeviceChanged: if (opened) reload()

  Connections {
    target: root.service
    function onReapplied() { if (root.opened) root.reload() }
  }

  Process {
    id: listProc
    command: ["/bin/bash", root.tool, "list"]
    // webcam-ctl caps its list at 256 KiB before the collector sees it.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ownCameras = Model.parseCameraList(text)
    }
    stderr: SplitParser { onRead: function(line) { if (line) console.warn("webcam: " + line) } }
    onExited: function(code) { root.toolFailed = code !== 0 }
  }

  Timer {
    interval: 30000
    running: !root.service && !root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!listProc.running) listProc.running = true
  }

  // While the panel is open, keep "In use by" honest.
  Timer {
    interval: 3000
    running: root.opened
    repeat: true
    onTriggered: root.refreshCameras()
  }

  Process {
    id: controlsProc
    // webcam-ctl caps this at 256 KiB and marks a cut listing; the model
    // caps controls and menu entries on top. Bounded by the producer, not here.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseControlsDetailed(text)
        root.controls = parsed.controls
        root.controlsTruncated = parsed.truncated
      }
    }
    stderr: SplitParser { onRead: function(line) { if (line) console.warn("webcam: " + line) } }
    onExited: function(code) { root.finishReload(code) }
  }

  Process {
    id: setProc
    stderr: SplitParser { onRead: function(line) { if (line) console.warn("webcam: " + line) } }
    onExited: root.pumpSets()
  }

  Process {
    id: resetProc
    stderr: SplitParser { onRead: function(line) { if (line) console.warn("webcam: " + line) } }
    onExited: root.reload()
  }

  Process {
    id: powerProc
    stderr: SplitParser { onRead: function(line) { if (line) console.warn("webcam: " + line) } }
    onExited: { root.refreshCameras(); root.reload() }
  }

  // The button goes when the last camera does, except while its panel is
  // open: the panel is anchored to it, and says what happened.
  implicitWidth: hasCamera || opened ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight
  visible: hasCamera || opened

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰄀"
    opacity: root.cameraOff ? 0.5 : 1.0
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(fixedTop.implicitHeight + Style.space(14) + panelColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustCursor(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // The camera's name, its state and its switch stay put; the sections
      // scroll beneath them, the way Bluetooth keeps connected devices
      // above its scrolling lists.
      Column {
        id: fixedTop
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(14)

        PanelHero {
          title: root.hasCamera ? Model.cameraLabel(root.camera.name) : "Camera"
          meta: previewFrame.waiting ? "Starting the camera"
            : (previewFrame.showing && !previewFrame.loadFailed && previewFrame.preview && !previewFrame.preview.failed
              ? "Previewing" : Model.statusText(root.camera))
          foreground: root.fg
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: "󰄀"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            Row {
              spacing: Style.space(10)

              PanelActionButton {
                visible: root.cameraOn
                iconText: root.previewing ? "󰈉" : "󰈈"
                tooltipText: root.previewing ? "Stop the preview" : "Preview the picture"
                foreground: root.fg
                fontFamily: root.fontFamily
                hasCursor: root.activeKey === "preview"
                anchors.verticalCenter: parent.verticalCenter
                onHovered: function(on) { if (on) root.setCursor("preview") }
                onClicked: root.previewing = !root.previewing
              }

              PanelActionButton {
                visible: root.cameraOn
                iconText: "󰦛"
                tooltipText: "Back to camera defaults"
                foreground: root.fg
                fontFamily: root.fontFamily
                hasCursor: root.activeKey === "reset"
                anchors.verticalCenter: parent.verticalCenter
                onHovered: function(on) { if (on) root.setCursor("reset") }
                onClicked: root.resetCamera()
              }

              ToggleSwitch {
                id: powerSwitch
                visible: root.canSwitch
                checked: root.cameraOn
                busy: powerProc.running
                hasCursor: root.activeKey === "power"
                foreground: root.fg
                anchors.verticalCenter: parent.verticalCenter
                onHovered: function(on) { if (on) root.setCursor("power") }
                onToggled: root.togglePower()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: root.cameraOn ? "Turn camera off" : "Turn camera on"
                  fontFamily: root.fontFamily
                }
              }
            }
          }
        }

        // Under the name, above the controls, and pinned with them: the point
        // is to watch the picture while a slider moves. The frame is drawn the
        // moment the preview is asked for; the camera and the multimedia
        // module come up behind a loading mark, then the picture takes over.
        Rectangle {
          id: previewFrame
          readonly property bool showing: root.previewing && root.cameraOn && root.opened
          readonly property var preview: previewLoader.item
          // Qt Multimedia missing or broken: the loader fails, and that is a
          // final state with its own message, not a spinner forever.
          readonly property bool loadFailed: previewLoader.status === Loader.Error
          readonly property bool waiting: showing && !loadFailed && (!preview || (!preview.hasFrame && !preview.failed))
          width: parent.width
          height: showing ? Math.round(width * 9 / 16) : 0
          visible: showing
          radius: Style.cornerRadius
          color: "black"
          clip: true

          Loader {
            id: previewLoader
            anchors.fill: parent
            active: previewFrame.showing
            asynchronous: true
            source: active ? Qt.resolvedUrl("Preview.qml") : ""
            onLoaded: {
              item.device = Qt.binding(function() { return root.cameraDevice })
              item.cameraName = Qt.binding(function() { return root.camera ? String(root.camera.name) : "" })
            }
            onStatusChanged: if (status === Loader.Error) console.warn("webcam: preview could not load (is qt6-multimedia installed?)")
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: previewFrame.waiting

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "󰦖"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              RotationAnimator on rotation {
                running: previewFrame.waiting
                from: 0; to: 360
                duration: 800
                loops: Animation.Infinite
              }
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "Starting the camera…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            visible: previewFrame.loadFailed || (!!previewFrame.preview && previewFrame.preview.failed)
            textFormat: Text.PlainText
            text: previewFrame.loadFailed ? "No preview: Qt Multimedia is not available"
              : (previewFrame.preview ? previewFrame.preview.problem : "")
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }

        PanelSeparator { foreground: root.fg }
      }

      ScrollView {
        id: scrollArea
        anchors.top: fixedTop.bottom
        anchors.topMargin: Style.space(14)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        readonly property bool overflowing: panelColumn.implicitHeight > height
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        // A bar that is there whenever there is more below: this panel is
        // long on a laptop screen, and a bar that only appears mid-scroll
        // does not say so.
        ScrollBar.vertical.policy: overflowing ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: scrollArea.overflowing
        }
        Binding {
          target: scrollArea.contentItem
          property: "boundsBehavior"
          value: Flickable.StopAtBounds
        }

        function scrollBy(pixels) {
          var flick = scrollArea.contentItem
          if (!flick || !scrollArea.overflowing) return
          var max = Math.max(0, flick.contentHeight - flick.height)
          flick.contentY = Math.max(0, Math.min(max, flick.contentY - pixels))
        }

        Column {
          id: panelColumn
          // The bar paints over the content's right edge; leave it room so
          // the values stay readable.
          width: scrollArea.availableWidth
            - (scrollArea.overflowing ? scrollArea.ScrollBar.vertical.width + Style.space(6) : 0)
          spacing: Style.space(14)

          // ---- Cameras, only when there is a choice ----
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.showCameraRows

            PanelSectionHeader {
              text: "CAMERAS"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.showCameraRows ? root.cameras.length : 0

              CursorSurface {
                id: cameraRow
                required property int index
                readonly property var cam: root.cameras[index] || null
                readonly property string key: "camera:" + (cam ? cam.id : "")

                width: panelColumn.width
                hasCursor: root.activeKey === key
                current: !!(cam && root.camera && cam.id === root.camera.id)
                foreground: root.fg
                implicitHeight: cameraInner.implicitHeight + Style.spacing.xl
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(cameraRow)

                Row {
                  id: cameraInner
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: cameraRow.cam ? Model.cameraLabel(cameraRow.cam.name) : ""
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: cameraRow.current
                    elide: Text.ElideRight
                    width: parent.width - deviceText.width - parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    id: deviceText
                    textFormat: Text.PlainText
                    text: cameraRow.cam ? cameraRow.cam.device : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) root.setCursor(cameraRow.key)
                  onClicked: if (cameraRow.cam) root.selectedCameraId = cameraRow.cam.id
                }
              }
            }
          }

          // ---- One section per control class the camera reports ----
          Repeater {
            model: root.sections.length

            Column {
              id: sectionColumn
              required property int index
              readonly property var section: root.sections[index] || null

              width: panelColumn.width
              spacing: Style.space(14)

              PanelSeparator {
                visible: sectionColumn.index > 0 || root.showCameraRows
                foreground: root.fg
              }

              Column {
                width: parent.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: sectionColumn.section ? sectionColumn.section.title : ""
                  foreground: root.fg
                  fontFamily: root.fontFamily
                }

                Repeater {
                  model: sectionColumn.section ? sectionColumn.section.controls.length : 0

                  ControlRow {
                    required property int index
                    width: panelColumn.width
                    ctrl: sectionColumn.section && sectionColumn.section.controls[index]
                      ? sectionColumn.section.controls[index] : null
                  }
                }
              }
            }
          }

          Text {
            visible: root.cameraOn && root.controlsTruncated
            width: parent.width
            textFormat: Text.PlainText
            text: "Control list cut short: the camera reported more than can be shown."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: !root.cameraOn
            width: parent.width
            textFormat: Text.PlainText
            text: root.cameraOff
              ? "The camera is switched off. Nothing can see it until it is switched on again, or the machine restarts."
              : (root.toolBroken
                ? "The camera tool could not run. The shell log says which part is missing."
                : "No camera. Plug one in and its controls appear here.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
        }
      }

      // The wheel scrolls the panel wherever the pointer is, by the same
      // amount each notch. Without this a notch over a slider changes that
      // control (PanelSlider handles wheel itself) and a notch over a switch
      // scrolls, which in a panel that is mostly sliders is two behaviors.
      // Buttons pass through, so rows, sliders and the bar still take clicks
      // and drags; sliders move by drag or the h/l keys.
      MouseArea {
        anchors.fill: scrollArea
        acceptedButtons: Qt.NoButton
        onWheel: function(wheel) {
          var pixels = wheel.pixelDelta.y !== 0
            ? wheel.pixelDelta.y
            : (wheel.angleDelta.y / 120) * Style.space(64)
          scrollArea.scrollBy(pixels)
          wheel.accepted = true
        }
      }
    }
  }

  // A control as the camera describes it. Inactive ones (manual focus while
  // autofocus is on) stay visible but dimmed and out of the cursor's path, so
  // the row that would bring them back is easy to find.
  component ControlRow: CursorSurface {
    id: row
    property var ctrl: null

    readonly property string name: ctrl ? ctrl.name : ""
    readonly property string key: "control:" + name
    readonly property bool editable: Model.isEditable(ctrl)
    readonly property bool isBool: !!ctrl && ctrl.type === "bool"
    readonly property bool isMenu: !!ctrl && (ctrl.type === "menu" || ctrl.type === "intmenu")
    readonly property bool isRange: !!ctrl && ctrl.type === "int"
    readonly property var shown: root.current(ctrl)
    readonly property int shownValue: slider.dragging ? Math.round(slider.liveValue) : (shown ? shown.value : 0)

    hasCursor: editable && root.activeKey === key
    foreground: root.fg
    opacity: editable ? 1.0 : 0.45
    implicitHeight: rowContent.implicitHeight + Style.spacing.xl
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(row)

    function step(delta) {
      if (!editable) return
      if (isBool) root.setControl(name, delta > 0 ? 1 : 0)
      else if (isMenu) root.setControl(name, Model.menuStep(shown, delta))
    }

    Column {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(2)

      Item {
        id: headline
        width: parent.width
        implicitHeight: Math.max(nameText.implicitHeight, trailing.implicitHeight, Style.space(22))

        Text {
          id: nameText
          textFormat: Text.PlainText
          text: Model.label(row.name)
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          anchors.left: parent.left
          anchors.right: trailing.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }

        Row {
          id: trailing
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Text {
            visible: !row.isBool
            textFormat: Text.PlainText
            text: row.isRange ? String(row.shownValue) : Model.valueText(row.shown)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            visible: row.isMenu
            textFormat: Text.PlainText
            text: "󰅂"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }

          ToggleSwitch {
            visible: row.isBool
            checked: !!(row.shown && row.shown.value)
            interactive: false
            foreground: root.fg
            trackHeight: Style.space(18)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // The headline owns clicks for switches and menus; the slider below
        // handles its own, so a drag never has to fight a covering MouseArea.
        MouseArea {
          anchors.fill: parent
          enabled: row.editable && !row.isRange
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: row.editable && !row.isRange ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) row.step(-1)
            else if (row.isBool) root.setControl(row.name, row.shown.value ? 0 : 1)
            else row.step(1)
          }
        }
      }

      PanelSlider {
        id: slider
        visible: row.isRange
        bar: root.bar
        width: parent.width
        integer: true
        minimum: row.ctrl && row.ctrl.min !== null ? row.ctrl.min : 0
        maximum: row.ctrl && row.ctrl.max !== null ? row.ctrl.max : 1
        step: row.ctrl && row.ctrl.step > 0 ? row.ctrl.step : 1
        value: row.shown ? row.shown.value : 0
        enabled: row.editable
        onMoved: function(v) { root.setControl(row.name, Model.clampValue(row.ctrl, v)) }
      }
    }

    HoverHandler {
      enabled: row.editable
      onHoveredChanged: if (hovered) root.setCursor(row.key)
    }
  }
}
