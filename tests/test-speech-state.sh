#!/usr/bin/env bash
# Tests for the finished-speaking edge that hands-free input depends on.
#
# The edge must mean "the turn ended", not "the speaker went quiet" — a
# mid-turn progress call must never trigger it, or a listener would open the
# microphone in the middle of a turn.
#
# Run: bash tests/test-speech-state.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../hooks/scripts"

PASS=0
FAIL=0

ok() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

bad() {
    echo "  FAIL: $1"
    echo "        $2"
    FAIL=$((FAIL + 1))
}

# Enqueue via the real speak.sh against a real FIFO and return the JSON line.
# A live PID file stops speak.sh from booting a Kokoro daemon.
enqueue() {
    local tmphome
    tmphome=$(mktemp -d)
    mkdir -p "$tmphome/.claude-code-narrator"
    mkfifo "$tmphome/.claude-code-narrator/fifo"
    printf '%s\n' "$$" > "$tmphome/.claude-code-narrator/daemon.pid"
    printf 'enabled=true\n' > "$tmphome/.claude-code-narrator/config"

    ( timeout 5 head -1 "$tmphome/.claude-code-narrator/fifo" > "$tmphome/out.json" 2>/dev/null ) &
    local reader=$!
    echo "hello there" | HOME="$tmphome" bash "$SCRIPTS/speak.sh" "$@" >/dev/null 2>&1 || true
    wait "$reader" 2>/dev/null || true

    cat "$tmphome/out.json" 2>/dev/null
    rm -rf "$tmphome"
}

echo "=== speak.sh marks the turn's final utterance ==="

out=$(enqueue --force --final)
if [[ "$out" == *'"final":true'* ]]; then
    ok "--final sets final:true"
else
    bad "--final sets final:true" "got: $out"
fi

out=$(enqueue --force)
if [[ "$out" == *'"final":false'* ]]; then
    ok "a plain --force call sets final:false"
else
    bad "a plain --force call sets final:false" "got: $out"
fi

out=$(enqueue --final --force)
if [[ "$out" == *'"final":true'* ]]; then
    ok "flag order does not matter"
else
    bad "flag order does not matter" "got: $out"
fi

out=$(enqueue --force --final)
if [[ "$out" == *'"text":"hello there"'* ]]; then
    ok "the flag is not spoken as text"
else
    bad "the flag is not spoken as text" "got: $out"
fi

echo ""
echo "=== the Stop hook marks every end-of-turn path ==="

# Drive speak-response.sh with a speak.sh that records the arguments it got.
hook_args() {
    local message="$1" mode="$2" tmpdir actual
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/scripts"
    cp "$SCRIPTS/speak-response.sh" "$SCRIPTS/spoken-line.sh" "$tmpdir/scripts/"
    cat > "$tmpdir/scripts/speak.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGS_LOG"
cat >/dev/null
STUB
    chmod +x "$tmpdir/scripts/speak.sh"
    : > "$tmpdir/args.log"

    printf '%s' "$message" \
        | jq -Rs --arg m "$mode" '{last_assistant_message: ., cwd: "/tmp", permission_mode: $m}' \
        | ARGS_LOG="$tmpdir/args.log" bash "$tmpdir/scripts/speak-response.sh" >/dev/null 2>&1 || true

    actual=$(cat "$tmpdir/args.log")
    rm -rf "$tmpdir"
    printf '%s' "$actual"
}

got=$(hook_args "Body."$'\n'"🔊 Spoken line." "default")
if [[ "$got" == *"--final"* ]]; then
    ok "marker path passes --final"
else
    bad "marker path passes --final" "got: '$got'"
fi

got=$(hook_args "A plain answer with no marker at all." "default")
if [[ "$got" == *"--final"* ]]; then
    ok "fallback path passes --final"
else
    bad "fallback path passes --final" "got: '$got'"
fi

got=$(hook_args "A plan-mode answer." "plan")
if [[ "$got" == *"--final"* ]]; then
    ok "plan-mode path passes --final"
else
    bad "plan-mode path passes --final" "got: '$got'"
fi

got=$(hook_args "Housekeeping."$'\n'"🔇" "default")
if [[ -z "$got" ]]; then
    ok "a silenced turn enqueues nothing at all"
