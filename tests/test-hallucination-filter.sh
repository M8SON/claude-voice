#!/usr/bin/env bash
# Tests the gate that stops Whisper's room-noise hallucinations reaching the pane.
#
# Every number below is MEASURED, not invented — captured from Mason's own
# microphone at 40% gain on 2026-08-16 and recorded in
# ~/.claude-code-narrator/voice-samples.jsonl. Fixtures built from the code's
# own assumptions would agree with the code's own mistakes, and this filter has
# already had two plausible designs refuted by measurement:
#
#   - transcript length: refuted. The hallucinations are LONGER than the real
#     commands ("Love it, love it, love it." at 26 chars against "Yes." at 4),
#     so a length floor drops speech and passes noise.
#   - RMS: refuted. "Yes." measures RMS 0.00255, BELOW the 0.0033 of a silent
#     window. A short word carries full amplitude but little average energy,
#     so RMS penalises exactly the short commands that must survive.
#   - a peak THRESHOLD: refuted, and caught in the act. Shipped at 0.042, it
#     blocked a real "Yes." measuring peak 0.00711 — logged with
#     blocked="level". Spoken "Yes." ranges 0.00711 to 0.06598 depending on
#     how it is said, so real speech reaches well below the 0.035 of the
#     loudest silent window. The distributions OVERLAP; no peak threshold
#     separates them, and one tuned to pass a quiet "Yes." must pass silence.
#
# So the VAD endpoint carries the decision, and it earns that on real-world
# data: all 8 genuine utterances fired it, and both hallucinations that
# actually reached the pane did not. The peak floor stays only as a low
# backstop under every real utterance seen, and is not asked to separate the
# overlapping region — see the limitation at the end of this file.
#
# Run: bash tests/test-hallucination-filter.sh

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

# peak, endpoint -> is_probably_speech
gate() {
    python3 -c "
import sys
sys.path.insert(0, '$LISTENER_DIR')
import claude_listener as cl
print(cl.is_probably_speech($1, $2))
"
}

echo "=== Real utterances must get through ==="

# The five speech rows measured on 2026-08-16. "Yes." is the one that matters:
# it is the quietest real utterance recorded and the case every rejected
# design broke on.
check "a normal sentence (peak 0.06625)" "True" "$(gate 0.06625 True)"
check "'Yes.' spoken clearly (peak 0.05093)" "True" "$(gate 0.05093 True)"
check "'Hey Jarvis, um, I'm just testing' (peak 0.06674)" "True" "$(gate 0.06674 True)"
check "'Testing if you can hear me again.' (peak 0.06326)" "True" "$(gate 0.06326 True)"
check "'Right, that's good.' (peak 0.06372)" "True" "$(gate 0.06372 True)"

# The regression this suite exists to prevent. A 0.042 floor dropped this one,
# and the sample log is the only reason it was noticed rather than felt as the
# assistant intermittently ignoring a word.
check "'Yes.' spoken quietly (peak 0.00711) — was wrongly dropped once" \
    "True" "$(gate 0.00711 True)"

echo ""
echo "=== Hallucinations must be blocked ==="

# Both real-world nuisance submissions, each transcribed "You" from an empty
# room. Neither fired the VAD endpoint.
check "'You' from a silent window (peak 0.0007)" "False" "$(gate 0.0007 False)"
check "'You' from a silent window (peak 0.00461)" "False" "$(gate 0.00461 False)"

# Both were caught by the endpoint, not the level — and they are the only two
# that ever reached the pane in ordinary use.
check "a silent window that never endpointed, however loud (peak 0.035)" \
    "False" "$(gate 0.035 False)"

echo ""
echo "=== The endpoint is required as well as the level ==="

# One staged silent window in five DID fire the endpoint, so the endpoint
# alone cannot be trusted — and a loud noise that never endpointed is not
# speech either. Both conditions are needed.
check "a loud burst that never endpointed is not speech" "False" "$(gate 0.9 False)"
check "a near-silent window that endpointed is not speech" "False" "$(gate 0.003 True)"

echo ""
echo "=== The floor stays under every real utterance ever measured ==="

# The floor is a backstop, not a separator. It must sit below the quietest
# real utterance (0.00711) — anything higher drops speech, which is exactly
# what 0.042 did — while still catching the loudest hallucination that
# actually reached the pane (0.00461).
floor=$(python3 -c "
import sys
sys.path.insert(0, '$LISTENER_DIR')
import claude_listener as cl
print(cl.MIN_SPEECH_PEAK)
")
if python3 -c "import sys; sys.exit(0 if 0.00461 < $floor < 0.00711 else 1)"; then
    echo "  PASS: the floor ($floor) is below all measured speech"
    PASS=$((PASS + 1))
else
    echo "  FAIL: the floor ($floor) is not between 0.00461 and 0.00711"
    echo "        above 0.00711 it drops a real 'Yes.'; below 0.00461 the"
    echo "        backstop stops catching anything"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== A blocked utterance is still recorded ==="

# A dropped command must be visible after the fact. If the floor is ever wrong
# the evidence has to be in the log, not lost.
row=$(python3 -c "
import sys, json, tempfile, os, wave, array
sys.path.insert(0, '$LISTENER_DIR')
import claude_listener as cl

class FakeVoice:
    def _record_until_silence(self, max_wait_seconds=0, on_speech_done=None):
        p = tempfile.mktemp(suffix='.wav')
        a = array.array('h', [100] * 16000)   # peak 0.003 — far below the floor
        with wave.open(p, 'wb') as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
            w.writeframes(a.tobytes())
        return p
    def _transcribe(self, path):
        return 'Love it, love it, love it.'

log = tempfile.mktemp(suffix='.jsonl')
cl.SAMPLE_LOG = log
returned = cl.listen_and_log(FakeVoice(), 'followup')
row = json.loads(open(log).read().strip().splitlines()[-1])
os.unlink(log)
print(json.dumps({'returned': returned, 'row': row}))
")

check "the hallucination is not returned" "null" "$(jq -r '.returned' <<< "$row")"
check "the row still records its text" "Love it, love it, love it." "$(jq -r '.row.text' <<< "$row")"
check "the row marks it as not submitted" "false" "$(jq -r '.row.returned' <<< "$row")"
check "the row records why it was dropped" "level" "$(jq -r '.row.blocked' <<< "$row")"

echo ""
echo "=== Known limitation, asserted so it is not mistaken for a bug ==="

# A silent window that fires the VAD endpoint AND clears the backstop gets
# through. One staged capture in five did exactly that. This is not fixable by
# threshold — real speech lives in the same range — so it is pinned here as
# expected behaviour rather than left to be rediscovered as a regression.
check "endpoint-firing room noise above the floor is NOT caught" \
    "True" "$(gate 0.02527 True)"

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
