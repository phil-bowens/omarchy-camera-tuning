#!/bin/bash

# webcam-ctl against a fake v4l2-ctl and udevadm: what it asks the camera for,
# in what order, and what it remembers.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/dev" "$tmp/config"
# video0 captures, video1 is its metadata node, video4 is a v4l2loopback
# virtual camera, video5 a second capture node of the same camera as video0.
touch "$tmp/dev/video0" "$tmp/dev/video1" "$tmp/dev/video4" "$tmp/dev/video5"
export PATH="$tmp/bin:$PATH"
export XDG_CONFIG_HOME="$tmp/config"
export WEBCAM_CTL_DEV_DIR="$tmp/dev"
export FAKE_LOG="$tmp/set.log"
export FAKE_CTRLS="$ROOT/test/fixtures/c920.txt"
# Tools that hang are cut off after this many seconds.
export WEBCAM_CTL_TIMEOUT=2

# video0 captures video, video1 is the metadata node. focus_absolute is refused
# while autofocus is on, the way the kernel refuses an inactive control.
cat >"$tmp/bin/v4l2-ctl" <<'FAKE'
#!/bin/bash
device=""
[[ -n ${FAKE_HANG:-} ]] && exec /bin/sleep 30
while (( $# )); do
  case $1 in
    --device) device=$2; shift 2 ;;
    --info)
      case $device in
        */video0 | */video5)
          printf '\tDriver name      : uvcvideo\n\tCard type        : %s\n\tDevice Caps      : 0x04200001\n\t\tVideo Capture\n' "${FAKE_NAME:-Fake Cam 1000}" ;;
        */video4)
          printf '\tDriver name      : v4l2 loopback\n\tCard type        : OBS Virtual Camera\n\tDevice Caps      : 0x04200001\n\t\tVideo Capture\n' ;;
        *)
          printf '\tDriver name      : uvcvideo\n\tCard type        : Fake Cam 1000\n\tDevice Caps      : 0x04a00000\n\t\tMetadata Capture\n' ;;
      esac
      exit 0 ;;
    --list-ctrls | --list-ctrls-menus)
      if [[ -n ${FAKE_BIG:-} ]]; then
        yes 'brightness 0x00980900 (int)    : min=0 max=255 step=1 default=128 value=128' | head -c 3000000
      else
        cat "$FAKE_CTRLS"
      fi
      exit 0 ;;
    --set-ctrl)
      if [[ $2 == focus_absolute=* ]] && ! grep -q '^focus_automatic_continuous=0$' "$FAKE_LOG" 2>/dev/null; then
        echo "VIDIOC_S_EXT_CTRLS: failed: Permission denied" >&2
        exit 255
      fi
      echo "$2" >>"$FAKE_LOG"
      exit 0 ;;
    *) shift ;;
  esac
done
FAKE

cat >"$tmp/bin/fuser" <<'FAKE'
#!/bin/bash
[[ -n ${FAKE_HANG:-} ]] && exec /bin/sleep 30
[[ -n ${FAKE_USER_PID:-} ]] || exit 1
echo "$FAKE_USER_PID"
FAKE
cat >"$tmp/bin/udevadm" <<'FAKE'
#!/bin/bash
case "$*" in
  *--query=path*--name=*video0*) echo "/devices/pci0000:00/0000:00:14.0/usb1/1-6/1-6:1.0/video4linux/video0" ;;
  *--query=path*--name=*video5*) echo "/devices/pci0000:00/0000:00:14.0/usb1/1-6/1-6:1.2/video4linux/video5" ;;
  *--name=*video0* | *--name=*video5*) echo "ID_SERIAL=${FAKE_SERIAL-FAKE_Cam_1000_ABC123}"; echo "ID_PATH=pci-0000:00:14.0-usb-0:1:1.0" ;;
  *) exit 0 ;;
