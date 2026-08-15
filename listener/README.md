# Hands-free voice input

Talk to Claude Code with no keypress — no hold-space, no Enter. This listens for a
wake word, records until you stop talking, transcribes locally, and submits the text
into a running Claude Code session. Narrator handles the other direction.

Nothing here implements speech. It reuses [kaizen](../../kaizen)'s voice stack —
openWakeWord, Silero VAD, faster-whisper — and only supplies the wiring.

## Requirements

- kaizen checked out with its venv built (`pyaudio`, `openwakeword`, `faster-whisper`)
- A working microphone. **On WSL2 this needs `wsl --shutdown` from Windows PowerShell
  once**; WSLg's capture channel comes up dead otherwise, and no amount of Linux-side
  configuration fixes it.
- **Input gain at 40%.** `RDPSource` defaults to 100% and clips so hard that speech and
  an empty room measure the same. This does not survive a reboot:

  ```bash
  pactl set-source-volume RDPSource 40%
  ```

## Run it

```bash
/home/daedalus/linux/kaizen/.venv/bin/python listener/claude_listener.py
```

Transcripts go to stdout, one per line; status goes to stderr.

Say the wake word, pause, then speak. First run downloads the models, which takes a
minute; after that startup is a few seconds.

## Configuration

All optional, all environment variables:

| Variable | Default | Notes |
|---|---|---|
| `KAIZEN_ROOT` | `/home/daedalus/linux/kaizen` | Where to import the voice stack from |
| `WAKE_MODEL` | `hey_jarvis` | Any openWakeWord model name |
| `WAKE_THRESHOLD` | `0.5` | Lower catches more, and more false positives |
| `STT_MODEL` | `tiny` | See below before changing |
| `VAD_BACKEND` | `silero` | Or `rms` |
| `VAD_MIN_SILENCE_MS` | `700` | How long a pause ends your turn |
| `CLAUDE_TMUX_TARGET` | unset | tmux pane to type into. Unset = print only |
| `AUTO_SUBMIT` | `true` | `false` types the text and waits for you to press Enter |

**`AUTO_SUBMIT=false`** is the dictation mode: the transcript is typed into Claude
Code's input line exactly as if you had typed it, and stays there until you press Enter.
You get a chance to read it — and fix it — before it becomes a prompt. That costs one
keypress and is the difference between hands-free and hands-nearly-free.

**Use `tiny`.** Measured on this machine against 8s of real captured speech: `tiny`
runs at RTF 0.20, `base` at 1.02. `base` transcribes in real time, which means waiting
several seconds after every sentence before anything happens.

## Notes on the audio path

Two behaviours look like faults and are not:

- **RDP suppresses silence to literal zeros.** A quiet room reads ~0.00001 RMS rather
  than a noise floor. VAD likes this.
- **Roughly 1.5 seconds of dead air at stream open.** This is why the interface holds
  one stream across wake and listen instead of reopening per utterance, and why a short
  test capture can read as total failure when the microphone is fine.
