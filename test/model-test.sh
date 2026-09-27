#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const model = requireFromRoot('Model.js')

// Fixtures are real `v4l2-ctl --list-ctrls-menus` output: a Logitech C920 and
// the Microdia module in a Dell Inspiron.
const c920 = model.parseControls(readFixture('c920.txt'))
const microdia = model.parseControls(readFixture('microdia.txt'))

assertEqual(c920.length, 17, 'c920 lists 17 controls')
assertEqual(microdia.length, 16, 'microdia lists 16 controls')

const brightness = c920.find(c => c.name === 'brightness')
assertDeepEqual(
  [brightness.type, brightness.min, brightness.max, brightness.step, brightness.defaultValue, brightness.value, brightness.section],
  ['int', 0, 255, 1, 128, 128, 'User Controls'],
  'an int control carries its range, default, value and class'
)

const wb = c920.find(c => c.name === 'white_balance_temperature')
assert(wb.inactive, 'a control flagged inactive is parsed as inactive')
assertDeepEqual(wb.flags, ['inactive', 'has-min-max'], 'flags split on the comma')
assert(!model.isEditable(wb), 'an inactive control is not editable')
assert(model.isRenderable(wb), 'an inactive control still renders')

const autoWb = c920.find(c => c.name === 'white_balance_automatic')
assertDeepEqual([autoWb.type, autoWb.min, autoWb.max, autoWb.value], ['bool', 0, 1, 1], 'a bool control gets a 0..1 range')

const plf = c920.find(c => c.name === 'power_line_frequency')
assertDeepEqual(plf.menu, [{ value: 0, label: 'Disabled' }, { value: 1, label: '50 Hz' }, { value: 2, label: '60 Hz' }], 'menu entries follow their control')
assertEqual(plf.valueLabel, '60 Hz', 'the current menu label is kept')

const ae = c920.find(c => c.name === 'auto_exposure')
assertDeepEqual(ae.menu.map(m => m.value), [1, 3], 'a sparse menu keeps only the entries the camera lists')
assertEqual(ae.section, 'Camera Controls', 'controls after a class heading are tagged with it')
assertEqual(model.menuStep(ae, 1), 1, 'stepping a sparse menu forward wraps to the first entry')
assertEqual(model.menuStep(ae, -1), 1, 'stepping a sparse menu backward from 3 lands on 1')
assertEqual(model.menuStep(plf, 1), 0, 'stepping past the last menu entry wraps')
assertEqual(model.menuStep(plf, -1), 1, 'stepping back goes to the previous entry')
assertEqual(model.menuLabel(plf, 1), '50 Hz', 'menu labels resolve by value')

const rect = microdia.find(c => c.name === 'region_of_interest_rectangle')
const bitmask = microdia.find(c => c.name === 'region_of_interest_auto_ctrls')
assertEqual(rect.type, 'rect', 'a rect control is parsed')
assertEqual(bitmask.type, 'bitmask', 'a bitmask control is parsed')
assert(!model.isRenderable(rect) && !model.isRenderable(bitmask), 'rect and bitmask controls are not rendered')

const c920Sections = model.sections(c920)
assertDeepEqual(c920Sections.map(s => s.title), ['IMAGE', 'CAMERA'], 'the image class comes first, then camera')
assertDeepEqual(c920Sections.map(s => s.controls.length), [9, 8], 'c920 sections hold every control')
assertDeepEqual(
  c920Sections[0].controls.map(c => c.name),
  ['brightness', 'contrast', 'saturation', 'sharpness', 'white_balance_automatic', 'white_balance_temperature', 'gain', 'backlight_compensation', 'power_line_frequency'],
  'image controls run from the look of the picture to the things set once, auto switch before its value'
)
assertDeepEqual(
  c920Sections[1].controls.map(c => c.name),
  ['auto_exposure', 'exposure_time_absolute', 'focus_automatic_continuous', 'focus_absolute', 'zoom_absolute', 'pan_absolute', 'tilt_absolute', 'exposure_dynamic_framerate'],
  'camera controls put exposure and focus before the frame-rate switch'
)
assertDeepEqual(model.sections(microdia).map(s => s.controls.length), [11, 3], 'microdia sections leave out the two unrenderable controls')
assertDeepEqual(
  model.sections([{ name: 'zzz_custom', type: 'int', section: 'User Controls' }, { name: 'aaa_custom', type: 'int', section: 'User Controls' }, { name: 'brightness', type: 'int', section: 'User Controls' }]).map(s => s.controls.map(c => c.name)),
  [['brightness', 'zzz_custom', 'aaa_custom']],
  'unknown controls trail in driver order')
