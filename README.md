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

State lives in `~/.claude-code-narrator/`: `config` (enabled, voice, speed), the
`fifo`, `daemon.pid`, and `speech-finished`. Per-directory overrides live in
`<cwd>/.claude-code-narrator/config`.

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

13 suites of plain bash, each self-contained, using an `assert`/`check` pattern.
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

MIT. Copyright (c) 2026 Shreyas Rao for the original work; see `LICENSE`, which
applies to this fork in full.
