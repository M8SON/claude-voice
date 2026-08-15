#!/usr/bin/env bash
# Tests for submitting transcripts into a tmux pane, and for stripping the wake
# phrase that leaks into transcripts because listen() reuses the wake stream.
#
# Submission is tested against a REAL throwaway tmux session running `cat`, not
# a stub, because the failure mode being guarded against is tmux itself
# interpreting spoken words as key names.
#
# Run: bash tests/test-tmux-submit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER_DIR="$SCRIPT_DIR/../listener"

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

# Call a function from the real listener module. Module-level imports are
# stdlib only, so the system python is enough — no kaizen venv needed.
call_py() {
    python3 -c "
import sys
sys.path.insert(0, '$LISTENER_DIR')
import claude_listener as cl
print(cl.$1)
"
}

echo "=== Wake phrase stripping ==="

check "strips the leaked wake phrase" \
    "I'm testing if this is working." \
    "$(call_py "strip_wake_phrase(\"Hey Jarvis, I'm testing if this is working.\")")"

check "strips without a comma" \
    "run the tests" \
    "$(call_py 'strip_wake_phrase("hey jarvis run the tests")')"

check "case insensitive" \
    "check git status" \
    "$(call_py 'strip_wake_phrase("HEY JARVIS check git status")')"

check "leaves a clean transcript alone" \
    "commit the changes" \
    "$(call_py 'strip_wake_phrase("commit the changes")')"

check "keeps the text when it is only the wake phrase" \
    "Hey Jarvis" \
    "$(call_py 'strip_wake_phrase("Hey Jarvis")')"

check "does not strip mid-sentence" \
    "tell me what hey jarvis means" \
    "$(call_py 'strip_wake_phrase("tell me what hey jarvis means")')"

echo ""
echo "=== Submission into a real tmux pane ==="

SESSION="cvtest-$$"
OUTFILE=$(mktemp)
tmux new-session -d -s "$SESSION" "cat > $OUTFILE" 2>/dev/null
trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true; rm -f "$OUTFILE"' EXIT

submit() {
    python3 -c "
import sys
sys.path.insert(0, '$LISTENER_DIR')
import claude_listener as cl
cl.submit_to_tmux('$SESSION', sys.argv[1])
" "$1"
}

# Each of these is a spoken sentence that tmux could mangle if -l were missing
# or quoting were wrong.
submit "check the git status"
submit "it's Mason's repo, isn't it?"
submit "run tests; then commit"
submit 'say "hello there" out loud'
submit "use C-c to quit and press Enter"

# Let cat flush, then close stdin so the file is complete.
tmux send-keys -t "$SESSION" C-d 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -s "$OUTFILE" ]] && grep -q "press Enter" "$OUTFILE" 2>/dev/null && break
    tmux send-keys -t "$SESSION" C-d 2>/dev/null || true
done

got=$(cat "$OUTFILE")

for expected in \
    "check the git status" \
    "it's Mason's repo, isn't it?" \
    "run tests; then commit" \
    'say "hello there" out loud' \
    "use C-c to quit and press Enter"
do
    if grep -Fqx "$expected" <<< "$got"; then
        echo "  PASS: arrived intact — $expected"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: arrived intact — $expected"
        echo "        full capture: $(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "=== auto_submit=False types without sending ==="

NOSEND="cvnosend-$$"
NOSEND_OUT=$(mktemp)
tmux new-session -d -s "$NOSEND" "cat > $NOSEND_OUT" 2>/dev/null

python3 -c "
import sys
sys.path.insert(0, '$LISTENER_DIR')
import claude_listener as cl
cl.submit_to_tmux('$NOSEND', 'typed but not submitted', auto_submit=False)
"

# cat only receives a line once Enter is pressed, so an empty file proves the
# text is still sitting in the input line.
if [[ ! -s "$NOSEND_OUT" ]]; then
    echo "  PASS: nothing is submitted without Enter"
    PASS=$((PASS + 1))
else
    echo "  FAIL: nothing is submitted without Enter"
    echo "        received: $(cat "$NOSEND_OUT")"
    FAIL=$((FAIL + 1))
fi

if tmux capture-pane -t "$NOSEND" -p 2>/dev/null | grep -Fq "typed but not submitted"; then
    echo "  PASS: the text is visible in the pane, awaiting Enter"
    PASS=$((PASS + 1))
else
    echo "  FAIL: the text is visible in the pane, awaiting Enter"
    FAIL=$((FAIL + 1))
fi

tmux kill-session -t "$NOSEND" 2>/dev/null || true
rm -f "$NOSEND_OUT"

echo ""
echo "=== Target validation ==="

# A session of its own: the one above is dead, because C-d ended its `cat`.
LIVE="cvlive-$$"
tmux new-session -d -s "$LIVE" "sleep 60" 2>/dev/null
trap 'tmux kill-session -t "$SESSION" 2>/dev/null || true; tmux kill-session -t "$LIVE" 2>/dev/null || true; rm -f "$OUTFILE"' EXIT

if python3 -c "
import sys
sys.path.insert(0, '$LISTENER_DIR')
import claude_listener as cl
sys.exit(0 if cl.tmux_target_exists('$LIVE') else 1)
"; then
    echo "  PASS: a live session validates"
    PASS=$((PASS + 1))
else
    echo "  FAIL: a live session validates"
    FAIL=$((FAIL + 1))
fi

if python3 -c "
import sys
sys.path.insert(0, '$LISTENER_DIR')
import claude_listener as cl
sys.exit(0 if cl.tmux_target_exists('no-such-session-xyz') else 1)
"; then
    echo "  FAIL: a missing session is rejected"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: a missing session is rejected"
    PASS=$((PASS + 1))
fi

# tmux has-session prefix-matches, which would accept a truncated name and
# type into the wrong pane. Exact matching only.
if python3 -c "
import sys
sys.path.insert(0, '$LISTENER_DIR')
import claude_listener as cl
sys.exit(0 if cl.tmux_target_exists('${LIVE%%-*}') else 1)
"; then
    echo "  FAIL: a prefix of a real session is rejected"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: a prefix of a real session is rejected"
    PASS=$((PASS + 1))
fi

if python3 -c "
import sys
sys.path.insert(0, '$LISTENER_DIR')
import claude_listener as cl
sys.exit(0 if cl.tmux_target_exists('$LIVE:0.0') else 1)
"; then
    echo "  PASS: full pane coordinates validate"
    PASS=$((PASS + 1))
else
    echo "  FAIL: full pane coordinates validate"
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
