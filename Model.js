// Pure helpers for the Camera tuning panel and service. Nothing here touches
// Qt, so the tests in test/ run them under node against captured v4l2-ctl
// output. Maps keyed by strings that come from a driver or a process are
// created without a prototype, and every lookup into a fixed table checks
// the table's own keys, so a control named "constructor" is just a name.

var LABELS = {
  brightness: "Brightness",
  contrast: "Contrast",
  saturation: "Saturation",
  hue: "Hue",
  gamma: "Gamma",
  gain: "Gain",
  sharpness: "Sharpness",
  backlight_compensation: "Backlight compensation",
  power_line_frequency: "Power line frequency",
  white_balance_automatic: "Auto white balance",
  white_balance_temperature: "White balance",
  auto_exposure: "Exposure mode",
  exposure_time_absolute: "Exposure time",
  exposure_absolute: "Exposure time",
  exposure_dynamic_framerate: "Dynamic frame rate",
  exposure_auto_priority: "Dynamic frame rate",
  focus_automatic_continuous: "Autofocus",
  focus_auto: "Autofocus",
  focus_absolute: "Focus",
  zoom_absolute: "Zoom",
  pan_absolute: "Pan",
  tilt_absolute: "Tilt",
  led1_mode: "LED",
  led1_frequency: "LED frequency",
  privacy: "Privacy shutter"
}

var SECTION_TITLES = {
  "User Controls": "IMAGE",
  "Camera Controls": "CAMERA"
}

// Control types the panel can render. Everything else (rect, bitmask, string,
// button, arrays) is left out rather than shown as something it is not.
var EDITABLE_TYPES = { bool: true, int: true, menu: true, intmenu: true }

// Caps on what one listing may turn into: the two real cameras here have 17
// and 16 controls; anything past these is not a camera describing itself.
var MAX_CONTROLS = 256
var MAX_MENU_ITEMS = 64
var MAX_LINE = 1024
var TRUNCATED_MARK = "# truncated"

function has(table, key) {
  return Object.prototype.hasOwnProperty.call(table, key)
}

function emptyMap() {
  return Object.create(null)
}

// Trailing whitespace off, by index rather than by a regex that has to try
// every starting point of a long run of spaces.
function rtrim(s) {
  var end = s.length
  while (end > 0 && /\s/.test(s.charAt(end - 1))) end--
  return s.slice(0, end)
}

var HEADER = /^\s*([a-z0-9_]+)\s+0x([0-9a-f]+)\s+\((\w+)\)\s*:\s*(.*)$/
var MENU_ITEM = /^\s+(-?\d+):\s*(.*)$/
var NUMBER_FIELD = /\b(min|max|step|default|value)=(-?\d+)\b/g
var VALUE_LABEL = /\bvalue=-?\d+\s+\(([^)]*)\)/
var FLAGS_FIELD = /\bflags=(.*)$/

// Parse `v4l2-ctl --list-ctrls-menus` into plain control records, in the
// order the driver lists them, each tagged with the class heading it sat
// under ("User Controls", "Camera Controls"). The result says whether the
// listing was cut: by webcam-ctl's byte cap (it leaves a marker line), or by
// the control and menu caps here.
function parseControlsDetailed(text) {
  var controls = []
  var section = ""
  var current = null
  var truncated = false
  var lines = String(text || "").split("\n")

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.length > MAX_LINE) line = line.slice(0, MAX_LINE)
    line = rtrim(line)
    if (line === "") continue
    if (line === TRUNCATED_MARK) { truncated = true; break }

    var header = HEADER.exec(line)
    if (header) {
      var rest = header[4]
      var flagsMatch = FLAGS_FIELD.exec(rest)
      var flags = flagsMatch ? flagsMatch[1].split(/,\s*/) : []
      var fields = flagsMatch ? rest.slice(0, flagsMatch.index) : rest
      var ctrl = {
        name: header[1],
        id: "0x" + header[2],
        type: header[3],
        section: section,
        min: null,
        max: null,
        step: 1,
        defaultValue: null,
        value: null,
        valueLabel: "",
        flags: flags,
        inactive: flags.indexOf("inactive") !== -1,
        readOnly: flags.indexOf("read-only") !== -1 || flags.indexOf("grabbed") !== -1
          || flags.indexOf("disabled") !== -1,
        menu: []
      }
      var m
      NUMBER_FIELD.lastIndex = 0
      while ((m = NUMBER_FIELD.exec(fields)) !== null) {
        var n = parseInt(m[2], 10)
        if (m[1] === "min") ctrl.min = n
        else if (m[1] === "max") ctrl.max = n
        else if (m[1] === "step") ctrl.step = n
        else if (m[1] === "default") ctrl.defaultValue = n
        else if (m[1] === "value") ctrl.value = n
      }
      var labelMatch = VALUE_LABEL.exec(fields)
      if (labelMatch) ctrl.valueLabel = labelMatch[1]
      if (ctrl.type === "bool") { ctrl.min = 0; ctrl.max = 1; ctrl.step = 1 }
      if (controls.length >= MAX_CONTROLS) { truncated = true; break }
      controls.push(ctrl)
      current = ctrl
      continue
    }

    var item = MENU_ITEM.exec(line)
    if (item && current && (current.type === "menu" || current.type === "intmenu")) {
      if (current.menu.length >= MAX_MENU_ITEMS) { truncated = true; continue }
      current.menu.push({ value: parseInt(item[1], 10), label: item[2] })
      continue
    }

    if (!/^\s/.test(line)) {
      section = line.trim()
      current = null
    }
  }

  return { controls: controls, truncated: truncated }
}