esac
FAKE
# pkexec stands in for the root step: it logs what root would run and what
# arrives on stdin, then does the one write itself the way `pkexec tee`
# would, or refuses like a canceled prompt.
cat >"$tmp/bin/pkexec" <<'FAKE'
#!/bin/bash
body=$(cat)
echo "$* <<$body" >>"$FAKE_PKEXEC_LOG"
[[ ${FAKE_PKEXEC:-} == cancel ]] && exit 126
[[ $1 == /usr/bin/tee && $2 == -- && -n $3 && $# -eq 3 ]] || exit 1
printf '%s' "$body" >"$3"
FAKE
export FAKE_PKEXEC_LOG="$tmp/pkexec.log"
export WEBCAM_CTL_PKEXEC="$tmp/bin/pkexec"
export WEBCAM_CTL_SYS_DIR="$tmp/sys"
# A USB device in sysfs: its directory, its subsystem link to the USB bus, a
# vendor id and the authorized switch.
usbdev="$tmp/sys/devices/pci0000:00/0000:00:14.0/usb1/1-6"
mkdir -p "$usbdev" "$tmp/sys/bus/usb/drivers/usb"
ln -s "$tmp/sys/bus/usb" "$usbdev/subsystem"
echo 046d >"$usbdev/idVendor"
printf 1 >"$usbdev/authorized"
chmod +x "$tmp/bin/v4l2-ctl" "$tmp/bin/udevadm" "$tmp/bin/fuser" "$tmp/bin/pkexec"

ctl="$ROOT/webcam-ctl"
config="$tmp/config/omarchy/webcam.json"

# --- list ---
listed=$("$ctl" list)
assert_equal "$(jq -c '.' <<<"$listed")" \
  '[{"device":"'"$tmp"'/dev/video0","id":"FAKE_Cam_1000_ABC123","name":"Fake Cam 1000","app":"","usb":"/devices/pci0000:00/0000:00:14.0/usb1/1-6","off":false}]' \
  'list reports one camera: its first capture node, not the metadata node, not the virtual camera, not the second node behind the same serial'
assert_equal "$(FAKE_USER_PID=$$ "$ctl" list | jq -r '.[0].app')" "$(tr -d '\0' </proc/$$/comm)" 'list names the process that has the camera open'

# --- names and ids from the device are data, capped and never paths ---
hostile=$'<img src=x onerror=1>"back\\slash\\" \e[31mred\a\r'
assert_equal "$(FAKE_NAME="$hostile" "$ctl" list | jq -r '.[0].name')" "$(tr -d '\r' <<<"$hostile")" 'a hostile card name comes through as a string, control characters and quotes intact, CR dropped'
assert_equal "$(FAKE_NAME="$(head -c 10000 /dev/zero | tr '\0' n)" "$ctl" list | jq -r '.[0].name | length')" '256' 'a card name is capped at 256 bytes'
assert_equal "$(FAKE_NAME="$(head -c 100000 /dev/zero | tr '\0' n)" "$ctl" list)" '[]' 'a device whose info runs past 64 KiB is not a camera'
assert_equal "$(FAKE_SERIAL='__proto__' "$ctl" list | jq -r '.[0].id')" '__proto__' 'a serial named like a prototype key is only a string'
FAKE_SERIAL='../../etc/passwd' "$ctl" set "$tmp/dev/video0" brightness=1
assert_equal "$(jq -r 'keys[0]' "$tmp/config/omarchy/webcam.json")" '../../etc/passwd' 'a serial shaped like a path is only a JSON key'
assert_equal "$(find "$tmp/config" -type f | wc -l)" '1' '... and nothing was written anywhere but the config file'
rm -f "$tmp/config/omarchy/webcam.json"
assert_equal "$(FAKE_SERIAL='' FAKE_NAME='' "$ctl" list | jq -r '.[0].id')" 'pci-0000:00:14.0-usb-0:1:1.0' 'a camera without a serial is known by its bus path'

# --- controls: capped in bytes, cut listings marked, only video nodes ---
assert_equal "$("$ctl" controls "$tmp/dev/video0" | wc -c)" "$(( $(wc -c <"$FAKE_CTRLS") ))" 'controls prints the listing as v4l2-ctl gives it'
big=$(FAKE_BIG=1 "$ctl" controls "$tmp/dev/video0")
assert_equal "$(tail -n1 <<<"$big")" '# truncated' 'a listing over the cap ends with the truncation marker'
assert "... and is at most the cap plus the marker" test "$(wc -c <<<"$big")" -le $((256 * 1024 + 14))
"$ctl" controls /etc/passwd 2>/dev/null && fail 'controls refuses a path that is not a video node'
pass 'controls refuses a path that is not a video node'
"$ctl" set "$tmp/dev/../etc/passwd" brightness=1 2>/dev/null && fail 'set refuses a path that is not a video node'
pass 'set refuses a path that is not a video node'

# --- deadlines: a hung tool ends with the tool, not with the shell waiting ---
SECONDS=0
FAKE_HANG=1 "$ctl" list >"$tmp/hung.out" 2>/dev/null || true
assert 'list with a hung v4l2-ctl returns within one deadline per node' test "$SECONDS" -lt 16
assert_equal "$(cat "$tmp/hung.out")" '[]' '... and lists nothing rather than something made up'
SECONDS=0
FAKE_HANG=1 "$ctl" controls "$tmp/dev/video0" >/dev/null 2>&1 && fail 'controls with a hung v4l2-ctl exits non-zero'
pass 'controls with a hung v4l2-ctl exits non-zero'
assert '... within the deadline' test "$SECONDS" -lt 8

# --- set and saved ---
assert_equal "$("$ctl" saved "$tmp/dev/video0")" '{}' 'saved is empty before anything is set'

"$ctl" set "$tmp/dev/video0" brightness=130
assert_equal "$(tail -n1 "$FAKE_LOG")" 'brightness=130' 'set passes the assignment to v4l2-ctl'
assert_equal "$(jq -c '.' "$config")" \
  '{"FAKE_Cam_1000_ABC123":{"name":"Fake Cam 1000","controls":{"brightness":130}}}' \
  'set remembers the control under the camera id with its name'

"$ctl" set "$tmp/dev/video0" brightness=140
assert_equal "$("$ctl" saved "$tmp/dev/video0")" '{"brightness":140}' 'setting again replaces the remembered value'

if "$ctl" set "$tmp/dev/video0" 'brightness=1;rm' 2>/dev/null; then
  fail 'set refuses a malformed assignment'
fi
pass 'set refuses a malformed assignment'

# A refused set must not be remembered.
"$ctl" set "$tmp/dev/video0" focus_absolute=40 2>/dev/null && fail 'set exits non-zero when the camera refuses'
pass 'set exits non-zero when the camera refuses'
assert_equal "$("$ctl" saved "$tmp/dev/video0")" '{"brightness":140}' 'a refused control is not remembered'

# --- the config file: a directory or a FIFO in its place is never written through ---
mv "$config" "$config.keep"; mkdir "$config"
"$ctl" set "$tmp/dev/video0" brightness=5 2>/dev/null && fail 'set fails when the config path is a directory'
pass 'set fails when the config path is a directory'
assert_equal "$(ls -A "$config" | wc -l)" '0' '... and leaves nothing inside it'
rmdir "$config"; mkfifo "$config"
"$ctl" set "$tmp/dev/video0" brightness=5
assert 'a FIFO at the config path is replaced by a regular file, without reading it' test -f "$config"
rm -f "$config"; mv "$config.keep" "$config"

# --- apply: mode switches first, one call each, failures reported but not fatal to the rest ---
"$ctl" set "$tmp/dev/video0" focus_automatic_continuous=0
"$ctl" set "$tmp/dev/video0" focus_absolute=40
"$ctl" set "$tmp/dev/video0" auto_exposure=1
"$ctl" set "$tmp/dev/video0" exposure_time_absolute=300
: >"$FAKE_LOG"
"$ctl" apply "$tmp/dev/video0"
applied=$(paste -sd' ' "$FAKE_LOG")
assert_equal "$(cut -d' ' -f1-2 <<<"$applied" | tr ' ' '\n' | sort | paste -sd' ')" \
  'auto_exposure=1 focus_automatic_continuous=0' \
  'apply sets the two mode switches before anything else'
assert_equal "$(wc -l <"$FAKE_LOG" | tr -d ' ')" '5' 'apply sets every remembered control in its own call'

# With autofocus back on, the remembered focus is refused: apply reports it and still sets the rest.
: >"$FAKE_LOG"
jq '.FAKE_Cam_1000_ABC123.controls.focus_automatic_continuous = 1' "$config" >"$config.new" && mv "$config.new" "$config"
if "$ctl" apply "$tmp/dev/video0" 2>"$tmp/apply.err"; then
  fail 'apply exits non-zero when a control is refused'
fi
pass 'apply exits non-zero when a control is refused'
assert 'apply names the refused control on stderr' grep -q 'refused focus_absolute=40' "$tmp/apply.err"
assert 'apply still sets the controls after a refused one' grep -q '^brightness=140$' "$FAKE_LOG"

# apply with no device covers every camera.
: >"$FAKE_LOG"
"$ctl" apply || true
assert 'apply without a device covers the listed cameras' grep -q '^brightness=140$' "$FAKE_LOG"

# --- reset: defaults, mode switches first, then nothing remembered ---
: >"$FAKE_LOG"
"$ctl" reset "$tmp/dev/video0"
assert_equal "$(head -n1 "$FAKE_LOG" | cut -d= -f1 | grep -c auto)" '1' 'reset starts with a mode switch'
assert 'reset sets the camera default for a range' grep -q '^brightness=128$' "$FAKE_LOG"
assert 'reset sets the camera default for a menu' grep -q '^power_line_frequency=2$' "$FAKE_LOG"
assert_equal "$("$ctl" saved "$tmp/dev/video0")" '{}' 'reset forgets the remembered controls'
assert_equal "$(jq -c '.' "$config")" '{}' 'reset leaves the config without that camera'

# --- watch: a device appearing and a wake from sleep, through fake producers ---
"$ctl" set "$tmp/dev/video0" brightness=150
cat >"$tmp/bin/stdbuf" <<'FAKE'
#!/bin/bash
shift
exec "$@"
FAKE
cat >"$tmp/bin/inotifywait" <<'FAKE'
#!/bin/bash
case ${FAKE_WATCH:-events} in
  block) exec /bin/sleep "$FAKE_TAG" ;;
  storm) while :; do echo "usb CREATE $WEBCAM_CTL_DEV_DIR/bus/usb/001/009"; /bin/sleep 0.05; done ;;
