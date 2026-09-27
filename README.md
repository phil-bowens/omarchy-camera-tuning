# Camera tuning

A camera button in the bar. The switch beside the camera's name turns it off for real: the USB device is de-authorized, so it disappears from the system, its light goes out and no app can open it, until you switch it back on. The panel below holds whatever the camera reports it can do: brightness, contrast, white balance, exposure mode and time, autofocus and focus, zoom, pan and tilt, the power line filter, and on cameras that have it, the dynamic frame rate switch (off keeps the frame rate fixed in low light). Rows run from what gets touched most to what is set once. Switches for on/off controls, a slider for each range, a row that steps through the entries of a menu.

Anything you change is remembered for that camera and put back when it is plugged in again, on another port too, and after the machine wakes from sleep. Nothing is stored that the camera did not offer, and one button takes a camera back to its own defaults.

## Install

```bash
omarchy plugin add https://github.com/phil-bowens/omarchy-camera-tuning.git --enable
```

The button lands in the bar's right section. The panel also answers to a keybinding, for example in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + C", "Camera tuning", "omarchy-shell io.github.phil-bowens.camera-tuning toggle")
```

Needs `v4l-utils`, `jq`, `inotify-tools`, `psmisc`, `polkit`, `coreutils` and, for the preview, `qt6-multimedia`, all present on a stock Omarchy install. To remove it: `omarchy plugin remove io.github.phil-bowens.camera-tuning`; the settings file described below is left in place, and a camera switched off comes back on at the next boot.

The line under the camera's name says whether it is free ("Ready"), which app has it open ("In use by Chromium"), or that it is off.

The eye button in the header shows the camera's picture under its name, drawn by the shell itself, so a slider can be watched as it moves. It is off until asked for, stops with the button or when the panel closes, and says so if another app has the camera. Starting a stream is what makes some cameras recompute their exposure, so the picture may settle for a second.

The switch in the header turns a USB camera off for real: the device is de-authorized, so it disappears from the system, its light goes out and no app can open it. That is a root operation, so polkit asks for your password each way, in the same dialog Omarchy uses for its DNS switch. An off camera stays listed so it can be switched back on, and comes back on its own at the next boot, because the kernel authorizes every USB device as it is found (unless an administrator has set `authorized_default` otherwise). Cameras that are not USB devices have no switch. If the camera is unplugged and something else is plugged into the same port while the password prompt is open, that device is what gets switched; replugging it switches it back.

## Keys

In the panel: j/k or the arrows move between controls, h/l nudge a slider, flip a switch or step a menu, Enter flips or steps, Tab moves to the next panel, Escape closes. Right-click on a menu row steps backwards. The restore button in the header goes back to camera defaults. The mouse wheel always scrolls the panel, sliders included; a slider is moved by dragging it or with h/l.

Controls the camera has switched off, such as manual focus while autofocus is on, or white balance while it is automatic, show dimmed until the switch above them is turned off.

## What is stored

`~/.config/omarchy/webcam.json`, one entry per camera, keyed by the camera's USB serial string (the same one `/dev/v4l/by-id` uses), holding the camera's name and only the controls you changed:

```json
{
  "046d_HD_Pro_Webcam_C920_21C6D69F": {
    "name": "HD Pro Webcam C920",
    "controls": { "focus_automatic_continuous": 0, "focus_absolute": 40 }
  }
}
```

A camera that has been switched off also carries its USB port (`usb`) and `off: true` until it is switched on again.

Delete a camera's entry, or press the restore button, and it is back to what the camera does on its own.

## How it works

`webcam-ctl` is the whole backend: `list`, `controls`, `saved`, `set`, `apply`, `reset`, `off`, `on` and `watch`. The panel runs `set` for each change and re-reads the camera afterward, since cameras round, clamp and occasionally ignore what they are given. The service runs `apply` when the shell starts and keeps `watch` running, which reports cameras appearing in `/dev` and the wake from sleep, applying remembered controls on both. Controls are applied one call each, mode switches first: the kernel applies a batch atomically, so a single value the camera refuses would take the rest down with it.

The panel is the shape of Omarchy's own Audio and Bluetooth panels and uses only the shell's theme tokens.

### The root step

Switching a camera off or on is the only thing that runs as root, and what runs is `tee`:

```
printf 0 | /usr/bin/pkexec /usr/bin/tee -- /sys/devices/…/1-6/authorized
```

Nothing from the plugin's directory executes as root. `webcam-ctl` builds and checks the path before the prompt: it must sit under `/sys/devices`, be reached without following a link, be named like a USB port, have a `subsystem` link to the USB bus and carry a vendor id (Thunderbolt devices have an `authorized` file too and do not pass). The polkit dialog shows that exact command. polkit's default for `pkexec` is an administrator's password each time; a system that grants more (a member of the `empower` group, say) will not be asked. Nothing is written under `/etc`, no rule or policy file is installed, and the switch reverts at boot.

### What runs in the background

The service keeps `webcam-ctl watch` running for the life of the shell: two `inotifywait` processes (on `/dev` and `/dev/bus/usb`) and one `gdbus monitor` on logind. They report only that a video node came or went, that something changed on the USB bus, or that the machine woke. If the watcher dies the service starts it again after 5 seconds, doubling the wait up to 10 minutes while it keeps failing, and back to 5 seconds after a healthy run. A TERM to the watcher ends its producers with it; if the shell disappears without one, they notice within a few seconds and leave. While the panel is open, `list` runs every 3 seconds so the "In use by" line stays honest; it may rewrite the settings file when a camera marked off turns out to be back. Nothing else runs while the panel is closed.

### Bounds

Every call into `v4l2-ctl`, `udevadm` and `fuser` runs under a 10 second deadline in its own process group; a wedged camera makes the tool hang, not the shell. The control listing reaching the shell is capped at 256 KiB by the helper, and the panel keeps at most 256 controls and 64 entries per menu; a listing cut anywhere is shown with "Control list cut short", never as a shorter camera. The camera list is capped at 128 cameras and 256 KiB. A camera's name, its id and the name of the process using it are capped at 256 bytes (the kernel's own limits are 32 bytes for a name and 15 for a process name; the process name is the one the process gave itself). Only paths of the form `/dev/videoN` are ever handed to a tool. Every string from a device or a process is drawn as plain text. The settings file is written as a temp file in the same directory then renamed, mode 0600, never when the result is empty, and never through a directory or a FIFO in its place. There are no PID files and nothing under `/tmp`.

## Tests

```bash
test/all
```

`model-test.sh` runs the parser and the small pure functions under node against real `v4l2-ctl --list-ctrls-menus` output from a Logitech C920 and a Microdia laptop module, plus the bounds: a 256 KiB line, 300 controls, a 100-entry menu, the truncation marker, controls named like prototype keys. `webcam-ctl-test.sh` runs the script against fake tools: a `v4l2-ctl` that refuses an inactive control the way the kernel does, hangs on demand, or prints megabytes; hostile names and serials; a `pkexec` that records what root would run and what arrives on stdin; a fake sysfs with a Thunderbolt device, a device behind a `driver/` link and a device without a vendor id, none of which reach the prompt; the settings path as a directory and as a FIFO; and the watcher's teardown on TERM, on KILL and on a reader that went away with SIGPIPE ignored. `qml-test.sh` checks that every `Text` sets PlainText and that no QML spawns a tool by a bare name.

## Neighbors

Other plugins cover parts of this. [Webcam Controls](https://github.com/kristoferlund/omarchy-webcam) is a clean control panel with a preview and remembers nothing. [ninepointlabs' Webcam](https://github.com/ninepointlabs/omarchy-webcam) remembers controls per camera and picks the PipeWire default camera, polling for changes. [Privacy Controls](https://github.com/GrootAiInfinity/omarchy-privacy) switches a camera off through a udev rule that survives reboots, at the cost of a one-time root installer. [LensGuard](https://github.com/Shirak-Semonian/lensguard-omarchy-plugin) watches who opens the camera and alerts. This plugin is the one that does the everyday set in one panel: controls remembered and put back on plug-in and on wake, an off switch with nothing installed under /etc, a preview, and who has the camera.

## Limits

Cameras the kernel presents through V4L2 are what this works with, which is every USB webcam. Laptops with MIPI cameras that go through libcamera show no camera here, as they show none to Omarchy's screen recorder. Vendor extras that live outside the standard controls, such as Logitech LED modes or the Kiyo Pro's HDR, are not shown, since the driver does not offer them. Virtual cameras from OBS or v4l2loopback are left out of the list, and a camera with two capture nodes, such as one with an infrared sensor, is listed once.

## Notes

Cameras do not always honor what they report. A Logitech C920 recomputes its exposure time when a stream starts, and the driver reads `exposure_dynamic_framerate` as 0 whatever the camera is doing. The panel shows what the camera says; measure with `v4l2-ctl --stream-mmap --stream-count=120` when it matters.

Built against the Omarchy 4.0.4 shell. MIT license. Built with Claude Code.