function parseControls(text) {
  return parseControlsDetailed(text).controls
}

function isRenderable(ctrl) {
  return !!ctrl && has(EDITABLE_TYPES, String(ctrl.type))
}

function isEditable(ctrl) {
  return isRenderable(ctrl) && !ctrl.inactive && !ctrl.readOnly
}

function humanize(name) {
  var text = String(name || "").replace(/_absolute$/, "").replace(/_/g, " ").trim()
  return text ? text.charAt(0).toUpperCase() + text.slice(1) : ""
}

function label(name) {
  var key = String(name || "")
  return has(LABELS, key) ? LABELS[key] : humanize(key)
}

function sectionTitle(className) {
  var key = rtrim(String(className || "")).trim()
  if (key.length > MAX_LINE) key = key.slice(0, MAX_LINE)
  if (has(SECTION_TITLES, key)) return SECTION_TITLES[key]
  var stripped = /controls$/i.test(key) ? key.slice(0, -"controls".length) : key
  stripped = rtrim(stripped)
  return (stripped || "CONTROLS").toUpperCase()
}

// Renderable controls grouped under their class heading, image first since
// that is what gets touched most, and each section ordered by how often a
// control is likely wanted: the look of the picture before the things set
// once. An auto switch sits right before the value it gates. Controls not in
// the table trail in driver order.
var SECTION_ORDER = { IMAGE: 0, CAMERA: 1 }
var CONTROL_ORDER = [
  "brightness", "contrast", "saturation", "sharpness",
  "white_balance_automatic", "white_balance_temperature",
  "gain", "gamma", "hue", "backlight_compensation", "power_line_frequency",
  "auto_exposure", "exposure_time_absolute", "exposure_absolute",
  "focus_automatic_continuous", "focus_auto", "focus_absolute",
  "zoom_absolute", "pan_absolute", "tilt_absolute",
  "exposure_dynamic_framerate", "exposure_auto_priority",
  "led1_mode", "led1_frequency", "privacy"
]

function controlRank(name) {
  var rank = CONTROL_ORDER.indexOf(name)
  return rank === -1 ? CONTROL_ORDER.length : rank
}

function sections(controls) {
  var out = []
  var byTitle = emptyMap()
  var list = Array.isArray(controls) ? controls : []
  for (var i = 0; i < list.length; i++) {
    var ctrl = list[i]
    if (!isRenderable(ctrl)) continue
    var title = sectionTitle(ctrl.section)
    if (!byTitle[title]) {
      byTitle[title] = { title: title, controls: [], order: out.length }
      out.push(byTitle[title])
    }
    byTitle[title].controls.push({ ctrl: ctrl, position: byTitle[title].controls.length })
  }
  out.sort(function(a, b) {
    var ra = has(SECTION_ORDER, a.title) ? SECTION_ORDER[a.title] : 2 + a.order
    var rb = has(SECTION_ORDER, b.title) ? SECTION_ORDER[b.title] : 2 + b.order
    return ra - rb
  })
  for (var s = 0; s < out.length; s++) {
    out[s].controls.sort(function(a, b) {
      return (controlRank(a.ctrl.name) - controlRank(b.ctrl.name)) || (a.position - b.position)
    })
    out[s].controls = out[s].controls.map(function(entry) { return entry.ctrl })
    delete out[s].order
  }
  return out
}

function menuLabel(ctrl, value) {
  if (!ctrl) return ""
  for (var i = 0; i < ctrl.menu.length; i++)
    if (ctrl.menu[i].value === value) return ctrl.menu[i].label
  return String(value)
}

