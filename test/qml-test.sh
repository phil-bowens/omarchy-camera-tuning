#!/bin/bash

# Every Text in the QML sets PlainText: names, labels and process names come
# from a device or a process, and AutoText would read markup in them.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

for file in Panel.qml Preview.qml Service.qml; do
  texts=$(grep -cE '^\s*Text \{' "$ROOT/$file" || true)
  plain=$(grep -c 'textFormat: Text.PlainText' "$ROOT/$file" || true)
  assert_equal "$plain" "$texts" "$file: every Text sets PlainText ($texts)"
done

assert 'no QML spawns a tool by a bare name' test -z "$(grep -nE 'command: \[\s*"(v4l2-ctl|fuser|udevadm|pkexec)' "$ROOT"/*.qml || true)"
assert 'the only pkexec is tee on a fixed path' test "$(grep -c 'PKEXEC" "$TEE"' "$ROOT/webcam-ctl")" -eq 1
assert 'webcam-ctl never runs itself as root' test -z "$(grep -n 'realpath "\$0"\|authorize)' "$ROOT/webcam-ctl" || true)"
