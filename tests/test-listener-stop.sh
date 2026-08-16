#!/usr/bin/env bash
# Tests that Ctrl-C actually stops the hands-free listener.
#
# kaizen catches KeyboardInterrupt inside wait_for_wake_word() and reports it
# by returning False rather than re-raising (core/voice.py, and its own caller
# in main.py does `if not detected: break  # Ctrl+C`). A listener that treats
# that False as "nothing happened" reopens the microphone and becomes
# unkillable by Ctrl-C — observed live on 2026-08-15, where only kill -TERM
# stopped it.
#
# VoiceInterface itself needs a microphone and three loaded models, so it is
# faked here. The fake's contract is not invented: returning False on Ctrl-C is
# read off kaizen's real implementation. That makes this a test of OUR loop's
# handling, not proof the whole path works — the end-to-end path is verified by
# ear, not here.
#
# Run: bash tests/test-listener-stop.sh

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

# A bounded harness: the fake gives up after a few laps rather than hanging the
# suite, so the buggy behaviour fails fast and visibly instead of timing out.
run_case() {
    local wake_returns="$1" listen_returns="$2"
    timeout 20 python3 -c "
import sys
sys.path.insert(0, '$LISTENER_DIR')
import claude_listener as cl

WAKE_RETURNS = $wake_returns
LISTEN_RETURNS = $listen_returns
LAP_LIMIT = 4

class FakeVoice:
    def __init__(self):
        self.wake_calls = 0
        self.listen_calls = 0
        self.shutdown_called = False

    def wait_for_wake_word(self):
        self.wake_calls += 1
        if self.wake_calls > LAP_LIMIT:
            print('LOOPED')
            raise SystemExit(3)
        return WAKE_RETURNS

    def listen(self, max_wait_seconds=0):
        self.listen_calls += 1
        return LISTEN_RETURNS

    def shutdown(self):
        self.shutdown_called = True

fake = FakeVoice()
cl.build_interface = lambda: fake
cl.TMUX_TARGET = ''
cl.main()
print('RETURNED')
print('wake_calls=%d' % fake.wake_calls)
print('listen_calls=%d' % fake.listen_calls)
print('shutdown=%s' % fake.shutdown_called)
" 2>/dev/null
}

echo "=== Ctrl-C during the wake-word wait stops the listener ==="

out=$(run_case "False" "None" || true)

if grep -q "LOOPED" <<< "$out"; then
    echo "  FAIL: a False from wait_for_wake_word stops the loop"
    echo "        the listener reopened the mic instead of stopping —"
    echo "        this is the Ctrl-C-does-nothing bug"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: a False from wait_for_wake_word stops the loop"
    PASS=$((PASS + 1))
fi

check "main() returns instead of spinning" \
    "RETURNED" \
    "$(grep -c '^RETURNED$' <<< "$out" | sed 's/^1$/RETURNED/;s/^0$/NEVER RETURNED/')"

check "the mic is not reopened after the interrupt" \
    "wake_calls=1" \
    "$(grep '^wake_calls=' <<< "$out" || echo 'wake_calls=?')"

check "listen() is never reached" \
    "listen_calls=0" \
    "$(grep '^listen_calls=' <<< "$out" || echo 'listen_calls=?')"

check "the audio stack is shut down on the way out" \
    "shutdown=True" \
    "$(grep '^shutdown=' <<< "$out" || echo 'shutdown=?')"

echo ""
echo "=== A silent turn is not an interrupt ==="

# Guards the obvious over-fix: stopping on anything falsy would also kill the
# listener whenever a turn produced no speech, which must keep it running.
out=$(run_case "True" "None" || true)

if grep -q "LOOPED" <<< "$out"; then
    echo "  PASS: nothing heard keeps the listener alive"
    PASS=$((PASS + 1))
else
    echo "  FAIL: nothing heard keeps the listener alive"
    echo "        the listener exited on an empty transcript"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
