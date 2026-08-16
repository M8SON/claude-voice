#!/usr/bin/env bash
# Tests for the playback backend that routes audio around WSLg's broken audio.
#
# On 2026-08-16 TTS sputtered mid-sentence on this machine. The fault was in
# WSLg's PulseAudio RDP sink: it plays cleanly for ~20s after resuming from
# idle, then starves the audio callback for hundreds of milliseconds at a time,
# degrading cumulatively and surviving a stream reopen. Measured A/B with an
# identical 30s signal: through WSL audio, 30s of audio took 91.5s; written to
# a Windows path and played by Media.SoundPlayer, 32.6s and clean.
#
# So playback picks a route. These tests pin the choice and the mechanics of
# the Windows route — not the audio itself, which no unit test can hear.
#
# Everything here is stdlib-only on purpose: selection and the WAV/subprocess
# plumbing must be testable without numpy or the Kokoro venv.
#
# Run: bash tests/test-playback-backend.sh

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

# Run a python snippet with hooks/scripts importable. Prints the snippet's
# stdout; the caller compares against what it expected.
py() {
    python3 -c "
import sys
sys.path.insert(0, '$SCRIPTS')
$1
" 2>&1
}

check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        ok "$label"
    else
        bad "$label" "expected [$expected], got [$actual]"
    fi
}

echo "=== Backend selection ==="

# An explicit setting wins everywhere. Detection can be wrong, and when it is,
# the config is the way out — so it must override, not merely hint.
check "an explicit 'windows' wins on a non-WSL kernel" "windows" \
    "$(py "
import playback
print(playback.select_backend('windows', 'Linux version 6.6.0', True))
")"

check "an explicit 'sounddevice' wins on WSL" "sounddevice" \
    "$(py "
import playback
print(playback.select_backend('sounddevice', 'Linux version 6.6-microsoft-standard-WSL2', True))
")"

check "auto picks windows on WSL when powershell is reachable" "windows" \
    "$(py "
import playback
print(playback.select_backend('auto', 'Linux version 6.6.87.2-microsoft-standard-WSL2', True))
")"

# WSL without interop is a real configuration (interop can be disabled in
# wsl.conf). Choosing the Windows route there would leave the user mute, which
# is worse than the sputter this is fixing.
check "auto falls back when powershell is missing" "sounddevice" \
    "$(py "
import playback
print(playback.select_backend('auto', 'Linux version 6.6-microsoft-standard-WSL2', False))
")"

check "auto picks sounddevice on a plain Linux kernel" "sounddevice" \
    "$(py "
import playback
print(playback.select_backend('auto', 'Linux version 6.6.0-generic', True))
")"

check "the match is case-insensitive" "windows" \
    "$(py "
import playback
print(playback.select_backend('auto', 'Linux version 5.15.0-Microsoft-standard', True))
")"

# A typo in the config should not be a silent third behaviour.
check "an unrecognised value behaves like auto" "windows" \
    "$(py "
import playback
print(playback.select_backend('nonsense', 'Linux version 6.6-microsoft-standard-WSL2', True))
")"

echo ""
echo "=== The Windows route's mechanics ==="

# _play_pcm takes raw 16-bit bytes rather than a numpy array, so the plumbing
# is testable without the Kokoro venv.
check "it writes a WAV the stdlib can read back" "1|2|24000|1200" \
    "$(py "
import playback, wave, tempfile, os, shutil
p = playback.WindowsPlayer(tempfile.gettempdir(), tempfile.gettempdir())
def fake(win_path):
    # Copy the file aside before play_pcm deletes it, so we can inspect it.
    shutil.copy(p.last_path, os.path.join(tempfile.gettempdir(), 'probe.wav'))
    return ['true']
playback.build_player_command = fake
p.play_pcm(b'\x00\x00' * 1200, 24000)
with wave.open(os.path.join(tempfile.gettempdir(), 'probe.wav')) as w:
    print('|'.join(str(x) for x in (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes())))
")"

check "it hands the player a Windows-style path" "yes" \
    "$(py "
import playback, tempfile
seen = {}
def fake(win_path):
    seen['win'] = win_path
    return ['true']
playback.build_player_command = fake
p = playback.WindowsPlayer(r'C:\\Temp', tempfile.gettempdir())
p.play_pcm(b'\x00\x00' * 10, 24000)
print('yes' if seen['win'].startswith(r'C:\\Temp' + '\\\\') and seen['win'].endswith('.wav') else 'no:' + seen['win'])
")"

# A spoken line every few seconds would otherwise fill the Windows temp
# directory with WAVs nobody deletes.
check "it removes its temp file afterwards" "gone" \
    "$(py "
import playback, tempfile, os
def fake(win_path):
    return ['true']
playback.build_player_command = fake
p = playback.WindowsPlayer(tempfile.gettempdir(), tempfile.gettempdir())
p.play_pcm(b'\x00\x00' * 10, 24000)
print('gone' if not os.path.exists(p.last_path) else 'left behind')
")"

# Hush is the whole reason stop() exists: the user has started talking and the
# reply must go quiet at once, not when the utterance happens to end.
check "stop() ends playback promptly" "stopped-early" \
    "$(py "
import playback, tempfile, threading, time
def fake(win_path):
    return ['sleep', '30']
playback.build_player_command = fake
p = playback.WindowsPlayer(tempfile.gettempdir(), tempfile.gettempdir())
done = []
t = threading.Thread(target=lambda: (p.play_pcm(b'\x00\x00' * 10, 24000), done.append(time.monotonic())))
start = time.monotonic()
t.start()
time.sleep(1.0)
p.stop()
t.join(timeout=10)
print('stopped-early' if done and done[0] - start < 5 else 'still-playing')
")"

# The temp file must not survive an interrupted utterance either.
check "an interrupted utterance still cleans up" "gone" \
    "$(py "
import playback, tempfile, threading, time, os
def fake(win_path):
    return ['sleep', '30']
playback.build_player_command = fake
p = playback.WindowsPlayer(tempfile.gettempdir(), tempfile.gettempdir())
t = threading.Thread(target=lambda: p.play_pcm(b'\x00\x00' * 10, 24000))
t.start()
time.sleep(1.0)
p.stop()
t.join(timeout=10)
print('gone' if not os.path.exists(p.last_path) else 'left behind')
")"

# stop() with nothing playing happens on every hush that arrives between
# utterances. It must be a no-op, not a crash in a signal handler.
check "stop() is safe when nothing is playing" "ok" \
    "$(py "
import playback, tempfile
p = playback.WindowsPlayer(tempfile.gettempdir(), tempfile.gettempdir())
p.stop()
print('ok')
")"

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