esac
if [[ $* == *bus/usb* ]]; then
  echo "usb DELETE $WEBCAM_CTL_DEV_DIR/bus/usb/001/007"
  exit 0
fi
echo "dev CREATE $WEBCAM_CTL_DEV_DIR/video0"
echo "dev CREATE $WEBCAM_CTL_DEV_DIR/video1"
echo "dev DELETE $WEBCAM_CTL_DEV_DIR/video0"
echo "dev CREATE $WEBCAM_CTL_DEV_DIR/tty7"
FAKE
mkdir -p "$tmp/dev/bus/usb/001"
cat >"$tmp/bin/gdbus" <<'FAKE'
#!/bin/bash
[[ ${FAKE_WATCH:-events} == events ]] || exec /bin/sleep "$FAKE_TAG"
sleep 0.3
echo "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)"
echo "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)"
FAKE
cat >"$tmp/bin/sleep" <<'FAKE'
#!/bin/bash
exit 0
FAKE
chmod +x "$tmp/bin/stdbuf" "$tmp/bin/inotifywait" "$tmp/bin/gdbus" "$tmp/bin/sleep"
: >"$FAKE_LOG"
watched=$(timeout 10 "$ctl" watch 2>/dev/null | paste -sd' ')
assert_equal "$(tr ' ' '\n' <<<"$watched" | sort | paste -sd' ')" "$(printf '%s\n' "added" "$tmp/dev/video0" "removed" "$tmp/dev/video0" "changed" "resumed" | sort | paste -sd' ')" \
  'watch reports the capture node appearing and going, a USB change, and the wake, and ignores the rest'
