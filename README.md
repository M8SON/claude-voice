# claude-voice — talk to Claude Code, hear it answer

Hands-free voice for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).
Say a wake word, speak, and hear the reply — then just keep talking.

Everything runs locally. [Kokoro](https://github.com/hexgrad/kokoro) for speech,
[openWakeWord](https://github.com/dscripka/openWakeWord) for the wake word, Silero
VAD for endpointing, faster-whisper for transcription. No cloud APIs, no audio
leaves the machine.

```bash
cd ~/any/project
claude-voice
```

Then say **"hey jarvis"** and talk. When the reply finishes speaking, the microphone
reopens by itself — follow-ups need no wake word. Stay quiet for twelve seconds and
it drops back to waiting for one.

```
microphone → wake word → Whisper → tmux pane → Claude Code
                                                    ↓
   microphone reopens ← finished-speaking edge ← Kokoro → speaker
```

## Credit

The speaking half is not ours. It comes from
**[claude-code-narrator](https://github.com/shreyas-s-rao/claude-code-narrator)**
by **Shreyas Rao**, MIT licensed, and the Kokoro pipeline, the speech daemon, the
slash commands and the per-directory config are all his work. `LICENSE` is his
copyright notice, kept intact. Upstream remains the `upstream` git remote.

This project adds the listening half, and changes how the speaking half decides
what to say.

## What this adds

**Listening — new here.**

- A wake-word listener (`listener/`) that transcribes speech and types it into
  Claude Code's pane. Claude Code's own voice input is push-to-talk by
  construction, so hands-free input has to be built outside it.
- The **finished-speaking edge**: a marker the daemon touches once a turn's last
  utterance has actually finished playing. The microphone reopens on that signal
  and only then, which is what stops the listener transcribing Claude's own voice
  and submitting it back as a new prompt. Without it there is no conversation,
  only dictation.
- A **hallucination filter**. Whisper transcribes an empty room as speech — six
  silent windows here produced *"Love it, love it, love it."*, *"It's done."* and a
  111-character run-on, and with auto-submit each became a prompt. Neither
  transcript length nor audio level separates those from real speech: the
  hallucinations are *longer* than "stop", and a quietly spoken "Yes." measures
  below a loud silent room. The VAD endpoint decides instead, with a level floor
  only as a backstop under everything real ever measured.
- **`claude-voice`**, which starts Claude in the current directory with a listener
  already wired to its pane, one session per project.

**Speaking — changes to upstream's behaviour.**

- **A spoken line, written on purpose.** Rather than reading the first ~1000
  characters of a response, it speaks a line the assistant writes for the ear: a
  final line prefixed `🔊 `, compressed but carrying the whole situation. A line of
  exactly `🔇` keeps the turn silent. Short answers that already read well aloud
  carry no marker and are spoken as written.
- **No per-tool chatter.** The `PostToolUse` hook is gone. Mid-turn narration is
  deliberate, via `speak.sh --force`, and triggered by duration rather than
  activity.
- **The contract is taught at `SessionStart`**, so the assistant knows the rules
  without being told each time.
- **Kokoro is warmed at `SessionStart`.** Loading it takes ~13s while the `Stop`
  hook's budget is 10s, so on a cold daemon the first turn used to be killed
  mid-load — silent, and with no edge to reopen the microphone. The load now
  happens off the critical path.

## Requirements

For speaking:

- Python 3.9+ (tested on 3.13)
- Linux or macOS with audio output
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)

Additionally for listening:

- A working microphone
- `tmux` — the listener types into a pane, which is how you reach another
  process's terminal at all
- [kaizen](https://github.com/M8SON/kaizen)'s venv, which supplies the wake-word,
  VAD and transcription backends. No voice code is duplicated here; they are
  imported. Point `KAIZEN_ROOT` at that checkout (default `~/linux/kaizen`).

## Install

```bash
git clone https://github.com/M8SON/claude-voice.git
ln -s "$PWD/claude-voice/bin/claude-voice" ~/.local/bin/claude-voice
```

Then start a session and turn voice output on once:

```bash
cd ~/any/project
claude-voice
```

Run `/narrator:on` in the Claude pane. On first use it installs Kokoro and its
dependencies into a dedicated venv at `~/.claude-narrator-venv`, which takes a few
minutes. After that, startup is seconds.

The plugin is loaded with `--plugin-dir` by the launcher, so **a plain `claude`
session has no voice at all** — every hook is declared in `hooks/hooks.json` and
loads only with the plugin. Voice exists where you ask for it and nowhere else.

## Using it

| Command | What it does |
|---|---|
| `claude-voice` | Start, or reattach if a session is already running here |
| `claude-voice --background` | Start without taking over the terminal. Speech still works — you hear replies without seeing them |
| `claude-voice --stop` | Kill this directory's session |
| `claude-voice --review` | Type transcripts into the input line without pressing Enter, so you can read one before it becomes a prompt |
| `claude-voice --print-session` | Print this directory's session name |

Sessions are named `voice-<dirname>`, so voice on one project and voice on another
coexist rather than fighting over a shared name. Running it twice in the same
directory attaches to what is already there rather than starting a second listener.

The session is two panes: Claude Code on top, where you type, and the listener
below, printing status. `Ctrl-b d` detaches without stopping anything. `Ctrl-C` in
the listener pane stops the listener and leaves you a prompt to restart it.

Requirements are checked *before* anything is built, so a missing venv or disabled
voice output shows up as an error in your terminal rather than as silence in a pane
you are not watching.

## Controlling the voice

Slash commands, from upstream, all still work:

| Command | What it does |
|---|---|
| `/narrator:on` | Enable voice output (installs Kokoro on first run) |
| `/narrator:off` | Disable it |
| `/narrator:cast` | Change voice, or list the available ones |
| `/narrator:speed` | Change speaking rate |
| `/narrator:speak` | Say something on demand |
| `/narrator:hush` | Stop what is currently being spoken |

Each has a matching skill, so plain phrasing works too — "be quiet", "talk faster",
"change your voice".

Add `--local` to `on`, `off`, `cast` or `speed` to apply the setting to the current
directory only, via `<cwd>/.claude-code-narrator/config`. Local settings win over
global ones per key; anything unset falls back.

### Playback route

Under WSL, speech sputters — and not because of Kokoro or the daemon. WSLg's
PulseAudio RDP sink plays cleanly for about twenty seconds after resuming from
idle, then starves the audio callback for hundreds of milliseconds at a time,
degrading the longer it stays active and surviving a stream close and reopen.
Measured with an identical 30-second signal: through WSL audio, 30 seconds of
audio took **91.5 seconds** and stuttered; written to a Windows path and played
by `Media.SoundPlayer`, **32.6 seconds**, clean.

So playback picks a route. Set `playback=` in `~/.claude-code-narrator/config`:

| Value | What it does |
|---|---|
| `auto` (default) | Windows when `/proc/version` says WSL *and* `powershell.exe` is reachable; otherwise `sounddevice` |
| `windows` | Always route through Windows |
| `sounddevice` | Always use the system audio server — upstream's behaviour |

An explicit setting always wins, because detection can be wrong and this is the
way out when it is. WSL with interop disabled falls back to `sounddevice` rather
than choosing a route that cannot play: silence would be worse than the sputter
this avoids.

The Windows route costs roughly 0.7–1.2 seconds before each spoken line —
PowerShell startup plus loading the WAV — scaling with the length of the line.
Off WSL, nothing changes and nothing is spawned.

The daemon records which route it chose in `~/.claude-code-narrator/daemon.log`,
along with anything that went wrong while speaking.

Note this routes *around* the WSLg fault rather than fixing it. Anything else on
the machine playing through PulseAudio still sputters.

## Tuning

Set any of these when launching; the launcher forwards them to the listener.

```bash
STT_MODEL=small claude-voice        # more accurate transcription
REPLY_TIMEOUT=20 claude-voice       # longer pause before it stops listening
WAKE_MODEL=alexa claude-voice       # a different wake word
```

Set `WAKE_DISPLAY` to match when you change `WAKE_MODEL` — it is both what the
listener prints and the phrase stripped off the front of a transcript, since the
wake audio is still in the recording:

```bash
WAKE_MODEL=hey_mycroft WAKE_DISPLAY="hey mycroft" claude-voice
```

### Transcription model

`STT_MODEL` selects the faster-whisper model: `tiny` (default), `base`, `small`,
`medium`, `large-v3`. Bigger models hear identifiers and file paths more reliably;
they cost latency after you stop speaking, and memory.

Measured on one machine — a Ryzen 7 250 under WSL2, int8 on CPU, against 18.6
seconds of speech. Treat as a shape, not a promise:

| `STT_MODEL` | RTF | 4-second utterance | peak RSS |
|---|---|---|---|
| `tiny` (default) | 0.03 | ~0.13 s | 0.79 GB |
| `base` | 0.06 | ~0.24 s | 0.91 GB |
| `small` | 0.14 | ~0.56 s | 1.38 GB |

Nothing there is close to real-time, so this is a question of tenths of a second
rather than of feasibility. Memory is the tighter constraint: the Kokoro daemon
holds ~2.2 GB of its own, so on a machine with 8 GB, `small` fits comfortably and
`medium` starts competing with it.

Bigger models also take longer to load the first time — `small` took ~15 seconds on
first use, before it was cached — which lands on listener startup, not on each
utterance.

A larger model will not stop Whisper inventing sentences out of room noise; every
size does that. The VAD-endpoint filter is what handles those.

### Everything else

| Variable | Default | What it does |
|---|---|---|
| `WAKE_MODEL` | `hey_jarvis` | openWakeWord model — `hey_jarvis`, `alexa`, `hey_mycroft`, `hey_marvin` ship with it |
| `WAKE_THRESHOLD` | `0.5` | Higher = fewer false wakes, more missed ones |
| `WAKE_DISPLAY` | `hey jarvis` | The phrase shown, and stripped from transcripts |
| `VAD_BACKEND` | `silero` | `silero` or `rms` |
| `VAD_THRESHOLD` | `0.5` | Speech/silence sensitivity |
| `VAD_MIN_SILENCE_MS` | `700` | Silence needed before an utterance is considered over |
| `REPLY_TIMEOUT` | `12` | Seconds the microphone stays open for a follow-up |
| `EDGE_TIMEOUT` | `300` | Seconds to wait for a spoken reply before falling back to the wake word |
| `MIN_SPEECH_PEAK` | `0.006` | Level backstop for the hallucination filter |
| `VOICE_SAMPLE_LOG` | `~/.claude-code-narrator/voice-samples.jsonl` | Where per-utterance measurements are written |
| `KAIZEN_ROOT` | `~/linux/kaizen` | Where the voice backends are imported from |

Every utterance is logged to `VOICE_SAMPLE_LOG` with its peak, RMS, whether the VAD
endpoint fired, the transcript, and whether it was submitted or dropped. That file
is how to judge a change to any of these against real speech rather than by
impression — and how a dropped utterance is recovered rather than merely felt.

## How it works

```
hook fires → speak.sh → FIFO → speak-daemon.py → Kokoro → speaker
                                     ↓
                            speech-finished marker
                                     ↓
                       listener reopens the microphone
```

`speak-daemon.py` is a persistent process holding the Kokoro pipeline in memory, so
utterances after the first cost milliseconds rather than seconds. It reads JSON
lines from a FIFO and speaks them one at a time. The utterance ending a turn is
flagged `final`; after it drains, the daemon touches `speech-finished`, and that is
the signal the listener waits on.

State lives in `~/.claude-code-narrator/`: `config` (enabled, voice, speed,
playback), the `fifo`, `daemon.pid`, `speech-finished`, and `daemon.log`.
Per-directory overrides live in `<cwd>/.claude-code-narrator/config`.

`daemon.log` is where the daemon's own output goes. It used to go to `/dev/null`,
which is why an intermittent audio fault took an afternoon to localise instead of
being readable in a file.

Hooks, all scoped to plugin sessions:

| Hook | Purpose |
|---|---|
| `SessionStart` | Teach the spoken-line contract; warm Kokoro in the background |
| `Stop` | Speak the turn's spoken line and publish the edge |
| `Notification` | Speak notifications |
| `UserPromptSubmit` | Stop speech when you start typing |

Auto-hush deliberately ignores prompts the listener submitted itself — otherwise
every spoken turn would hush its own reply, since pressing Enter in a pane is a
prompt submission like any other.

## Development

```bash
bash tests/run-all.sh          # everything
bash tests/test-launcher.sh    # one suite
```

15 suites of plain bash, each self-contained, using an `assert`/`check` pattern.
New files matching `tests/test-*.sh` are picked up automatically.

Tests exercise real things where the real thing is the point: real tmux sessions
for the launcher, a real FIFO for the speech queue, real signal delivery for
auto-hush. Only genuinely heavy binaries are stubbed — Claude Code itself, and
kaizen's Python — so no test opens the microphone or starts a model.

Fixtures for the hallucination filter are **measured, not invented**: every peak
and RMS figure in `tests/test-hallucination-filter.sh` was captured from a real
microphone. Three filter designs were refuted that way, one of them after it had
already shipped and started dropping a real "Yes."

## License

MIT, and two copyright holders — see `LICENSE`.

- **Copyright (c) 2026 Shreyas Rao** — the original
  [claude-code-narrator](https://github.com/shreyas-s-rao/claude-code-narrator):
  the Kokoro pipeline, the speech daemon, the slash commands, the per-directory
  config.
- **Copyright (c) 2026 Mason Misch** — the work added here: the hands-free
  listener, the finished-speaking edge, the hallucination filter, the launcher,
  and the changes to how the spoken line is chosen.

The same MIT terms cover both. Forking this carries both notices forward.
