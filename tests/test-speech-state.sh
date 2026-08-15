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
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