assertDeepEqual(
  model.sections([{ name: 'a', type: 'int', section: 'Codec Controls' }, { name: 'b', type: 'int', section: 'User Controls' }]).map(s => s.title),
  ['IMAGE', 'CODEC'],
  'other classes follow the two known ones')
assertEqual(model.sectionTitle('Codec Controls'), 'CODEC', 'other classes drop the word Controls')

assertEqual(model.label('exposure_dynamic_framerate'), 'Dynamic frame rate', 'known controls have a plain label')
assertEqual(model.label('focus_automatic_continuous'), 'Autofocus', 'autofocus is named as such')
assertEqual(model.label('led1_mode'), 'LED', 'vendor controls in the table are labeled')
assertEqual(model.label('some_new_control_absolute'), 'Some new control', 'unknown controls are humanized')

const focus = c920.find(c => c.name === 'focus_absolute')
assertEqual(model.clampValue(focus, 43), 45, 'values snap to the control step')
assertEqual(model.clampValue(focus, 999), 250, 'values clamp to the maximum')
assertEqual(model.clampValue(focus, -5), 0, 'values clamp to the minimum')
const pan = c920.find(c => c.name === 'pan_absolute')
assertEqual(model.clampValue(pan, -1000), 0, 'a coarse step snaps to the nearest grid point')
assertEqual(model.clampValue(pan, -2000), -3600, 'a coarse step rounds away when past halfway')

const exposure = c920.find(c => c.name === 'exposure_time_absolute')
assertEqual(model.keyStep(exposure), 51, 'a wide range gets a wide keyboard step')
assertEqual(model.keyStep(focus), 5, 'a stepped range never nudges below one step')
const gain = microdia.find(c => c.name === 'gain')
assertEqual(model.keyStep(gain), 1, 'a tiny range nudges by one')

assertEqual(model.valueText(autoWb), 'On', 'bool values read On or Off')
assertEqual(model.valueText(plf), '60 Hz', 'menu values read as their label')
assertEqual(model.valueText(brightness), '128', 'int values read as numbers')

assertDeepEqual(
  model.applyOrder({ exposure_time_absolute: 300, brightness: 100, auto_exposure: 1, focus_absolute: 40, focus_automatic_continuous: 0 }),
  [['auto_exposure', 1], ['focus_automatic_continuous', 0], ['exposure_time_absolute', 300], ['brightness', 100], ['focus_absolute', 40]],
  'mode switches are applied before the values they gate'
)

assertEqual(model.cameraLabel('Integrated_Webcam_HD: Integrate'), 'Integrated Webcam HD', 'camera names lose the bus suffix and underscores')
assertEqual(model.cameraLabel('HD Pro Webcam C920'), 'HD Pro Webcam C920', 'clean camera names pass through')
assertEqual(model.cameraLabel(''), 'Camera', 'an empty name falls back to Camera')

assertDeepEqual(model.parseCameraList('[{"id":"a","device":"/dev/video0","name":"Cam"}]')[0].device, '/dev/video0', 'camera lists parse')
assertDeepEqual(model.parseCameraList('nonsense'), [], 'a bad camera list is empty, not an exception')

