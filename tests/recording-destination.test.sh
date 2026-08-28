#!/usr/bin/env bash

set -euo pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
STUB_BIN="$TEST_ROOT/bin"
DESTINATION_LOG="$TEST_ROOT/destination"
SCREENSHOT_DESTINATION_LOG="$TEST_ROOT/screenshot-destination"
TEST_HOME="$TEST_ROOT/home"
STATE_ROOT="$TEST_ROOT/state"
VIDEOS_DIR="$TEST_ROOT/Videos"
PICTURES_DIR="$TEST_ROOT/Pictures"

cleanup() {
  rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local expected="$1" actual="$2" message="$3"
  [[ $actual == "$expected" ]] ||
    fail "$message (expected '$expected', got '$actual')"
}

mkdir -p "$STUB_BIN" "$TEST_HOME/.config/omarchy" "$TEST_ROOT/state/omarchy"

cat >"$STUB_BIN/omarchy-capture-screenrecording" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$OMARCHY_SCREENRECORD_DIR" >"$TEST_DESTINATION_LOG"
STUB

cat >"$STUB_BIN/grim" <<'STUB'
#!/usr/bin/env bash
output=${!#}
printf '%s\n' "$output" >"$TEST_SCREENSHOT_DESTINATION_LOG"
printf 'pixels\n' >"$output"
STUB

cat >"$STUB_BIN/hyprctl" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

cat >"$STUB_BIN/notify-send" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

chmod +x "$STUB_BIN"/*

run_recording() {
  env \
    -u OMARCHY_SCREENRECORD_DIR \
    PATH="$STUB_BIN:$PATH" \
    HOME="$TEST_HOME" \
    XDG_STATE_HOME="$STATE_ROOT" \
    XDG_VIDEOS_DIR="$VIDEOS_DIR" \
    TEST_DESTINATION_LOG="$DESTINATION_LOG" \
    "$PLUGIN_DIR/omashot" record screen
}

run_screenshot() {
  env \
    PATH="$STUB_BIN:$PATH" \
    HOME="$TEST_HOME" \
    XDG_STATE_HOME="$STATE_ROOT" \
    XDG_PICTURES_DIR="$PICTURES_DIR" \
    TEST_SCREENSHOT_DESTINATION_LOG="$SCREENSHOT_DESTINATION_LOG" \
    "$PLUGIN_DIR/omashot" screenshot screen >/dev/null
}

write_shell_settings() {
  local screenshot_loc="$1" video_loc="$2"
  jq -n --arg sl "$screenshot_loc" --arg vl "$video_loc" '{
    version: 1,
    plugins: [{id: "b.omashot", screenshotSaveLocation: $sl, videoSaveLocation: $vl}]
  }' >"$TEST_HOME/.config/omarchy/shell.json"
}

write_oma_settings() {
  local output_mode="$1"
  jq -n --arg om "$output_mode" '{
    outputMode: $om
  }' >"$TEST_ROOT/state/omarchy/omashot.json"
}

# Test recording with different video save locations from shell.json
write_shell_settings "$PICTURES_DIR" "$PICTURES_DIR"
write_oma_settings "file"
run_recording
assert_equal "$PICTURES_DIR" "$(<"$DESTINATION_LOG")" \
  "the recording save location did not resolve to the Pictures path"

write_shell_settings "$PICTURES_DIR" "$VIDEOS_DIR"
write_oma_settings "file"
run_recording
assert_equal "$VIDEOS_DIR" "$(<"$DESTINATION_LOG")" \
  "the Videos destination did not resolve to the given path"

# Test screenshot with different screenshot save locations from shell.json
write_shell_settings "$PICTURES_DIR" "$VIDEOS_DIR"
write_oma_settings "file"
run_screenshot
[[ $(<"$SCREENSHOT_DESTINATION_LOG") == "$PICTURES_DIR"/screenshot-*.png ]] ||
  fail "the screenshot save location did not resolve to the given path"

write_shell_settings "$PICTURES_DIR" "$VIDEOS_DIR/subdir"
write_oma_settings "file"
run_recording
assert_equal "$VIDEOS_DIR/subdir" "$(<"$DESTINATION_LOG")" \
  "a nested recording save location did not resolve correctly"

printf 'PASS: capture destinations\n'