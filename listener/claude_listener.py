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
import sys
import logging

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


def status(message):
    """Progress to stderr, keeping stdout to transcripts alone."""
    print(message, file=sys.stderr, flush=True)


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

    status("Loading models (first run downloads them)...")
    voice = build_interface()
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

            status("Transcribed:")
            print(text, flush=True)
    except KeyboardInterrupt:
        status("\nStopping.")
    finally:
        voice.shutdown()


if __name__ == "__main__":
    main()
