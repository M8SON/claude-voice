#!/usr/bin/env bash
# Tests for the claude-voice launcher.
#
# Sessions are built for real, against a real tmux server — the thing being
# tested IS tmux orchestration, so a stub would prove nothing. What is stubbed
# is only the two heavy binaries the panes would otherwise run: `claude` (via
# PATH) and kaizen's venv python (via KAIZEN_ROOT). Both are replaced with
# sleeps, so no Claude Code instance starts and nothing opens the microphone.
# That keeps the launcher itself unstubbed and free of test-only branches.
#
# Run: bash tests/test-launcher.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$REPO/bin/claude-voice"

PASS=0
FAIL=0

if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux not installed — skipping"
    exit 0
fi

check() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $description"
        echo "        expected: \"$expected\""
        echo "        actual:   \"$actual\""
        FAIL=$((FAIL + 1))
    fi
}

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL + 1)); }

# ── Sandbox ───────────────────────────────────────────────────────────────
# A fake HOME (narrator config), fake PATH (`claude`), fake kaizen venv, and a
# project directory whose name becomes the session name.
setup() {
    SANDBOX=$(mktemp -d)
    FAKE_HOME="$SANDBOX/home"
    FAKE_BIN="$SANDBOX/bin"
    FAKE_KAIZEN="$SANDBOX/kaizen"
    PROJECT="$SANDBOX/myproject"

    mkdir -p "$FAKE_HOME/.claude-code-narrator" "$FAKE_BIN" \
             "$FAKE_KAIZEN/.venv/bin" "$PROJECT"
    printf 'enabled=true\nvoice=af_heart\nspeed=1.1\n' \
        > "$FAKE_HOME/.claude-code-narrator/config"

    printf '#!/usr/bin/env bash\nsleep 300\n' > "$FAKE_BIN/claude"
    printf '#!/usr/bin/env bash\nsleep 300\n' > "$FAKE_KAIZEN/.venv/bin/python"
    chmod +x "$FAKE_BIN/claude" "$FAKE_KAIZEN/.venv/bin/python"
}

# Run the launcher inside the sandbox, from $PROJECT unless told otherwise.
launch() {
    local dir="${LAUNCH_DIR:-$PROJECT}"
    ( cd "$dir" && \
      HOME="$FAKE_HOME" \
      PATH="$FAKE_BIN:$PATH" \
      KAIZEN_ROOT="$FAKE_KAIZEN" \
      bash "$LAUNCHER" "$@" 2>&1 )
}

teardown() {
    for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^voice-'); do
        tmux kill-session -t "$s" 2>/dev/null || true
    done
    rm -rf "$SANDBOX"
}

echo "=== Session naming ==="

setup

check "the session is named after the directory" \
    "voice-myproject" \
    "$(launch --print-session)"

mkdir -p "$SANDBOX/my.odd project"
check "characters tmux cannot take are replaced" \
    "voice-my-odd-project" \
    "$(LAUNCH_DIR="$SANDBOX/my.odd project" launch --print-session)"

teardown

echo ""
echo "=== Starting in the background ==="

setup
launch --background >/dev/null 2>&1

if tmux has-session -t voice-myproject 2>/dev/null; then
    ok "the session is created"
else
    bad "the session is created" "no session named voice-myproject"
fi

check "it has two panes — Claude and the listener" \
    "2" \
    "$(tmux list-panes -t voice-myproject 2>/dev/null | wc -l | tr -d ' ')"

# The listener must be told a target that its own validator accepts, which is
# session:window.pane — not a tmux pane id, which would silently never match.
if tmux list-panes -t voice-myproject -F '#{pane_start_command}' 2>/dev/null \
    | grep -q 'CLAUDE_TMUX_TARGET=voice-myproject:0\.0'; then
    ok "the listener is pointed at the Claude pane"
else
    bad "the listener is pointed at the Claude pane" \
        "$(tmux list-panes -t voice-myproject -F '#{pane_start_command}' 2>/dev/null)"
fi

if tmux list-panes -t voice-myproject -F '#{pane_start_command}' 2>/dev/null \
    | grep -q 'AUTO_SUBMIT=true'; then
    ok "transcripts are submitted by default"
else
    bad "transcripts are submitted by default" "AUTO_SUBMIT=true not found"
fi

echo ""
echo "=== Running it again attaches rather than duplicating ==="

# The whole point of naming sessions per directory. A second run must not
# build a second session, or leave two listeners fighting over the microphone.
launch --background >/dev/null 2>&1
check "there is still exactly one session" \
    "1" \
    "$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -c '^voice-myproject$')"

check "there are still exactly two panes" \
    "2" \
    "$(tmux list-panes -t voice-myproject 2>/dev/null | wc -l | tr -d ' ')"

echo ""
echo "=== Stopping ==="

launch --stop >/dev/null 2>&1
if tmux has-session -t voice-myproject 2>/dev/null; then
    bad "--stop removes the session" "the session is still there"
else
    ok "--stop removes the session"
fi

# Stopping something already stopped is not an error worth failing a script on.
launch --stop >/dev/null 2>&1
check "--stop on a stopped session succeeds quietly" "0" "$?"

teardown

echo ""
echo "=== Preflight fails before building anything ==="

setup
rm -rf "$FAKE_KAIZEN/.venv"
out=$(launch --background); rc=$?

check "a missing kaizen venv exits non-zero" "1" "$rc"

if grep -qi "kaizen" <<< "$out"; then
    ok "the error names kaizen"
else
    bad "the error names kaizen" "got: $out"
fi

if tmux has-session -t voice-myproject 2>/dev/null; then
    bad "no half-built session is left behind" "a session was created anyway"
else
    ok "no half-built session is left behind"
fi

teardown

setup
printf 'enabled=false\n' > "$FAKE_HOME/.claude-code-narrator/config"
out=$(launch --background); rc=$?

check "a disabled narrator exits non-zero" "1" "$rc"

if grep -q "narrator:on" <<< "$out"; then
    ok "the error says how to fix it"
else
    bad "the error says how to fix it" "got: $out"
fi

teardown

# speak.sh resolves "enabled" local-then-global via resolve_state, and
# /narrator:off --local writes a per-directory config. A preflight that reads
# only the global file passes, builds the session, and then nothing speaks —
# and because the microphone reopens on the finished-speaking edge, the
# listener waits out the full 300s EDGE_TIMEOUT. That is the exact
# "apparent deadness" this check exists to prevent.

setup
mkdir -p "$PROJECT/.claude-code-narrator"
printf 'enabled=false\n' > "$PROJECT/.claude-code-narrator/config"
out=$(launch --background); rc=$?

check "a locally disabled narrator exits non-zero" "1" "$rc"

if grep -q -- "--local" <<< "$out"; then
    ok "the error points at the per-directory config"
else
    bad "the error points at the per-directory config" "got: $out"
fi

if tmux has-session -t voice-myproject 2>/dev/null; then
    bad "no session is built when output is locally off" "a session was created"
else
    ok "no session is built when output is locally off"
fi

teardown

# The reverse must also hold: local wins, so local=true over a global=false
# is a working configuration and must not be refused.
setup
printf 'enabled=false\n' > "$FAKE_HOME/.claude-code-narrator/config"
mkdir -p "$PROJECT/.claude-code-narrator"
printf 'enabled=true\n' > "$PROJECT/.claude-code-narrator/config"
launch --background >/dev/null 2>&1

if tmux has-session -t voice-myproject 2>/dev/null; then
    ok "a local override turning it ON is honoured"
else
    bad "a local override turning it ON is honoured" \
        "refused a directory where speech would actually work"
fi

teardown

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
