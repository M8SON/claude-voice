#!/usr/bin/env bash
# Tests that the daemon is warmed at SessionStart rather than on the first turn.
#
# Kokoro takes ~13s to load. The Stop hook's budget in hooks.json is 10s, so on
# a cold daemon speak-response.sh was killed mid-wait: no speech, and — worse
# for hands-free input — no finished-speaking edge, leaving the listener parked
# in wait_for_speech_finished for the full 300s EDGE_TIMEOUT. Observed live on
# 2026-08-16: the first turn after a reboot was silent.
#
# The load has to happen off the critical path. These tests pin both halves of
# that: warming must actually start a daemon, and it must not make the
# SessionStart hook wait for it.
#
# speak-daemon.sh is stubbed with a deliberately SLOW stub — a fast one would
# pass even against a blocking implementation, which is the bug being guarded
# against. Everything runs against a temp HOME, never the live
# ~/.claude-code-narrator.
#
# Run: bash tests/test-daemon-prewarm.sh

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

# An isolated narrator home plus a copy of the scripts with a slow stub daemon.
# Sets TMPHOME and TMPSCRIPTS.
setup_sandbox() {
    TMPHOME=$(mktemp -d)
    TMPSCRIPTS=$(mktemp -d)
    mkdir -p "$TMPHOME/.claude-code-narrator"
    printf 'enabled=true\nvoice=af_heart\nspeed=1.1\n' \
        > "$TMPHOME/.claude-code-narrator/config"
    # Created up front so a reader can attach to it. Without this the reader
    # opens a path that does not exist yet, exits at once, and "nothing was
    # enqueued" passes without observing anything.
    mkfifo "$TMPHOME/.claude-code-narrator/fifo"

    cp "$SCRIPTS/speak.sh" "$SCRIPTS/inject-spoken-line-rules.sh" "$TMPSCRIPTS/"

    # Stands in for the Kokoro daemon: slow to become ready, exactly like the
    # real one. Writes the PID file only after the delay, which is the signal
    # speak.sh waits on.
    cat > "$TMPSCRIPTS/speak-daemon.sh" <<'STUB'
#!/usr/bin/env bash
sleep 3
printf '%s\n' "$$" > "$HOME/.claude-code-narrator/daemon.pid"
sleep 30
STUB
    chmod +x "$TMPSCRIPTS/speak-daemon.sh"
}

teardown_sandbox() {
    if [[ -f "$TMPHOME/.claude-code-narrator/daemon.pid" ]]; then
        kill "$(cat "$TMPHOME/.claude-code-narrator/daemon.pid")" 2>/dev/null || true
    fi
    pkill -f "$TMPSCRIPTS/speak-daemon.sh" 2>/dev/null || true
    rm -rf "$TMPHOME" "$TMPSCRIPTS"
}

echo "=== speak.sh --warm starts the daemon without speaking ==="

setup_sandbox

# Drain the FIFO if anything is ever enqueued, so "nothing was spoken" is
# checked against a real read rather than assumed.
( timeout 12 head -1 "$TMPHOME/.claude-code-narrator/fifo" \
    > "$TMPHOME/enqueued.txt" 2>/dev/null ) &
READER=$!

# `if` rather than a bare call: set -e would abort the suite on exactly the
# non-zero exit this is here to measure.
if HOME="$TMPHOME" timeout 20 bash "$TMPSCRIPTS/speak.sh" --warm \
        >/dev/null 2>"$TMPHOME/warm.err"; then
    warm_rc=0
else
    warm_rc=$?
fi
warm_err=$(cat "$TMPHOME/warm.err" 2>/dev/null || true)

# The EXIT trap that releases the lock referenced a variable scoped to the
# function that set it, so it evaluated after the function returned and
# tripped `set -u` on the way out. The daemon still started, which is exactly
# why this went unnoticed — the failure was only ever visible on stderr.
if [[ $warm_rc -eq 0 && -z "$warm_err" ]]; then
    ok "warming exits cleanly"
else
    bad "warming exits cleanly" "rc=$warm_rc stderr=$warm_err"
fi

if [[ -f "$TMPHOME/.claude-code-narrator/daemon.pid" ]]; then
    ok "a daemon is started"
else
    bad "a daemon is started" "no daemon.pid was ever written"
fi

wait "$READER" 2>/dev/null || true
enqueued=$(cat "$TMPHOME/enqueued.txt" 2>/dev/null || echo "")
if [[ -z "$enqueued" ]]; then
    ok "nothing is enqueued — warming is silent"
else
    bad "nothing is enqueued — warming is silent" "FIFO received: $enqueued"
fi

teardown_sandbox

echo ""
echo "=== SessionStart does not wait for the daemon to load ==="

setup_sandbox

start=$(date +%s%N)
hook_out=$(HOME="$TMPHOME" timeout 20 bash "$TMPSCRIPTS/inject-spoken-line-rules.sh" 2>/dev/null || true)
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))

# The stub takes 3s. hooks.json allows the SessionStart hook 5s. Anything that
# waits on the daemon blows past this; a detached warm returns in milliseconds.
if (( elapsed_ms < 2000 )); then
    ok "the hook returns immediately (${elapsed_ms}ms)"
else
    bad "the hook returns immediately" \
        "took ${elapsed_ms}ms — it is waiting for the daemon to load"
fi

if jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 <<< "$hook_out"; then
    ok "the spoken-line rules are still emitted"
else
    bad "the spoken-line rules are still emitted" "stdout was not the expected JSON"
fi

# The point of returning fast is to start the load, not skip it.
appeared=false
for _ in $(seq 1 20); do
    if [[ -f "$TMPHOME/.claude-code-narrator/daemon.pid" ]]; then
        appeared=true
        break
    fi
    sleep 0.5
done
if [[ "$appeared" == "true" ]]; then
    ok "the daemon really does start in the background"
else
    bad "the daemon really does start in the background" \
        "no daemon.pid appeared — the hook returned fast by doing nothing"
fi

teardown_sandbox

echo ""
echo "=== SessionStart warms nothing when voice output is off ==="

setup_sandbox
printf 'enabled=false\n' > "$TMPHOME/.claude-code-narrator/config"

HOME="$TMPHOME" timeout 20 bash "$TMPSCRIPTS/inject-spoken-line-rules.sh" >/dev/null 2>&1 || true
sleep 4

if [[ -f "$TMPHOME/.claude-code-narrator/daemon.pid" ]]; then
    bad "a disabled narrator stays cold" "a daemon was started anyway"
else
    ok "a disabled narrator stays cold"
fi

teardown_sandbox

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
