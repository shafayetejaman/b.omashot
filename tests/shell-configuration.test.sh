#!/usr/bin/env bash

set -euo pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$PLUGIN_DIR/omashot"
SERVICE="$PLUGIN_DIR/Service.qml"
TEST_ROOT=$(mktemp -d)
TEST_HOME="$TEST_ROOT/home"
STUB_BIN="$TEST_ROOT/bin"
OUTPUT_DIR="$TEST_ROOT/output"
TMP_DIR="$TEST_ROOT/tmp"
GRIM_LOG="$TEST_ROOT/grim.log"
SLEEP_LOG="$TEST_ROOT/sleep.log"
EDITOR_LOG="$TEST_ROOT/editor.log"
EDITOR_CONTENT_LOG="$TEST_ROOT/editor-content.log"
CLIPBOARD_LOG="$TEST_ROOT/clipboard.log"
RECORDING_ARGS_LOG="$TEST_ROOT/recording-args.log"
RECORDING_DIR_LOG="$TEST_ROOT/recording-dir.log"
STATE_FILE="$TEST_ROOT/state/omashot/state.json"
OMA_SETTINGS_FILE="$TEST_ROOT/state/omarchy/omashot.json"

cleanup() {
  rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_source_absent() {
  local needle="$1" file="$2" message="$3"
  if rg --fixed-strings --quiet -- "$needle" "$file"; then
    fail "$message"
  fi
}

for option in --output-mode --save-location --timer --cursor --settle --editor; do
  assert_source_absent "$option" "$HELPER" "the helper still accepts $option configuration"
  assert_source_absent "$option" "$SERVICE" "the service still passes $option configuration"
done

legacy_prefix="OMA""SHOT_"
assert_source_absent "$legacy_prefix" "$HELPER" \
  "the helper still reads legacy Omashot environment configuration"
rg --fixed-strings --quiet -- 'SHELL_CONFIG_FILE="$HOME/.config/omarchy/shell.json"' "$HELPER" ||
  fail "the helper does not read shell.json"
rg --fixed-strings --quiet -- 'first(.plugins[]? | select(.id == $id))' "$HELPER" ||
  fail "the helper does not select its b.omashot plugin entry"
rg --fixed-strings --quiet -- 'OMA_SETTINGS_FILE="${XDG_STATE_HOME' "$HELPER" ||
  fail "the helper does not read XDG_STATE_HOME for omashot.json"
assert_source_absent 'XDG_DESKTOP_DIR' "$HELPER" \
  "the helper still recognizes Desktop as a destination"
rg --fixed-strings --quiet -- 'var next = normalizeSaveLocation(value)' "$SERVICE" ||
  fail "the service accepts unrecognized symbolic save locations"

mkdir -p "$TEST_HOME/.config/omarchy" "$STUB_BIN" "$OUTPUT_DIR" "$TMP_DIR" "$TEST_ROOT/state/omarchy"

# shell.json for save locations
jq -n --arg output "$OUTPUT_DIR" '{
  version: 1,
  plugins: [{
    id: "b.omashot",
    screenshotSaveLocation: $output,
    videoSaveLocation: $output
  }]
}' >"$TEST_HOME/.config/omarchy/shell.json"

# omashot.json for other settings
jq -n '{
  outputMode: "editor",
  timerSeconds: 5,
  includeCursor: true,
  editorCommand: "test-screenshot-editor"
}' >"$OMA_SETTINGS_FILE"

if env HOME="$TEST_HOME" XDG_STATE_HOME="$TEST_ROOT/state" "$HELPER" screenshot --output-mode=file >/dev/null 2>&1; then
  fail "a retired command-line configuration option was accepted"
fi

