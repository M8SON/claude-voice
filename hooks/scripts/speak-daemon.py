#!/usr/bin/env python3
"""Speech queue daemon. Keeps the Kokoro TTS pipeline loaded in memory and reads
utterances from a FIFO, speaking them sequentially with no overlap.

Usage: speak-daemon.py <fifo_path>
"""

import sys
import os
import signal
import time
import json

NARRATOR_DIR = os.path.expanduser('~/.claude-code-narrator')
STATE_FILE = os.path.join(NARRATOR_DIR, 'config')
PID_FILE = os.path.join(NARRATOR_DIR, 'daemon.pid')
# Touched after the last utterance of a turn finishes playing. The mtime is the
# signal; the contents are unused. A hands-free listener watches this to know
# when the speaker has gone quiet and the microphone can safely open.
SPEECH_FINISHED_FILE = os.path.join(NARRATOR_DIR, 'speech-finished')


HUSH_WINDOW = 5.0


def dispatch(final, seconds_since_hush, window=HUSH_WINDOW):
    """What to do with a dequeued utterance: (speak, publish_edge_now).

    A recent hush means the user has taken over, so the line is dropped. But
    dropping the turn's LAST utterance must still publish the finished-speaking
    edge: a hands-free listener has the microphone shut until that edge lands,
    and silence is the point of a hush while a 300s hang is not.

    When the line is spoken, the edge is published after playback drains
    instead, so publish_edge_now is False on that path.
    """
    if seconds_since_hush < window:
        return False, bool(final)
    return True, False


def publish_speech_finished():
    """Touch the finished-speaking file, ignoring any filesystem error."""
    try:
        with open(SPEECH_FINISHED_FILE, 'w') as f:
            f.write(str(time.time()))
    except OSError:
        pass


def read_state(key, default):
    """Read a value from the state file, with a default."""
    try:
        with open(STATE_FILE, 'r') as f:
            for line in f:
                line = line.strip()
                if line.startswith(key + '='):
                    return line.split('=', 1)[1]
    except FileNotFoundError:
        pass
    return default


def main():
    if len(sys.argv) < 2:
        print("Usage: speak-daemon.py <fifo_path>", file=sys.stderr)
        sys.exit(1)

    fifo_path = sys.argv[1]

    import kokoro
    import sounddevice as sd
    import numpy as np

    # Load pipeline once — this is the expensive step (~9s).
    pipeline = kokoro.KPipeline(lang_code='a', repo_id='hexgrad/Kokoro-82M')

    # Open FIFO read-write to prevent EOF when no writers.
    fd = os.open(fifo_path, os.O_RDWR)

    # Write PID file AFTER pipeline is loaded and FIFO is open — this signals
    # to speak.sh that we're ready to accept text.
    with open(PID_FILE, 'w') as f:
        f.write(str(os.getpid()))

    # Timestamp of last SIGUSR1 (hush). Lines received before this are skipped.
    hush_time = 0.0

    def shutdown(signum, frame):
        sd.stop()
        try:
            os.unlink(PID_FILE)
        except OSError:
            pass
        sys.exit(0)

    def hush(signum, frame):
        nonlocal hush_time
        hush_time = time.monotonic()
        sd.stop()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGUSR1, hush)

    buf = b''
    while True:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            continue

        buf += data
        while b'\n' in buf:
            line_bytes, buf = buf.split(b'\n', 1)
            line = line_bytes.decode('utf-8', errors='replace').strip()

            if line == '__QUIT__':
                try:
                    os.unlink(PID_FILE)
                except OSError:
                    pass
                return

            if not line:
                continue

            try:
                # Parsed BEFORE the hush check, because whether this is the
                # turn's final utterance decides what a discard has to do.
                utterance_text = line
                utterance_voice = None
                utterance_speed = None
                utterance_final = False
                if line.startswith('{'):
                    try:
                        msg = json.loads(line)
                        utterance_text = msg.get('text', line)
                        utterance_voice = msg.get('voice')
                        utterance_speed = msg.get('speed')
                        utterance_final = bool(msg.get('final'))
                    except json.JSONDecodeError:
                        pass  # treat as plain text

                if not utterance_text.strip():
                    continue

                # A hush means the user has taken over: drop the line. If it
                # was the turn's last, the edge still has to fire, or a
                # listener waits out its whole timeout with the mic shut.
                speak, publish_now = dispatch(
                    utterance_final, time.monotonic() - hush_time)
                if not speak:
                    if publish_now:
                        publish_speech_finished()
                    continue

                voice = utterance_voice or os.environ.get('CLAUDE_VOICE') or read_state('voice', 'af_heart')
                speed = float(utterance_speed if utterance_speed is not None else (os.environ.get('CLAUDE_VOICE_SPEED') or read_state('speed', '1.1')))

                audio_chunks = []
                for gs, ps, audio in pipeline(utterance_text, voice=voice, speed=speed):
                    if audio is not None:
                        audio_chunks.append(audio)

                # Check again after synthesis — hush may have arrived mid-TTS.
                # Same rule: a dropped final utterance still ends the turn.
                speak, publish_now = dispatch(
                    utterance_final, time.monotonic() - hush_time)
                if not speak:
                    if publish_now:
                        publish_speech_finished()
                    continue

                if audio_chunks:
                    full_audio = np.concatenate(audio_chunks)
                    sd.play(full_audio, samplerate=24000)
                    sd.wait()

                # Playback has drained. If this was the turn's last utterance,
                # publish the edge — mid-turn progress calls do not set "final",
                # so they never open a listener's microphone.
                if utterance_final:
                    publish_speech_finished()
            except Exception as e:
                print(f"Speech error: {e}", file=sys.stderr)

    # Clean up PID file on normal exit.
    try:
        os.unlink(PID_FILE)
    except OSError:
        pass


if __name__ == '__main__':
    main()