assert_equal "$(grep -c '^brightness=150$' "$FAKE_LOG")" '2' 'watch re-applies remembered controls on plug-in and on wake'

# Teardown: a TERM to the watcher takes every producer with it; so does the
# watcher's own disappearance; and a reader that went away ends the loop even
# with SIGPIPE ignored, which is how the shell's systemd unit runs it.
export FAKE_TAG="299.$$"
FAKE_WATCH=block "$ctl" watch >/dev/null 2>&1 &
watcher=$!
/bin/sleep 0.6
assert 'blocking producers are running' test "$(pgrep -fc "sleep $FAKE_TAG")" -ge 2
kill -TERM "$watcher"
for _ in $(seq 30); do pgrep -f "sleep $FAKE_TAG" >/dev/null || break; /bin/sleep 0.1; done
assert_equal "$(pgrep -fc "sleep $FAKE_TAG" || true)" '0' 'TERM to watch ends every producer within 3 s'
wait "$watcher" 2>/dev/null || true
FAKE_WATCH=block "$ctl" watch >/dev/null 2>&1 &
watcher=$!
disown "$watcher"
/bin/sleep 0.6
kill -KILL "$watcher"
for _ in $(seq 60); do pgrep -f "sleep $FAKE_TAG" >/dev/null || break; /bin/sleep 0.1; done
assert_equal "$(pgrep -fc "sleep $FAKE_TAG" || true)" '0' 'a watcher killed outright loses its producers within 6 s'
wait "$watcher" 2>/dev/null || true
SECONDS=0
(trap '' PIPE; exec timeout 8 "$ctl" watch 2>/dev/null) | head -n1 >/dev/null
assert 'a reader that closes ends watch even with SIGPIPE ignored' test "$SECONDS" -lt 5
for _ in $(seq 30); do pgrep -f "sleep 0.05" >/dev/null || break; /bin/sleep 0.1; done