// The value a menu control moves to when stepped by delta, wrapping at the
// ends. Menus can be sparse (auto_exposure offers 1 and 3), so step through
// the listed entries rather than the numeric range.
function menuStep(ctrl, delta) {
  if (!ctrl || ctrl.menu.length === 0) return ctrl ? ctrl.value : null
  var index = 0
  for (var i = 0; i < ctrl.menu.length; i++)
    if (ctrl.menu[i].value === ctrl.value) { index = i; break }
  var next = (index + delta + ctrl.menu.length) % ctrl.menu.length
  return ctrl.menu[next].value
}

// Snap a slider value onto the control's grid and inside its range.
function clampValue(ctrl, value) {
  if (!ctrl || ctrl.min === null || ctrl.max === null) return Math.round(value)
  var step = ctrl.step > 0 ? ctrl.step : 1
  var snapped = ctrl.min + Math.round((value - ctrl.min) / step) * step
  return Math.max(ctrl.min, Math.min(ctrl.max, snapped))
}

// One keyboard nudge (h/l). A single driver step is right for a 0..7 range
// and hopeless for 3..2047, so widen it to about a fortieth of the range,
// kept on the step grid.
function keyStep(ctrl) {
  if (!ctrl || ctrl.min === null || ctrl.max === null) return 1
  var step = ctrl.step > 0 ? ctrl.step : 1
  var span = ctrl.max - ctrl.min
  return Math.max(step, Math.round(span / 40 / step) * step)
}

function valueText(ctrl) {
  if (!ctrl) return ""
  if (ctrl.type === "bool") return ctrl.value ? "On" : "Off"
  if (ctrl.type === "menu" || ctrl.type === "intmenu") return menuLabel(ctrl, ctrl.value)
  return String(ctrl.value)
}

// Controls that switch other controls between automatic and manual go first,
// otherwise the manual value is refused as inactive or overwritten by the
// automatic mode that was still on. Same rule as webcam-ctl's apply.
function isModeControl(name) {
  return /auto/.test(String(name || ""))
}

function applyOrder(values) {
  var names = Object.keys(values || {})
  var modes = names.filter(isModeControl)
  var rest = names.filter(function(n) { return !isModeControl(n) })
  return modes.concat(rest).map(function(n) { return [n, values[n]] })
}

// "Integrated_Webcam_HD: Integrate" is what the Microdia in a Dell reports;
// keep the part before the colon and let the underscores go.
function cameraLabel(name) {
  var text = String(name || "").split(":")[0].replace(/_/g, " ").replace(/\s+/g, " ").trim()
  return text || "Camera"
}

function parseCameraList(json) {
  try {
    var list = JSON.parse(String(json || "[]"))
    return Array.isArray(list) ? list : []
  } catch (e) {
    return []
  }
}

// A few process names read better as the app they belong to.
var APP_NAMES = {
  chromium: "Chromium", chrome: "Chrome", firefox: "Firefox", zoom: "Zoom",
  obs: "OBS", mpv: "mpv", "wf-recorder": "Screen recording", ffmpeg: "ffmpeg",
  "gst-launch-1.0": "GStreamer", cheese: "Cheese", guvcview: "guvcview",
  teams: "Teams", slack: "Slack", discord: "Discord", signal: "Signal"
}

function appLabel(app) {
  var key = String(app || "").trim()
  if (!key) return ""
  var lower = key.toLowerCase()
  for (var known in APP_NAMES)
    if (lower === known || lower.indexOf(known) === 0) return APP_NAMES[known]
  return key
}

function isOff(camera) {
  return !!camera && camera.off === true
}

function canSwitch(camera) {
  return !!camera && (isOff(camera) || !!camera.usb)
}

function statusText(camera) {
  if (!camera) return "No camera connected"
  if (isOff(camera)) return "Off"
  var app = appLabel(camera.app)
  return app ? "In use by " + app : "Ready"
}

if (typeof module !== "undefined") {
  module.exports = {
    parseControls: parseControls,
    parseControlsDetailed: parseControlsDetailed,
    emptyMap: emptyMap,
    rtrim: rtrim,
    MAX_CONTROLS: MAX_CONTROLS,
    MAX_MENU_ITEMS: MAX_MENU_ITEMS,
    isRenderable: isRenderable,
    isEditable: isEditable,
    humanize: humanize,
    label: label,
    sectionTitle: sectionTitle,
    sections: sections,
    menuLabel: menuLabel,
    menuStep: menuStep,
    clampValue: clampValue,
    keyStep: keyStep,
    valueText: valueText,
    isModeControl: isModeControl,
    applyOrder: applyOrder,
    cameraLabel: cameraLabel,
    parseCameraList: parseCameraList,
    appLabel: appLabel,
    isOff: isOff,
    canSwitch: canSwitch,
    statusText: statusText
  }
}