assertEqual(model.statusText(null), 'No camera connected', 'no camera has its own status')
assertEqual(model.statusText({ id: 'a', app: '' }), 'Ready', 'an idle camera is ready')
assertEqual(model.statusText({ id: 'a', app: 'chromium' }), 'In use by Chromium', 'a camera in use names the app')
assertEqual(model.appLabel('wf-recorder'), 'Screen recording', 'the screen recorder reads as what it is')
assertEqual(model.appLabel('someapp'), 'someapp', 'unknown process names pass through')
assertEqual(model.statusText({ id: 'a', off: true }), 'Off', 'a switched-off camera reads Off')
assert(model.isOff({ off: true }) && !model.isOff({ off: false }) && !model.isOff(null), 'isOff follows the off flag')
assert(model.canSwitch({ usb: '/devices/x/1-6' }) && model.canSwitch({ off: true, usb: '' }) && !model.canSwitch({ usb: '' }), 'only USB cameras, or cameras already off, get a switch')

// Bounds: one enormous line, a listing of thousands of controls, a menu of
// hundreds, the helper's truncation marker, all handled in bounded time and
// reported as a cut listing.
const header = 'brightness 0x00980900 (int)    : min=0 max=255 step=1 default=128 value=128'
let t0 = Date.now()
let one = model.parseControlsDetailed(header + ' '.repeat(256 * 1024))
assert(Date.now() - t0 < 200, 'a 256 KiB line parses in under 200 ms')
assertEqual(one.controls.length, 1, '... and still yields its control')
t0 = Date.now()
assertEqual(model.sectionTitle('Codec' + ' '.repeat(80000) + 'Controls'), 'CODEC', 'a class name padded with 80,000 spaces is titled in bounded time')
assert(Date.now() - t0 < 200, '... in under 200 ms')
const many = model.parseControlsDetailed(Array(300).fill(header).join('\n'))
assertEqual(many.controls.length, model.MAX_CONTROLS, 'a listing of 300 controls stops at the control cap')
assert(many.truncated, '... and is reported as truncated')
const menu = model.parseControlsDetailed('power_line_frequency 0x00980918 (menu)   : min=0 max=2 default=2 value=2\n' + Array.from({ length: 100 }, (_, i) => `\t\t\t\t${i}: item ${i}`).join('\n'))
assertEqual(menu.controls[0].menu.length, model.MAX_MENU_ITEMS, 'a menu of 100 entries stops at the menu cap')
assert(menu.truncated, '... and is reported as truncated')
const marked = model.parseControlsDetailed(header + '\n# truncated\n' + header)
assertEqual(marked.controls.length, 1, "webcam-ctl's marker ends the listing")
assert(marked.truncated, '... and marks it truncated')
assert(!model.parseControlsDetailed(readFixture('c920.txt')).truncated, 'a real listing is not truncated')
assertEqual(model.parseControls('\x80'.repeat(1000) + '\n' + 'x'.repeat(5000000)).length, 0, 'garbage yields no controls and no exception')

// Driver-named keys never reach a prototype.
const odd = model.parseControlsDetailed('constructor 0x00980900 (int)    : min=0 max=1 step=1 default=0 value=0\n__proto__ 0x00980901 (bool)   : default=0 value=0')
assertDeepEqual(odd.controls.map(c => model.label(c.name)), ['Constructor', 'Proto'], 'controls named like prototype keys get plain labels')
assert(odd.controls.every(model.isRenderable), '... and render')
assertDeepEqual(model.sections([{ name: 'a', type: 'int', section: 'constructor' }]).map(s => s.title), ['CONSTRUCTOR'], 'a class named constructor is a section like any other')
const map = model.emptyMap()
assert(map.constructor === undefined && map.__proto__ === undefined, 'emptyMap has no prototype keys')
assert(!model.isRenderable({ type: 'constructor' }), 'a type named constructor is not renderable')
JS