else
    bad "a silenced turn enqueues nothing at all" "got: '$got'"
fi

echo ""
echo "=== the daemon only publishes on a final utterance ==="

# Exercise the daemon's decision without loading Kokoro: the rule is that the
# edge is published when, and only when, the parsed message carries final=true.
daemon_decision() {
    python3 -c "
import json, sys
line = sys.argv[1]
final = False
if line.startswith('{'):
    try:
        final = bool(json.loads(line).get('final'))
    except json.JSONDecodeError:
        pass
print('publish' if final else 'quiet')
" "$1"
}

if [[ "$(daemon_decision '{"text":"done","voice":"af_heart","speed":1.1,"final":true}')" == "publish" ]]; then
    ok "final:true publishes the edge"
else
    bad "final:true publishes the edge" "did not publish"
fi

if [[ "$(daemon_decision '{"text":"running tests","voice":"af_heart","speed":1.1,"final":false}')" == "quiet" ]]; then
    ok "mid-turn progress stays quiet"
else
    bad "mid-turn progress stays quiet" "published when it should not"
fi

if [[ "$(daemon_decision 'bare legacy text line')" == "quiet" ]]; then
    ok "legacy plain-text lines stay quiet"
else
    bad "legacy plain-text lines stay quiet" "published when it should not"
fi

echo ""
echo "=== the listener watches the edge correctly ==="

if python3 - "$SCRIPT_DIR/../listener" <<'PY'
import sys, os, time, tempfile, threading
sys.path.insert(0, sys.argv[1])
import claude_listener as cl

marker = os.path.join(tempfile.mkdtemp(), 'speech-finished')
cl.SPEECH_FINISHED_FILE = marker

# Never written: treated as "no edge yet", not as an error.
assert cl.speech_finished_mtime() == 0.0, "absent marker should read 0"

# No edge ever arrives: must time out rather than block forever, or a dead
# narrator daemon would wedge the listener.
edge, reason = cl.wait_for_speech_finished(0.0, timeout=0.6, poll=0.1)
assert edge is None and reason == 'timeout', "should time out"

# An edge published after the baseline is detected.
baseline = cl.speech_finished_mtime()
def publish():
    time.sleep(0.3)
    with open(marker, 'w') as f:
        f.write(str(time.time()))
threading.Thread(target=publish, daemon=True).start()
got, reason = cl.wait_for_speech_finished(baseline, timeout=3, poll=0.1)
assert got is not None and got > baseline, "should detect a new edge"
assert reason is None, "a detected edge carries no reason"

# The edge from the PREVIOUS turn must not count as this turn's reply, or the
# mic opens immediately and records the assistant still talking.
stale = cl.speech_finished_mtime()
edge, _ = cl.wait_for_speech_finished(stale, timeout=0.6, poll=0.1)
assert edge is None, "stale edge counted"
PY
then
    ok "edge watching: absent, timeout, detection, and stale rejection"
else
    bad "edge watching: absent, timeout, detection, and stale rejection" "see assertion above"
fi

echo ""
echo "=== A hushed utterance still ends the turn ==="

# The stall this prevents: a hush discards the utterance, and the discard used
# to `continue` before publish_speech_finished(), so the turn's last utterance
# produced no edge at all. A hands-free listener then waits out the full 300s
# EDGE_TIMEOUT with the microphone shut. Silence is the intended effect of a
# hush; a five-minute hang is not.
dispatch() {
    python3 -c "
import sys, importlib.util
spec = importlib.util.spec_from_file_location('d', '$SCRIPTS/speak-daemon.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.dispatch($1, $2))
"
}

check_dispatch() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        ok "$description"
    else
        bad "$description" "expected $expected, got $actual"
    fi
}

check_dispatch "no recent hush: speak it, edge comes after playback" \
    "(True, False)" "$(dispatch False 9.0)"

check_dispatch "no recent hush, final utterance: same" \
    "(True, False)" "$(dispatch True 9.0)"

check_dispatch "hushed mid-turn utterance: dropped, no edge" \
    "(False, False)" "$(dispatch False 1.0)"

check_dispatch "hushed FINAL utterance: dropped, but the edge still fires" \
    "(False, True)" "$(dispatch True 1.0)"

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