cat >"$STUB_BIN/grim" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$TEST_GRIM_LOG"
output=${!#}
if [[ $output == - ]]; then
  printf 'pixels\n'
else
  printf 'pixels\n' >"$output"
fi
STUB

cat >"$STUB_BIN/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$TEST_SLEEP_LOG"
STUB

cat >"$STUB_BIN/test-screenshot-editor" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >"$TEST_EDITOR_LOG"
cat "$1" >"$TEST_EDITOR_CONTENT_LOG"
STUB

cat >"$STUB_BIN/wl-copy" <<'STUB'
#!/usr/bin/env bash
cat >"$TEST_CLIPBOARD_LOG"
STUB

cat >"$STUB_BIN/notify-send" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat >"$STUB_BIN/omarchy-capture-screenrecording" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$TEST_RECORDING_ARGS_LOG"
printf '%s\n' "$OMARCHY_SCREENRECORD_DIR" >"$TEST_RECORDING_DIR_LOG"
STUB

cat >"$STUB_BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

chmod +x "$STUB_BIN"/*

env \
  PATH="$STUB_BIN:$PATH" \
  HOME="$TEST_HOME" \
  XDG_STATE_HOME="$TEST_ROOT/state" \
  TMPDIR="$TMP_DIR" \
  TEST_GRIM_LOG="$GRIM_LOG" \
  TEST_SLEEP_LOG="$SLEEP_LOG" \
  TEST_EDITOR_LOG="$EDITOR_LOG" \
  TEST_EDITOR_CONTENT_LOG="$EDITOR_CONTENT_LOG" \
  "$HELPER" screenshot screen >/dev/null

for ((attempt = 0; attempt < 40; attempt++)); do
  [[ -f $EDITOR_LOG && -f $EDITOR_CONTENT_LOG ]] && break
  sleep 0.05
done

[[ -f $EDITOR_LOG && -f $EDITOR_CONTENT_LOG ]] ||
  fail "the editor command was not launched"
grep -Eq '(^|[[:space:]])-c([[:space:]]|$)' "$GRIM_LOG" ||
  fail "the cursor setting was ignored"
grep -Fxq '5' "$SLEEP_LOG" || fail "the timer setting was ignored"
editor_path=$(<"$EDITOR_LOG")
[[ $editor_path == "$TMP_DIR"/omashot-editor.*.png ]] ||
  fail "Editor mode did not use a temporary image"
grep -Fxq 'pixels' "$EDITOR_CONTENT_LOG" || fail "the editor did not receive the screenshot"
for ((attempt = 0; attempt < 40; attempt++)); do
  [[ ! -e $editor_path ]] && break
  sleep 0.05
done
[[ ! -e $editor_path ]] || fail "the temporary editor image was not removed"
[[ -z $(find "$OUTPUT_DIR" -mindepth 1 -print -quit) ]] ||
  fail "Editor mode saved a screenshot file"
if [[ -f $STATE_FILE && -n $(jq -r '.lastScreenshot // empty' "$STATE_FILE") ]]; then
  fail "Editor mode recorded a saved screenshot path"
fi

# Test clipboard mode with shell.json save location
jq -n '{
  outputMode: "clipboard"
}' >"$OMA_SETTINGS_FILE"

env \
  PATH="$STUB_BIN:$PATH" \
  HOME="$TEST_HOME" \
  XDG_STATE_HOME="$TEST_ROOT/state" \
  TMPDIR="$TMP_DIR" \
  TEST_GRIM_LOG="$GRIM_LOG" \
  TEST_SLEEP_LOG="$SLEEP_LOG" \
  TEST_CLIPBOARD_LOG="$CLIPBOARD_LOG" \
  "$HELPER" screenshot screen >/dev/null

grep -Fxq 'pixels' "$CLIPBOARD_LOG" || fail "Clipboard mode did not copy the screenshot"
grep -Eq -- '(^|[[:space:]])-$' "$GRIM_LOG" ||
  fail "Clipboard mode did not stream grim output"
[[ -z $(find "$OUTPUT_DIR" -mindepth 1 -print -quit) ]] ||
  fail "Clipboard mode saved a screenshot file"
[[ -z $(find "$TMP_DIR" -mindepth 1 -print -quit) ]] ||
  fail "Clipboard mode created a temporary screenshot file"
if [[ -f $STATE_FILE && -n $(jq -r '.lastScreenshot // empty' "$STATE_FILE") ]]; then
  fail "Clipboard mode recorded a saved screenshot path"
fi

# Test recording with shell.json videoSaveLocation and omashot.json audio settings
jq -n '{
  recordDesktopAudio: true,
  recordMicrophoneAudio: true,
  recordWebcam: true
}' >"$OMA_SETTINGS_FILE"

env \
  PATH="$STUB_BIN:$PATH" \
  HOME="$TEST_HOME" \
  XDG_STATE_HOME="$TEST_ROOT/state" \
  TEST_RECORDING_ARGS_LOG="$RECORDING_ARGS_LOG" \
  TEST_RECORDING_DIR_LOG="$RECORDING_DIR_LOG" \
  TEST_SLEEP_LOG="$SLEEP_LOG" \
  "$HELPER" record screen

grep -Fq -- '--with-desktop-audio' "$RECORDING_ARGS_LOG" ||
  fail "the omashot.json desktop-audio setting was ignored"
grep -Fq -- '--with-microphone-audio' "$RECORDING_ARGS_LOG" ||
  fail "the omashot.json microphone setting was ignored"
grep -Fq -- '--with-webcam' "$RECORDING_ARGS_LOG" ||
  fail "the omashot.json webcam setting was ignored"
[[ $(<"$RECORDING_DIR_LOG") == "$OUTPUT_DIR" ]] ||
  fail "the shell.json recording location was ignored"

printf 'PASS: split config (shell.json for locations, omashot.json for rest)\n'