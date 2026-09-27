import QtQuick
import QtMultimedia
import qs.Commons

// A live frame from the camera, drawn by the shell itself through Qt
// Multimedia. Loaded only while the preview is on, so the multimedia module
// and the camera stream exist only then; destroying this item stops the
// stream.
Item {
  id: root

  property string device: ""
  property string cameraName: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  // Qt did not offer the panel's camera under its device node or its name.
  // Showing some other camera instead would be a lie about the picture.
  property bool missing: false
  readonly property bool failed: missing || camera.error !== Camera.NoError
  // Qt says "Camera is in use" for a device another process is streaming.
  readonly property string problem: missing ? "No picture: the camera is not offered to Qt Multimedia"
    : failed
      ? (/in use|busy/i.test(String(camera.errorString || ""))
        ? "Another app has the camera" : "No picture: " + camera.errorString)
      : ""

  // True once a frame has been drawn; the panel shows its loading mark
  // until then.
  property bool hasFrame: false

  // Qt names V4L2 cameras by their device node, so the panel's camera is the
  // one whose id is its /dev/videoN, or failing that the one with its name.
  // No match means no picture, never a different camera.
  function pickDevice() {
    var inputs = mediaDevices.videoInputs
    for (var i = 0; i < inputs.length; i++)
      if (String(inputs[i].id) === root.device) return inputs[i]
    for (var j = 0; j < inputs.length; j++)
      if (root.cameraName && String(inputs[j].description) === root.cameraName) return inputs[j]
    return null
  }

  // The smallest mode that is still worth looking at: a preview this size
  // does not need 1080p, and a small MJPEG or YUYV stream costs little.
  function pickFormat(dev) {
    if (!dev || !dev.videoFormats) return null
    var best = null
    var formats = dev.videoFormats
    for (var i = 0; i < formats.length; i++) {
      var f = formats[i]
      var w = f.resolution.width
      if (w < 480) continue
      if (!best) { best = f; continue }
      var area = w * f.resolution.height
      var bestArea = best.resolution.width * best.resolution.height
      if (area < bestArea || (area === bestArea && f.maxFrameRate > best.maxFrameRate)) best = f
    }
    return best
  }

  MediaDevices { id: mediaDevices }

  CaptureSession {
    camera: Camera {
      id: camera
      onErrorOccurred: function(error, errorString) {
        console.warn("webcam preview: " + errorString)
      }
    }
    videoOutput: output
  }

  property bool ready: false

  // Start on the camera the panel is showing, and follow it when the panel
  // switches to another one while the preview is up.
  function open() {
    camera.stop()
    var dev = pickDevice()
    if (!dev) { missing = true; return }
    missing = false
    camera.cameraDevice = dev
    var format = pickFormat(dev)
    if (format) camera.cameraFormat = format
    camera.start()
  }

  onDeviceChanged: { hasFrame = false; if (ready) open() }

  Component.onCompleted: { ready = true; open() }
  Component.onDestruction: camera.stop()

  VideoOutput {
    id: output
    anchors.fill: parent
    fillMode: VideoOutput.PreserveAspectFit
  }

  Connections {
    target: output.videoSink
    function onVideoFrameChanged() { if (!root.hasFrame) root.hasFrame = true }
  }

  // Should the sink's signal not reach us on some backend, the mark still
  // clears a moment after the camera reports itself running.
  Timer {
    interval: 1500
    running: camera.active && !root.hasFrame && !root.failed
    onTriggered: root.hasFrame = true
  }
}