# --- off and on: one root write each, the camera stays listed while off ---
authorized="$tmp/sys/devices/pci0000:00/0000:00:14.0/usb1/1-6/authorized"
"$ctl" set "$tmp/dev/video0" brightness=90
"$ctl" off "$tmp/dev/video0"
assert_equal "$(cat "$authorized")" '0' 'off writes 0 to the USB device authorized file'
assert_equal "$(tail -n1 "$FAKE_PKEXEC_LOG")" "/usr/bin/tee -- $authorized <<0" 'off reaches root only as tee on the validated authorized file, with 0 on stdin'
assert_equal "$(jq -c '.FAKE_Cam_1000_ABC123 | {off, usb, controls}' "$config")" \
  '{"off":true,"usb":"/devices/pci0000:00/0000:00:14.0/usb1/1-6","controls":{"brightness":90}}' \
  'off records the port and keeps the remembered controls'
# De-authorizing takes every node of the device with it.
mv "$tmp/dev/video0" "$tmp/dev/video0.gone"; mv "$tmp/dev/video5" "$tmp/dev/video5.gone"
assert_equal "$("$ctl" list | jq -c '.[0] | {device, id, off}')" '{"device":"","id":"FAKE_Cam_1000_ABC123","off":true}' 'an off camera stays listed without a device'
"$ctl" on FAKE_Cam_1000_ABC123
assert_equal "$(cat "$authorized")" '1' 'on writes 1 to the authorized file'
assert_equal "$(tail -n1 "$FAKE_PKEXEC_LOG")" "/usr/bin/tee -- $authorized <<1" 'on is the same tee with 1 on stdin'
mv "$tmp/dev/video0.gone" "$tmp/dev/video0"; mv "$tmp/dev/video5.gone" "$tmp/dev/video5"
assert_equal "$(jq -c '.FAKE_Cam_1000_ABC123.off' "$config")" 'null' 'on clears the off mark'
assert_equal "$("$ctl" list | jq -c '.[0].off')" 'false' 'a camera switched back on lists as on'

# A canceled prompt leaves everything as it was.
FAKE_PKEXEC=cancel "$ctl" off "$tmp/dev/video0" 2>/dev/null && fail 'off fails when the prompt is canceled'
pass 'off fails when the prompt is canceled'
assert_equal "$(cat "$authorized")" '1' 'a canceled off leaves the camera authorized'
assert_equal "$(jq -c '.FAKE_Cam_1000_ABC123.off' "$config")" 'null' 'a canceled off leaves no off mark'

