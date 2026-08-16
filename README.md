# claude-voice — talk to Claude Code, hear it answer

Hands-free voice for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).
Say a wake word, speak, and hear the reply — then just keep talking. Everything runs
locally: [Kokoro](https://github.com/hexgrad/kokoro) for speech,
[openWakeWord](https://github.com/dscripka/openWakeWord), Silero VAD and
faster-whisper for listening. No cloud APIs.

```bash
cd ~/any/project
claude-voice
```

Then say **"hey jarvis"** and talk. When the reply finishes speaking, the microphone
reopens on its own — follow-ups need no wake word. Stay quiet for twelve seconds and
it drops back to waiting for one.

```
Microphone → wake word → Whisper → tmux pane → Claude Code
                                                    ↓
    microphone reopens ← finished-speaking edge ← Kokoro → speaker
```

The loop closes on that **finished-speaking edge**: a marker the speech daemon
touches once a turn's last utterance has actually finished playing. Opening the
microphone on that signal — and only then — is what stops the listener transcribing
Claude's own voice and submitting it back as a new prompt.

See [Hands-free voice](#hands-free-voice-fork-addition) for the commands, and
[`listener/README.md`](listener/README.md) for the input half's internals.

## Fork notes

A fork of [claude-code-narrator](https://github.com/shreyas-s-rao/claude-code-narrator)
(MIT © 2026 Shreyas Rao). Upstream speaks; this fork also listens.

**Output — changes to how it speaks:**

1. **Spoken-line contract.** Instead of reading the first ~1000 characters of a response, it
   speaks a line the assistant writes deliberately: a final line prefixed `🔊 `, compressed for
   the ear but carrying the full situation. A line of exactly `🔇` keeps the turn silent.
   Short answers that already read well aloud carry no marker and are spoken as written,
   via the same path that catches an unmarked long response — upstream's truncation.
2. **No per-tool chatter.** The `PostToolUse` hook is removed; mid-turn progress and errors are
   spoken deliberately via `speak.sh --force`.
3. **`SessionStart` rules injection.** The contract is taught to the assistant at session start,
   gated on voice being enabled.
4. **The daemon is warmed at `SessionStart`.** Loading Kokoro takes ~13s and the `Stop` hook's
   budget is 10s, so on a cold daemon the first turn was killed mid-load: silent, and with no
   finished-speaking edge to reopen the microphone. The load now happens off the critical path.

**Input — new in this fork:**

5. **A hands-free listener** (`listener/`), built on kaizen's voice backends. Claude Code's own
   voice input is push-to-talk by construction, so input is built outside it.
6. **The finished-speaking edge**, published by the daemon after a turn's last utterance drains,
   so the microphone can reopen without hearing the assistant.
7. **A hallucination filter.** Whisper transcribes an empty room as speech — six silent windows
   produced *"Love it, love it, love it."* and a 111-character run-on. Neither transcript length
   nor audio level separates those from real speech (a quiet "Yes." measures below a loud silent
   room), so the VAD endpoint decides, with a level floor only as a backstop.
8. **`claude-voice`**, a launcher that starts Claude in the current directory with a listener
   already wired to it, one session per project.

Every hook is declared in `hooks/hooks.json`, so a plain `claude` session has no voice at all —
voice exists only in sessions started by `claude-voice`.

Upstream is retained as the `upstream` git remote.

## Prerequisites

For speaking:

- Python 3.9+ (tested on 3.13)
- macOS or Linux with audio output (speakers or headphones)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI

Additionally, for listening:

- A working microphone
- `tmux` — the listener types transcripts into a pane, which is how you reach
  another process's terminal at all
- [kaizen](https://github.com/M8SON/kaizen)'s venv, for the wake-word, VAD and
  transcription backends. No voice code is duplicated here; they are imported.
  Point `KAIZEN_ROOT` at that checkout (default `~/linux/kaizen`).

## Installation

### From GitHub (recommended)

In Claude Code, run these slash commands:

1. Add the marketplace:
   ```
   /plugin marketplace add shreyas-s-rao/claude-code-narrator
   ```

2. Install the plugin:
   ```
   /plugin install narrator
   ```

3. Reload:
   ```
   /reload-plugins
   ```

> **Linux note:** If `/tmp` is a separate filesystem (tmpfs), plugin installation may fail with `EXDEV: cross-device link not permitted`. Fix by setting TMPDIR before launching Claude Code:
> ```bash
> mkdir -p ~/.cache/tmp && TMPDIR=~/.cache/tmp claude
> ```
> Then run the install commands above in that session. This is a [Claude Code platform limitation](https://github.com/anthropics/claude-code/issues/14799), not specific to this plugin.

### From local directory

If you've cloned the repo locally:

1. Add the marketplace:
   ```
   /plugin marketplace add /path/to/claude-code-narrator
   ```

2. Install and reload as above

### Direct plugin loading (development)

```bash
claude --plugin-dir /path/to/claude-code-narrator
```

## Getting Started

1. **Enable narrator**: Type `/narrator:on` in Claude Code
2. Kokoro TTS and all dependencies are **automatically installed** into a dedicated venv (`~/.claude-narrator-venv`) on first run. This takes a few minutes.
3. Once installed, the narrator speaks tool steps and responses aloud.
4. **Change voice**: `/narrator:cast af_bella` (or any voice from the table below)
5. **Silence**: `/narrator:hush` to stop current speech, `/narrator:off` to disable entirely

## Hands-free voice (fork addition)

Upstream speaks; this fork also listens. `claude-voice` launches both halves
together — Claude Code in your current directory, and a wake-word listener
underneath it already wired to that pane.

```bash
ln -s "$PWD/bin/claude-voice" ~/.local/bin/claude-voice   # once
cd ~/any/project
claude-voice
```

Then say **"hey jarvis"** and talk. After a reply finishes, the microphone
reopens on its own — follow-ups need no wake word. Stay quiet for 12 seconds
and it drops back to waiting for one.

| Command | Description |
|---------|-------------|
| `claude-voice` | Start, or reattach if a session is already running here |
| `claude-voice --background` | Start without taking over the terminal. Speech still works: you hear replies without seeing them |
| `claude-voice --stop` | Kill this directory's session |
| `claude-voice --review` | Type transcripts into the input line without pressing Enter, so you can read one before it becomes a prompt |
| `claude-voice --print-session` | Print this directory's session name |

Sessions are named per directory (`voice-<dirname>`), so voice on one project
and voice on another coexist rather than fighting over a shared name. Running
it twice in the same directory attaches to what is already there.

Requires `/narrator:on`, tmux, and kaizen's venv for the wake-word, VAD, and
transcription backends (`KAIZEN_ROOT`, default `~/linux/kaizen`). All three are
checked before anything is built, so a failure shows up in your terminal rather
than as silence in a pane you are not watching.

## Commands

| Command | Description |
|---------|-------------|
| `/narrator:on` | Enable voice output (auto-installs Kokoro on first run) |
| `/narrator:off` | Disable voice output |
| `/narrator:cast [voice]` | Change voice or list available voices |
| `/narrator:speed [value]` | Change speech speed (0.5–2.0, default 1.1) |
| `/narrator:speak [text]` | Speak on demand, even if narrator is off |
| `/narrator:hush` | Silence all current and queued speech |

All commands accept `--local` to apply settings to the current directory only (see [Per-Directory Config](#per-directory-config)).

## Available Voices

| Voice | Gender | Description |
|-------|--------|-------------|
| `af_heart` | Female | Warm, expressive (default) |
| `af_bella` | Female | Clear, professional |
| `af_nicole` | Female | Soft, gentle |
| `af_sarah` | Female | Bright, energetic |
| `af_sky` | Female | Calm, composed |
| `am_adam` | Male | Deep, authoritative |
| `am_michael` | Male | Warm, friendly |
| `am_fenrir` | Male | Bold, commanding |

## What Gets Spoken

| Event | What you hear |
|-------|---------------|
| Tool use (Read, Write, Bash, etc.) | Short description, e.g. "Reading file settings dot json" |
| Text between tool calls | The assistant's intermediate commentary |
| Final response | First ~1000 characters, ending at a sentence boundary |
| Notification | Title and message from Claude Code notifications |
| User input | Speech is automatically silenced when you type or click |

## Per-Directory Config

You can override narrator settings per directory, which is useful when running multiple Claude Code sessions with different voices.

```
/narrator:on --local          # enable narrator in this directory only
/narrator:cast --local am_adam  # use a different voice in this directory
/narrator:speed --local 1.5    # use a different speed in this directory
/narrator:off --local         # disable narrator in this directory only
```

Local settings are stored in `<cwd>/.claude-code-narrator/config`. Only the keys you set locally are overridden — missing keys fall back to the global config at `~/.claude-code-narrator/config`.

**Add the local config file to your `.gitignore`** so it's not committed:

```bash
echo .claude-code-narrator >> .gitignore
```

### Multi-Session Behavior

All sessions share a single daemon and FIFO (sequential playback, no overlap). Each session's utterances carry their own voice and speed settings, so if session A uses `am_adam` and session B uses `af_bella`, utterances interleave with the correct voices.

## Documentation

- [Architecture](docs/architecture.md) — pipeline diagram, state management, what gets spoken
- [Commands](docs/commands.md) — detailed reference for each command
- [Project Structure](docs/project-structure.md) — full directory tree with file descriptions

## Development

To work on the plugin locally, clone the repo and load it:

```bash
git clone https://github.com/shreyas-s-rao/claude-code-narrator
```

**Option 1:** Load directly (no install needed, good for quick iteration):

```bash
claude --plugin-dir /path/to/claude-code-narrator
```

**Option 2:** Install via local marketplace (persists across sessions):

1. In Claude Code, run `/plugin marketplace add /path/to/claude-code-narrator`
2. Run `/plugin install narrator` then `/reload-plugins`

Changes to hook scripts must be copied to the plugin cache (`~/.claude/plugins/cache/claude-code-narrator/narrator/<version>/`) for testing, since hooks run from the cache path, not the source repo. `/reload-plugins` does not refresh the cache unless the version changes.

Run tests with:

```bash
bash tests/run-all.sh
```

Tests are plain bash scripts using an `assert_eq` pattern. New test files matching `tests/test-*.sh` are automatically picked up by `run-all.sh`.

## Contributing

Narrator is a personal hobby project, built and tested on one machine (Apple Silicon, macOS Sequoia, Python 3.13). It almost certainly has rough edges — things may break on different hardware, OS versions, or Python setups.

Contributions are very welcome, including:

- **Bug reports** — open an issue describing your setup (OS, Python version, audio hardware) and what went wrong
- **Fixes** — PRs are welcome; keep changes small and focused
- **New pronunciation fixes** — uppercase/mixed-case words that Kokoro mispronounces (see `speak.sh`)
- **New voice support** — Kokoro supports more voices than the 8 listed; contributions to test and document them are welcome
- **Better text processing** — improvements to the TTS text replacement pipeline in `speak.sh`

### Things that are likely untested

- Linux audio (PortAudio/sounddevice should work, but not verified beyond install)
- Python versions below 3.11
- Intel Macs
- macOS versions before Sequoia
- Non-English Kokoro voices
- Running multiple daemons (only one daemon/FIFO is supported — all sessions share it)
- Very long responses (speech is truncated at ~1000 characters for final responses)

If something doesn't work, check whether the daemon is running (`cat ~/.claude-code-narrator/daemon.pid`) and try restarting it with `/narrator:hush` followed by any action that triggers speech.

## License

MIT License
