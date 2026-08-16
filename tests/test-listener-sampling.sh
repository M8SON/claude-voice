#!/usr/bin/env bash
# Tests the measurement rows the listener writes for every utterance.
#
# These exist to calibrate a hallucination filter against real use. Whisper
# tiny invents whole sentences from room noise — measured 2026-08-16, six
# silent windows produced "Love it, love it, love it.", "It's done." and a
# 111-character run-on, five of six long enough to survive kaizen's len<3 rule.
# Neither length nor the VAD endpoint separates those from real speech, so the
# threshold has to come from measured audio levels, and the levels have to come
# from Mason's own voice rather than a guess.
#
# Until there is enough data the rows are observation only: listen_and_log must
# return exactly what voice.listen() would, including its len<3 -> None rule.
# Instrumentation that changes behaviour would poison the samples it collects.
#
# Run: bash tests/test-listener-sampling.sh

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

# Runs python against the real listener module. Module-level imports are stdlib
# only — deliberately, so this needs no kaizen venv — and the level maths must
# stay that way.
py() {
    python3 -c "
import sys
sys.path.insert(0, '$LISTENER_DIR')
$1
"
}

echo "=== Level measurement ==="

# A WAV of constant amplitude has peak == rms, which makes both checkable
# against a known number rather than against whatever the code computes.
check "peak of a known-amplitude tone" \
    "0.1" \
    "$(py "
import wave, tempfile, array, os
import claude_listener as cl
p = tempfile.mktemp(suffix='.wav')
a = array.array('h', [3277] * 16000)
with wave.open(p, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(a.tobytes())
peak, rms = cl.measure_wav(p)
os.unlink(p)
print(round(peak, 3))
")"

check "rms of a known-amplitude tone" \
    "0.1" \
    "$(py "
import wave, tempfile, array, os
import claude_listener as cl
p = tempfile.mktemp(suffix='.wav')
a = array.array('h', [-3277] * 16000)
with wave.open(p, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(a.tobytes())
peak, rms = cl.measure_wav(p)
os.unlink(p)
print(round(rms, 3))
")"

check "an empty recording measures zero, not a crash" \
    "0.0 0.0" \
    "$(py "
import wave, tempfile, os
import claude_listener as cl
p = tempfile.mktemp(suffix='.wav')
with wave.open(p, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(b'')
peak, rms = cl.measure_wav(p)
os.unlink(p)
print(peak, rms)
")"

echo ""
echo "=== A row is written per utterance ==="

# A fake VoiceInterface exposing only what listen_and_log uses. The real one
# needs a microphone and three models.
FAKE=$(cat <<'PYFAKE'
import wave, array, tempfile

class FakeVoice:
    def __init__(self, text, amplitude=16384, fire=True):
        self.text = text
        self.amplitude = amplitude
        self.fire = fire
        self.shutdown_called = False

    def _record_until_silence(self, max_wait_seconds=0, on_speech_done=None):
        if self.fire and on_speech_done is not None:
            on_speech_done()
        p = tempfile.mktemp(suffix='.wav')
        a = array.array('h', [self.amplitude] * 16000)
        with wave.open(p, 'wb') as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
            w.writeframes(a.tobytes())
        return p

    def _transcribe(self, path):
        return self.text
PYFAKE
)

read_row() {
    py "
import json, tempfile, os
$FAKE
import claude_listener as cl
log = tempfile.mktemp(suffix='.jsonl')
cl.SAMPLE_LOG = log
voice = FakeVoice($1)
returned = cl.listen_and_log(voice, '$2')
row = json.loads(open(log).read().strip().splitlines()[-1])
os.unlink(log)
print(json.dumps({'returned': returned, 'row': row}))
"
}

row=$(read_row "'commit the changes'" "followup")

check "the transcript is returned unchanged" \
    "commit the changes" \
    "$(jq -r '.returned' <<< "$row")"

check "the row records the mode" \
    "followup" \
    "$(jq -r '.row.mode' <<< "$row")"

check "the row records the measured rms" \
    "0.5" \
    "$(jq -r '.row.rms' <<< "$row")"

check "the row records whether the VAD endpoint fired" \
    "true" \
    "$(jq -r '.row.endpoint' <<< "$row")"

check "the row records the text, so hallucinations can be told apart" \
    "commit the changes" \
    "$(jq -r '.row.text' <<< "$row")"

echo ""
echo "=== Observation only — behaviour must match voice.listen() ==="

# kaizen's listen() drops anything under 3 characters. "You" is exactly 3 and
# survives, which is why a length filter cannot solve this.
short=$(read_row "'Hi'" "followup")
check "under three characters returns None, as kaizen does" \
    "null" \
    "$(jq -r '.returned' <<< "$short")"

check "but the dropped utterance is still measured" \
    "Hi" \
    "$(jq -r '.row.text' <<< "$short")"

three=$(read_row "'You'" "followup")
check "exactly three characters still passes, as kaizen does" \
    "You" \
    "$(jq -r '.returned' <<< "$three")"

echo ""
echo "=== Logging must never break voice input ==="

check "an unwritable log does not stop the transcript coming back" \
    "still works" \
    "$(py "
$FAKE
import claude_listener as cl
cl.SAMPLE_LOG = '/proc/nonexistent-dir/samples.jsonl'
print(cl.listen_and_log(FakeVoice('still works'), 'wake'))
" 2>/dev/null)"

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
