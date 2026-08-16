#!/usr/bin/env bash
# Tests for auto-hush: stopping speech when the user takes over by typing.
#
# It has never worked on this machine. `enabled` was seeded with "false" and
# the global config read was guarded by [[ -z "$enabled" ]], which can then
# never be true — so without a per-directory config the global enabled=true was
# never read and the hook exited before signalling anything.
#
# Repairing that alone would have made things worse rather than better. The
# hands-free listener submits by pressing Enter in a tmux pane, which IS a
# UserPromptSubmit, so every spoken turn would fire a hush and the daemon drops
# anything dequeued within 5s of one. Replies arriving quickly — the
# 2026-08-16 follow-up came back in 2s — would simply vanish. A hush must mean
# "the user interrupted", not "a prompt was submitted".
#
# The signal is checked by actually delivering it to a real process, because
# the failure being guarded against is the hook deciding not to send it.
#
# Run: bash tests/test-hush.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../hooks/scripts"

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL + 1)); }

# Stand up a fake narrator home with a process playing the daemon: it records
# SIGUSR1 to a file so the test can tell whether the hook actually signalled.
setup() {
    TH=$(mktemp -d)
    mkdir -p "$TH/.claude-code-narrator" "$TH/proj/.claude-code-narrator"
    FLAG="$TH/hushed"

    python3 -c "
import os, signal, sys, time, pathlib
pathlib.Path('$FLAG.pid').write_text(str(os.getpid()))
signal.signal(signal.SIGUSR1, lambda *_: pathlib.Path('$FLAG').write_text('yes'))
time.sleep(20)
" &
    DAEMON=$!

    for _ in $(seq 1 40); do
        [[ -f "$FLAG.pid" ]] && break
        sleep 0.05
    done
    cp "$FLAG.pid" "$TH/.claude-code-narrator/daemon.pid"
}

teardown() {
    kill "$DAEMON" 2>/dev/null
    wait "$DAEMON" 2>/dev/null
    rm -rf "$TH"
}

# Fire the hook as Claude Code would, with the session's cwd on stdin.
fire_hook() {
    printf '{"cwd":"%s"}' "$TH/proj" \
        | HOME="$TH" bash "$SCRIPTS/hush-on-input.sh" >/dev/null 2>&1
    sleep 0.3
}

hushed() { [[ -f "$FLAG" ]]; }

echo "=== Reading the enabled flag ==="

setup
printf 'enabled=true\n' > "$TH/.claude-code-narrator/config"
fire_hook
if hushed; then ok "a global 'on' with no local config hushes"
else bad "a global 'on' with no local config hushes" "no SIGUSR1 was delivered"; fi
teardown

setup
printf 'enabled=true\n' > "$TH/.claude-code-narrator/config"
printf 'enabled=false\n' > "$TH/proj/.claude-code-narrator/config"
fire_hook
if hushed; then bad "a local 'off' overrides a global 'on'" "it hushed anyway"
else ok "a local 'off' overrides a global 'on'"; fi
teardown

setup
printf 'enabled=false\n' > "$TH/.claude-code-narrator/config"
printf 'enabled=true\n' > "$TH/proj/.claude-code-narrator/config"
fire_hook
if hushed; then ok "a local 'on' overrides a global 'off'"
else bad "a local 'on' overrides a global 'off'" "no SIGUSR1 was delivered"; fi
teardown

setup
fire_hook
if hushed; then bad "no config anywhere does not hush" "it hushed anyway"
else ok "no config anywhere does not hush"; fi
teardown

echo ""
echo "=== A voice submission is not an interruption ==="

# The listener touches this immediately before pressing Enter. Without the
# check, every hands-free turn hushes its own reply.
setup
printf 'enabled=true\n' > "$TH/.claude-code-narrator/config"
touch "$TH/.claude-code-narrator/voice-submit"
fire_hook
if hushed; then
    bad "a transcript the listener submitted does not hush" \
        "it hushed its own reply"
else
    ok "a transcript the listener submitted does not hush"
fi
teardown

# Typing later in the same session must still hush, so the marker has to go
# stale rather than disabling auto-hush for good.
setup
printf 'enabled=true\n' > "$TH/.claude-code-narrator/config"
touch -d '60 seconds ago' "$TH/.claude-code-narrator/voice-submit"
fire_hook
if hushed; then ok "an old voice submission does not suppress a real one"
else bad "an old voice submission does not suppress a real one" \
        "typing no longer hushes"; fi
teardown

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
