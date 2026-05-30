#!/usr/bin/env bash
# Live-test that SettingsWatcher actually reloads ~/.config/neomouse/settings.toml
# when it's edited, *and* that the new value lands in NeoMouseState.theme
# (proven by the "SettingsWatcher: reloaded …" log line appearing within
# the debounce window after each write).
#
# Usage:
#   scripts/test-hot-reload.sh             # uses an already-running neomouse / NeoMouseTest if present
#   scripts/test-hot-reload.sh --launch    # `just release-test` first, then run the checks against /Applications/NeoMouseTest.app
#
# Exit code: 0 if every scenario passed, 1 otherwise. Always restores
# ~/.config/neomouse/settings.toml from a backup on exit (even on failure).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS_PATH="$HOME/.config/neomouse/settings.toml"
LOG_PATH="$HOME/Library/Logs/neomouse/neomouse.log"
BACKUP_PATH="$(mktemp /tmp/neomouse-settings-bak.XXXXX.toml)"
PASSES=0
FAILURES=0

c_green=$'\033[1;32m'
c_red=$'\033[1;31m'
c_blue=$'\033[1;34m'
c_dim=$'\033[2m'
c_reset=$'\033[0m'

step()   { printf "\n%s==>%s %s\n" "$c_blue" "$c_reset" "$1"; }
pass()   { printf "  %sOK%s %s\n" "$c_green" "$c_reset" "$1"; PASSES=$((PASSES+1)); }
fail()   { printf "  %sFAIL%s %s\n" "$c_red" "$c_reset" "$1"; FAILURES=$((FAILURES+1)); }
note()   { printf "  %s%s%s\n" "$c_dim" "$1" "$c_reset"; }

cleanup() {
  if [[ -f "$BACKUP_PATH" ]]; then
    cp "$BACKUP_PATH" "$SETTINGS_PATH"
    rm -f "$BACKUP_PATH"
    note "restored $SETTINGS_PATH from backup"
  fi
}
trap cleanup EXIT

cd "$REPO_ROOT"

# ----- preflight -----

step "Preflight"

[[ -f "$SETTINGS_PATH" ]] || {
  fail "$SETTINGS_PATH does not exist — run \`just init\` first"
  exit 1
}
cp "$SETTINGS_PATH" "$BACKUP_PATH"
pass "backed up settings.toml → $BACKUP_PATH"

mkdir -p "$(dirname "$LOG_PATH")"
touch "$LOG_PATH"
pass "log path exists ($LOG_PATH)"

# Optional `--launch` arg: build + install + launch the test app fresh.
if [[ "${1:-}" == "--launch" ]]; then
  step "Launching NeoMouseTest"
  just release-test >/dev/null 2>&1
  sleep 2
  if pgrep -f "NeoMouseTest.app/Contents/MacOS/neomouse" >/dev/null; then
    pass "NeoMouseTest is running"
  else
    fail "NeoMouseTest did not start"
    exit 1
  fi
else
  # pgrep uses BRE by default — substring match on the bit common to both
  # the production (`/Applications/NeoMouseTest.app/Contents/MacOS/neomouse`)
  # and dev (`.build/debug/neomouse.app/Contents/MacOS/neomouse`) layouts.
  if pgrep -fl "app/Contents/MacOS/neomouse" >/dev/null; then
    pass "an existing neomouse/.app instance is running"
  else
    fail "no neomouse instance running — pass --launch or start the app first"
    exit 1
  fi
fi

# Capture log baseline so we only consider lines added after we start writing.
BASELINE=$(wc -l < "$LOG_PATH")
note "log baseline: $BASELINE lines"

# Wait for a SettingsWatcher line to appear after $BASELINE. Returns 0 if
# matched within $2 seconds, 1 otherwise. Argv: pattern, timeout-seconds.
wait_for_log() {
  local pattern="$1"
  local timeout="$2"
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    if tail -n +"$((BASELINE+1))" "$LOG_PATH" | grep -qE "$pattern"; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# Run a scenario. Argv: <label>, <pre-mutation cmd>, <expected log pattern>.
# Pre-mutation cmd runs in a subshell; pattern is an ERE matched against
# the log tail after the mutation.
run_scenario() {
  local label="$1"
  local mutation="$2"
  local pattern="$3"
  local new_baseline
  new_baseline=$(wc -l < "$LOG_PATH")
  BASELINE="$new_baseline"
  note "scenario: $label"
  bash -c "$mutation"
  if wait_for_log "$pattern" 5; then
    pass "matched: $pattern"
    # Show the matched line for context.
    local match
    match=$(tail -n +"$((BASELINE+1))" "$LOG_PATH" | grep -E "$pattern" | head -1)
    note "  ↳ $match"
  else
    fail "no match for: $pattern (timed out after 5s)"
    note "  last 5 log lines:"
    tail -n 5 "$LOG_PATH" | sed 's/^/    /'
  fi
}

# ----- scenarios -----

step "Scenario 1 — harmless comment append should trigger a reload"
run_scenario \
  "append a TOML comment" \
  "printf '\\n# hot-reload-test marker %s\\n' \"\$(date +%H%M%S)\" >> '$SETTINGS_PATH'" \
  "SettingsWatcher: reloaded"

step "Scenario 2 — theme value tweak (theme.toast.width) should reload"
run_scenario \
  "change theme.toast.width 300 → 500" \
  "sed -i.bak -E 's/^(width[[:space:]]*=)[[:space:]]*300/\\1 500/' '$SETTINGS_PATH' && rm -f '$SETTINGS_PATH.bak'" \
  "SettingsWatcher: reloaded"

step "Scenario 3 — invalid value (type mismatch) should produce a parseable failure"
run_scenario \
  "set grid.divisions to a string (invalid)" \
  "sed -i.bak -E 's/^divisions[[:space:]]*=[[:space:]]*5/divisions = \"not_an_int\"/' '$SETTINGS_PATH' && rm -f '$SETTINGS_PATH.bak'" \
  "SettingsWatcher: reload failed"

step "Scenario 4 — restore divisions, app should reload cleanly again"
run_scenario \
  "revert grid.divisions to 5" \
  "sed -i.bak -E 's/^divisions[[:space:]]*=[[:space:]]*\"not_an_int\"/divisions = 5/' '$SETTINGS_PATH' && rm -f '$SETTINGS_PATH.bak'" \
  "SettingsWatcher: reloaded"

step "Scenario 5 — app stayed alive throughout"
# pgrep uses BRE by default; the substring below is common to both the
# production (/Applications/NeoMouseTest.app/Contents/MacOS/neomouse) and
# dev (.build/debug/neomouse.app/Contents/MacOS/neomouse) layouts. Capture
# the PID separately so we can show diagnostic info if it's empty — the
# previous `if pgrep …; then` form swallowed too much context to debug.
survivor_pid="$(pgrep -f "app/Contents/MacOS/neomouse" | head -1 || true)"
if [[ -n "$survivor_pid" ]]; then
  pass "process still running (pid $survivor_pid) — survived 1 valid + 1 invalid + 2 more valid edits"
else
  fail "process died at some point"
  note "  pgrep -fl 'neomouse' snapshot:"
  pgrep -fl "neomouse" 2>&1 | sed 's/^/    /' || note "    (pgrep found nothing)"
fi

# ----- summary -----

step "Summary"
printf "  %d passed, %d failed\n" "$PASSES" "$FAILURES"
if (( FAILURES > 0 )); then
  exit 1
fi
