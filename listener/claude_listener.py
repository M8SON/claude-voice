#!/usr/bin/env python3
"""Hands-free voice input for Claude Code.

Reuses kaizen's voice stack unchanged — openWakeWord for the wake word, Silero
VAD for endpointing, faster-whisper for transcription. Narrator owns the output
half, so the interface is built with enable_tts=False and never speaks.

Transcripts go to stdout, one per line. Status goes to stderr, so stdout stays
clean enough to pipe.

Run it through kaizen's venv, which holds pyaudio, openwakeword and
faster-whisper — see listener/README.md.
"""

import os
import re
import sys
import logging
import subprocess

KAIZEN_ROOT = os.environ.get("KAIZEN_ROOT", "/home/daedalus/linux/kaizen")

# kaizen is imported, never copied. Its modules resolve as `core.*`.
if KAIZEN_ROOT not in sys.path:
    sys.path.insert(0, KAIZEN_ROOT)

WAKE_MODEL = os.environ.get("WAKE_MODEL", "hey_jarvis")
WAKE_THRESHOLD = float(os.environ.get("WAKE_THRESHOLD", "0.5"))
WAKE_DISPLAY = os.environ.get("WAKE_DISPLAY", "hey jarvis")

# tiny, not base: measured RTF 0.20 against 1.02 on this machine. base is
# real-time, which is too slow to hold a conversation with.
STT_MODEL = os.environ.get("STT_MODEL", "tiny")

VAD_BACKEND = os.environ.get("VAD_BACKEND", "silero")
VAD_THRESHOLD = float(os.environ.get("VAD_THRESHOLD", "0.5"))
VAD_RMS_THRESHOLD = int(os.environ.get("VAD_RMS_THRESHOLD", "1000"))
VAD_MIN_SILENCE_MS = int(os.environ.get("VAD_MIN_SILENCE_MS", "700"))


# Where to type. A tmux target like "voice:0.0" or a session name.
TMUX_TARGET = os.environ.get("CLAUDE_TMUX_TARGET", "")


def status(message):
    """Progress to stderr, keeping stdout to transcripts alone."""
    print(message, file=sys.stderr, flush=True)


def strip_wake_phrase(text, phrase=WAKE_DISPLAY):
    """Drop a leading wake phrase from a transcript.

    listen() reuses the stream wait_for_wake_word() left open, so the wake
    audio is still in the recording and Whisper transcribes it. Submitting
    that verbatim would prefix every prompt with "Hey Jarvis,".
    """
    if not text:
        return text
    words = r"[\s,]+".join(re.escape(w) for w in phrase.split())
    stripped = re.sub(rf"^\s*{words}\s*[,.!?:]*\s*", "", text, count=1, flags=re.IGNORECASE)
    # Only accept the strip if something survives it — otherwise the whole
    # utterance was the wake word and there is nothing to submit.
    return stripped if stripped.strip() else text


def tmux_target_exists(target):
    """True only if target names a real pane or session, matched exactly.

    Neither obvious builtin is safe here. `display-message -t` returns 0 for
    ANY target, silently falling back to the current session, and
    `has-session -t` prefix-matches, so "probe" resolves "probe-live". A wrong
    answer means typing a spoken sentence into someone else's pane, so this
    enumerates real panes and demands an exact match.
    """
    result = subprocess.run(
        [
            "tmux", "list-panes", "-a", "-F",
            "#{session_name}:#{window_index}.#{pane_index}\t#{session_name}",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return False

    for line in result.stdout.splitlines():
        pane, _, session = line.partition("\t")
        if target == pane or target == session:
            return True
    return False


def submit_to_tmux(target, text):
    """Type text into a tmux pane and press Enter.

    -l sends the text literally. Without it tmux parses words like "Enter" or
    "C-c" as key names, so a spoken sentence could send control keys.
    """
    subprocess.run(["tmux", "send-keys", "-t", target, "-l", text], check=True)
    subprocess.run(["tmux", "send-keys", "-t", target, "Enter"], check=True)


def build_interface():
    """Construct an input-only VoiceInterface from kaizen's backends."""
    from core.voice import VoiceInterface
    from core.voice_backends import (
        build_stt_backend,
        build_vad_backend,
        build_wake_backend,
    )

    wake_backend, wake_msg = build_wake_backend(WAKE_MODEL, WAKE_THRESHOLD)
    status(wake_msg)

    stt_backend, stt_msg = build_stt_backend(STT_MODEL, STT_MODEL)
    status(stt_msg)

    vad_backend, vad_msg = build_vad_backend(
        VAD_BACKEND, VAD_THRESHOLD, VAD_RMS_THRESHOLD
    )
    status(vad_msg)

    return VoiceInterface(
        enable_tts=False,
        stt_backend=stt_backend,
        wake_backend=wake_backend,
        vad_backend=vad_backend,
        vad_min_silence_ms=VAD_MIN_SILENCE_MS,
        display_wake_word=WAKE_DISPLAY,
    )


def main():
    logging.basicConfig(level=logging.ERROR)

    # Fail before loading models, not after a minute of downloads.
    if TMUX_TARGET and not tmux_target_exists(TMUX_TARGET):
        status(
            f"CLAUDE_TMUX_TARGET='{TMUX_TARGET}' does not resolve to a tmux pane.\n"
            "Check it with: tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}'"
        )
        sys.exit(1)

    status("Loading models (first run downloads them)...")
    voice = build_interface()

    if TMUX_TARGET:
        status(f"Submitting into tmux target '{TMUX_TARGET}'.")
    else:
        status("CLAUDE_TMUX_TARGET unset — printing transcripts only, not submitting.")
    status(f"Ready. Say '{WAKE_DISPLAY}' to speak. Ctrl-C to stop.")

    try:
        while True:
            if not voice.wait_for_wake_word():
                continue

            status("Listening...")
            text = voice.listen()
            if not text:
                status("Nothing heard.")
                continue

            text = strip_wake_phrase(text)

            status("Transcribed:")
            print(text, flush=True)

            if TMUX_TARGET:
                submit_to_tmux(TMUX_TARGET, text)
    except KeyboardInterrupt:
        status("\nStopping.")
    finally:
        voice.shutdown()


if __name__ == "__main__":
    main()
