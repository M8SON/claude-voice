#!/usr/bin/env bash
# Tests that the speech daemon's output is kept rather than discarded.
#
# speak.sh started the daemon with `>/dev/null 2>&1`, so every "Speech error:"
# speak-daemon.py has ever printed went nowhere. On 2026-08-16 that cost an
# afternoon: TTS was sputtering mid-sentence and the daemon's own account of it
# was unreadable — /proc/<pid>/fd/2 pointed at /dev/null. The audio fault turned
# out to be in WSLg's PulseAudio RDP sink, but nothing in the daemon could say
# so, because nothing it said was kept.
#
# The daemon is stubbed; this pins the redirection speak.sh sets up, not Kokoro.
# Everything runs against a temp HOME, never the live ~/.claude-code-narrator.
#
# Run: bash tests/test-daemon-logging.sh

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

# An isolated narrator home plus a copy of the scripts with a stub daemon that
# writes to both streams. Sets TMPHOME and TMPSCRIPTS.
setup_sandbox() {
    TMPHOME=$(mktemp -d)
    TMPSCRIPTS=$(mktemp -d)
    mkdir -p "$TMPHOME/.claude-code-narrator"
    printf 'enabled=true\nvoice=af_heart\nspeed=1.1\n' \
        > "$TMPHOME/.claude-code-narrator/config"
    mkfifo "$TMPHOME/.claude-code-narrator/fifo"

    cp "$SCRIPTS/speak.sh" "$TMPSCRIPTS/"

    # Stands in for the Kokoro daemon. Writes the marker to stderr the way
    # speak-daemon.py writes "Speech error: ...", and one line to stdout, then
    # writes the PID file so speak.sh stops waiting.
    cat > "$TMPSCRIPTS/speak-daemon.sh" <<'STUB'
#!/usr/bin/env bash
echo "STUB-STDERR-MARKER" >&2
echo "STUB-STDOUT-MARKER"
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

echo "=== the daemon's stderr is captured, not discarded ==="

setup_sandbox

HOME="$TMPHOME" timeout 20 bash "$TMPSCRIPTS/speak.sh" --warm >/dev/null 2>&1 || true

# The daemon is started detached; give the redirection a moment to land.
LOG="$TMPHOME/.claude-code-narrator/daemon.log"
for _ in $(seq 1 20); do
    [[ -s "$LOG" ]] && break
    sleep 0.5
done

if [[ -f "$LOG" ]]; then
    ok "a daemon log file is created"
else
    bad "a daemon log file is created" "no daemon.log at $LOG"
fi

log_contents=$(cat "$LOG" 2>/dev/null || echo "")

if [[ "$log_contents" == *STUB-STDERR-MARKER* ]]; then
    ok "stderr reaches the log"
else
    bad "stderr reaches the log" \
        "daemon.log did not contain the marker — stderr is still going to /dev/null. Got: ${log_contents:-<empty>}"
fi

if [[ "$log_contents" == *STUB-STDOUT-MARKER* ]]; then
    ok "stdout reaches the log too"
else
    bad "stdout reaches the log too" \
        "daemon.log did not contain the stdout marker. Got: ${log_contents:-<empty>}"
fi

teardown_sandbox

echo ""
echo "=== a restart appends rather than truncating ==="

# An intermittent fault that kills the daemon is exactly the case where the
# previous run's last words matter most. Truncating on start would erase them.
setup_sandbox

printf 'PRE-EXISTING-LINE\n' > "$TMPHOME/.claude-code-narrator/daemon.log"

HOME="$TMPHOME" timeout 20 bash "$TMPSCRIPTS/speak.sh" --warm >/dev/null 2>&1 || true

LOG="$TMPHOME/.claude-code-narrator/daemon.log"
for _ in $(seq 1 20); do
    grep -q STUB-STDERR-MARKER "$LOG" 2>/dev/null && break
    sleep 0.5
done

log_contents=$(cat "$LOG" 2>/dev/null || echo "")

if [[ "$log_contents" == *PRE-EXISTING-LINE* && "$log_contents" == *STUB-STDERR-MARKER* ]]; then
    ok "an earlier run's output survives a restart"
else
    bad "an earlier run's output survives a restart" \
        "expected both the old line and the new marker. Got: ${log_contents:-<empty>}"
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