# Unplugged while off: the port is empty, so the camera is neither listed nor marked.
"$ctl" off "$tmp/dev/video0"
mv "$tmp/dev/video0" "$tmp/dev/video0.gone"; mv "$tmp/dev/video5" "$tmp/dev/video5.gone"
mv "$tmp/sys/devices/pci0000:00/0000:00:14.0/usb1/1-6" "$tmp/sys/devices/pci0000:00/0000:00:14.0/usb1/1-6.gone"
assert_equal "$("$ctl" list)" '[]' 'an off camera whose port is empty is not listed'
assert_equal "$(jq -c '.FAKE_Cam_1000_ABC123.off' "$config")" 'null' 'and its off mark is cleared'
mv "$tmp/sys/devices/pci0000:00/0000:00:14.0/usb1/1-6.gone" "$tmp/sys/devices/pci0000:00/0000:00:14.0/usb1/1-6"
printf 1 >"$authorized"
mv "$tmp/dev/video0.gone" "$tmp/dev/video0"; mv "$tmp/dev/video5.gone" "$tmp/dev/video5"

# The kernel authorizes everything at boot: a camera marked off that is present is on.
jq '.FAKE_Cam_1000_ABC123.off = true' "$config" >"$config.new" && mv "$config.new" "$config"
assert_equal "$("$ctl" list | jq -c '.[0].off')" 'false' 'list drops the off mark of a camera that is back'
assert_equal "$(jq -c '.FAKE_Cam_1000_ABC123.off' "$config")" 'null' 'and forgets the mark'

# Nothing but a USB device's own authorized file ever reaches the root step:
# not a path with .., not a Thunderbolt device (it has an authorized file
# too), not another device reached through one of sysfs's links.
prompts=$(wc -l <"$FAKE_PKEXEC_LOG")
refuse_port() {
  jq --arg usb "$1" '.FAKE_Cam_1000_ABC123.usb = $usb' "$config" >"$config.new" && mv "$config.new" "$config"
  "$ctl" on FAKE_Cam_1000_ABC123 2>/dev/null && fail "$2"
  pass "$2"
}
refuse_port "/etc/../devices/evil" 'on refuses a remembered port with .. in it'
tb="$tmp/sys/devices/pci0000:00/0000:00:07.0/domain0/0-0/0-1"
mkdir -p "$tb" "$tmp/sys/bus/thunderbolt"; ln -s "$tmp/sys/bus/thunderbolt" "$tb/subsystem"; printf 0 >"$tb/authorized"
refuse_port "/devices/pci0000:00/0000:00:07.0/domain0/0-0/0-1" 'on refuses a Thunderbolt device, USB port name or not'
other="$tmp/sys/devices/pci0000:00/0000:00:14.0/usb1/1-10"
mkdir -p "$other"; ln -s "$tmp/sys/bus/usb" "$other/subsystem"; echo 1234 >"$other/idVendor"; printf 1 >"$other/authorized"
ln -s "$other" "$tmp/sys/bus/usb/drivers/usb/1-10"; ln -s "$tmp/sys/bus/usb/drivers/usb" "$usbdev/driver"
refuse_port "/devices/pci0000:00/0000:00:14.0/usb1/1-6/driver/1-10" 'on refuses a device reached through a sysfs link'
nov="$tmp/sys/devices/pci0000:00/0000:00:14.0/usb1/1-11"
mkdir -p "$nov"; ln -s "$tmp/sys/bus/usb" "$nov/subsystem"; printf 1 >"$nov/authorized"
refuse_port "/devices/pci0000:00/0000:00:14.0/usb1/1-11" 'on refuses a USB directory without a vendor id'
assert_equal "$(wc -l <"$FAKE_PKEXEC_LOG")" "$prompts" 'none of the refused ports reached pkexec'
assert_equal "$(cat "$other/authorized")" '1' 'the other device is untouched'
