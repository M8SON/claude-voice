#!/usr/bin/env bash
# Tests that the listener gives up on a reply that can never arrive.
#
# The microphone reopens on narrator's finished-speaking edge. If voice output
# is turned off mid-conversation — /narrator:off, or /narrator:off --local in
# the directory Claude is running in — no edge is ever published, and the
# listener used to sit in wait_for_speech_finished for the full 300s
# EDGE_TIMEOUT with the microphone shut. In --background mode its status lines
# are not even visible, so the whole thing simply looks dead.
#
# The flag is resolved against the CLAUDE pane's directory, not the listener's.
# They differ by design: claude-voice launches Claude in your project and the
# listener from the plugin repo, so reading the listener's own cwd would check
# the wrong directory entirely.
#
# Run: bash tests/test-listener-health.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER_DIR="$SCRIPT_DIR/../listener"

PASS=0
FAIL=0

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

py() {
    python3 -c "
import sys
sys.path.insert(0, '$LISTENER_DIR')
$1
"
}

echo "=== Resolving the enabled flag the way speak.sh does ==="

SB=$(mktemp -d)
mkdir -p "$SB/home/.claude-code-narrator" "$SB/proj/.claude-code-narrator"

printf 'enabled=true\n' > "$SB/home/.claude-code-narrator/config"
check "global on, no local override" "True" \
    "$(HOME=$SB/home py "import claude_listener as cl; print(cl.narrator_enabled('$SB/proj'))")"

printf 'enabled=false\n' > "$SB/proj/.claude-code-narrator/config"
check "a local 'off' overrides a global 'on'" "False" \
    "$(HOME=$SB/home py "import claude_listener as cl; print(cl.narrator_enabled('$SB/proj'))")"

printf 'enabled=false\n' > "$SB/home/.claude-code-narrator/config"
printf 'enabled=true\n' > "$SB/proj/.claude-code-narrator/config"
check "a local 'on' overrides a global 'off'" "True" \
    "$(HOME=$SB/home py "import claude_listener as cl; print(cl.narrator_enabled('$SB/proj'))")"

rm -f "$SB/home/.claude-code-narrator/config" "$SB/proj/.claude-code-narrator/config"
check "no config anywhere is not enabled" "False" \
    "$(HOME=$SB/home py "import claude_listener as cl; print(cl.narrator_enabled('$SB/proj'))")"

rm -rf "$SB"

echo ""
echo "=== Waiting for an edge that cannot come ==="

SB=$(mktemp -d)
mkdir -p "$SB/home/.claude-code-narrator" "$SB/proj"
printf 'enabled=false\n' > "$SB/home/.claude-code-narrator/config"

# The point of the whole exercise: this must come back in well under a second,
# not after EDGE_TIMEOUT.
result=$(HOME=$SB/home py "
import time
import claude_listener as cl
cl.SPEECH_FINISHED_FILE = '$SB/never-written'
cl.claude_pane_cwd = lambda: '$SB/proj'
start = time.monotonic()
edge, reason = cl.wait_for_speech_finished(0.0, timeout=30, poll=0.01)
print('%s %s %.2f' % (edge, reason, time.monotonic() - start))
")

check "it returns no edge" "None" "$(awk '{print $1}' <<< "$result")"
check "it says why" "silenced" "$(awk '{print $2}' <<< "$result")"

elapsed=$(awk '{print $3}' <<< "$result")
if python3 -c "import sys; sys.exit(0 if $elapsed < 2.0 else 1)"; then
    echo "  PASS: it gives up in ${elapsed}s rather than waiting out the timeout"
    PASS=$((PASS + 1))
else
    echo "  FAIL: it gives up in ${elapsed}s rather than waiting out the timeout"
    FAIL=$((FAIL + 1))
fi

rm -rf "$SB"

echo ""
echo "=== The normal paths still behave ==="

SB=$(mktemp -d)
mkdir -p "$SB/home/.claude-code-narrator" "$SB/proj"
printf 'enabled=true\n' > "$SB/home/.claude-code-narrator/config"

# A real edge, published while the wait is in progress.
edge_result=$(HOME=$SB/home py "
import os, time, threading
import claude_listener as cl
marker = '$SB/edge'
cl.SPEECH_FINISHED_FILE = marker
cl.claude_pane_cwd = lambda: '$SB/proj'

def publish():
    time.sleep(0.3)
    with open(marker, 'w') as f:
        f.write('done')

threading.Thread(target=publish, daemon=True).start()
edge, reason = cl.wait_for_speech_finished(0.0, timeout=10, poll=0.05)
print('%s %s' % (edge is not None, reason))
")

check "a published edge is still returned" "True" "$(awk '{print $1}' <<< "$edge_result")"
check "with no reason attached" "None" "$(awk '{print $2}' <<< "$edge_result")"

# Enabled, but nothing ever speaks: still a timeout, not a false "silenced".
timeout_result=$(HOME=$SB/home py "
import claude_listener as cl
cl.SPEECH_FINISHED_FILE = '$SB/never'
cl.claude_pane_cwd = lambda: '$SB/proj'
edge, reason = cl.wait_for_speech_finished(0.0, timeout=0.5, poll=0.05)
print('%s %s' % (edge, reason))
")

check "a genuine timeout is not reported as silenced" "None timeout" "$timeout_result"

rm -rf "$SB"

echo ""
echo "=== Without a tmux target there is no Claude directory to read ==="

check "an unset target yields no directory rather than a crash" "None" \
    "$(py "
import claude_listener as cl
cl.TMUX_TARGET = ''
print(cl.claude_pane_cwd())
")"

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
