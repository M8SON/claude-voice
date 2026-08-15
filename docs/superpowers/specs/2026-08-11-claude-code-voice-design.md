# Voice conversation with Claude Code — design

**Date:** 2026-08-11
**Status:** approved, not yet implemented
**Repo:** fork of [shreyas-s-rao/claude-code-narrator](https://github.com/shreyas-s-rao/claude-code-narrator) @ `393dddf` (v0.1.1, MIT, Shreyas Rao)

## Goal

Hold a spoken coding conversation with Claude Code: talk to it, hear it answer. Speech is an
I/O layer over the existing session — same tools, same MCP servers, same hooks. Nothing about
the agent changes.

Explicitly preserved: MemPalace and Nexus keep working untouched. The spoken line is
*additional* to the full text response, so transcript mining and PreCompact see the complete
response, not a compressed one.

## Decision: fork, don't build

Three prior projects cover most of this design. Narrator (24★, 36 commits) already solves the
warm daemon, playback queue, interruption, and speech text normalization. Building our own
would re-derive all of it to change three things.

Rejected alternatives:

- **Build from scratch** — the WSL gap that justified it turned out to be environmental, not a
  code gap (see Environment). Once PortAudio saw the `pulse` device, narrator's existing
  `sounddevice` path became viable unmodified.
- **PTY wrapper owning a `claude` subprocess** — enables barge-in mid-sentence, but fragile
  against TUI rendering and it sits between the user and the session.
- **Kaizen drives `claude -p` headless** — reuses kaizen's whole voice stack, but puts a
  different agent in front and loses interactive tool approvals and visible diffs.
- **Piper TTS** — rejected 2026-07-18, voice quality materially worse than Kokoro.

## Inherited unchanged

| Component | What it gives us |
|---|---|
| `hooks/hooks.json` | `Stop`, `PostToolUse`, `Notification` wiring as a Claude Code plugin |
| `speak-daemon.py` | Kokoro pipeline held warm; FIFO reader; PID file written only after load, so clients know when it's ready |
| Hush (`SIGUSR1`) | Timestamp-based: utterances queued before the interrupt are discarded, not played late |
| `hush-on-input.sh` | Auto-silence when the user starts typing. Registered in `~/.claude/settings.json` as `UserPromptSubmit` (not in `hooks.json`) so it persists across sessions; managed by `/narrator:on` and `/narrator:off` |
| `speak.sh` | Text normalization — filename dot expansion, operators to words, abbreviation expansion, and pronunciation fixes for tokens Kokoro mangles (README, JSON, API). `--force` bypasses the enabled check |
| Config | Global `~/.claude-code-narrator/config` + per-project override for enabled/voice/speed; `daemon.lock` (atomic mkdir) prevents concurrent daemon starts; `last-spoken` dedupes |
| Commands/skills | `/narrator:on`, `:off`, `:hush`, `:speed`, `:cast`, `:speak` |

`last_assistant_message` arrives directly in the Stop hook payload — no transcript parsing, so
no fragility across Claude Code versions.

## Changes

### 1. Spoken-line contract (the substance)

Narrator speaks the first ~1000 characters of the response, sentence-aligned. Replace with:
extract an explicit spoken line from `last_assistant_message`; fall back to narrator's
truncation when absent, so silence is never the failure mode.

The line is **compressed, not simplified**. Requirement, in the user's words: "shorter than
text because it's spoken, but should not skip on detail or complexity needed to understand the
situation." It conveys the *situation* — what happened, what it means, and the open decision if
there is one:

> "Tests pass except the auth one, which is flaky because it hits the real clock — I can freeze
> time or mark it skip."

Three seconds of speech carrying the decision content of a paragraph. Not "first sentence", not
"tests mostly pass".

Rules live in an always-loaded skill inside the plugin, so the discipline ships with the plugin
rather than living in the user's `CLAUDE.md`.

**Marker format:** the final line of the response, prefixed `🔊 `. Extraction is a one-liner
(`grep '^🔊 '`, last match wins), it survives markdown rendering untouched, and it reads as a
deliberate aside rather than clutter in the terminal.

**Silence marker:** a final line of exactly `🔇` means say nothing this turn, and suppresses the
fallback. Housekeeping turns — MemPalace save-hook confirmations and similar — use it, so the
assistant never narrates its own bookkeeping.

**Fallback precedence:** `🔊` line → speak it. `🔇` → speak nothing. Neither → speak narrator's
sentence-aligned truncation.

### 2. Mid-turn narration becomes deliberate

Narrator announces every tool call via `PostToolUse` ("Reading file settings dot json"), which
gets grating over a long session. Disable that hook; narrate deliberately instead by calling
`speak.sh --force` when something is genuinely worth saying — before a long operation, or when
something breaks mid-turn.

Note what else this drops: `speak-step.sh` also parses the transcript JSONL to speak
intermediate text blocks written between tool calls. Disabling the hook silences those too.
That is intended — deliberate narration replaces both.

Wanted aloud: end-of-turn line, permission prompts (`Notification`, inherited), mid-turn
progress, errors and blocked work.

### 3. Audio output path

Keep `sounddevice` (works now, see Environment). `paplay` is a documented fallback, not the
plan — `libpulse0` talks to WSLg directly and skips PortAudio and ALSA.

### Not changing: Kokoro loading

Narrator uses `kokoro.KPipeline` (PyTorch, ~9s cold start, <50ms warm synth). Do **not** swap to
kokoro-onnx int8 on the assumption it's faster: kaizen's code comment claims 2-3× but the later
2026-07-18 measurement found int8 ~2× *slower* on ARMv8.2 with fp32 the CPU floor. Unmeasured on
x86. Warm synth is already fast enough; revisit only if cold start proves annoying, and measure
first.

## Architecture

```
you (hold-to-talk via /voice) ──> Claude Code ──> assistant, working
                                                        │
                    ┌───────────────────────────────────┤
                    │ mid-turn / error: speak.sh (deliberate)
                    │ end of turn: Stop hook extracts the spoken line
                    │ permission prompt: Notification hook
                    ↓
              speak.sh ──FIFO──> speak-daemon.py ──> Kokoro (warm) ──> sounddevice ──> WSLg ──> speakers
                    ↑
              /hush, typing ──SIGUSR1──> discard queued + stop playback
```

Input is Claude Code's own `/voice` dictation (hold-to-talk or tap-to-toggle, `autoSubmit` on
release). Not our code.

Kaizen integration, if wanted later, attaches at the FIFO — kaizen writes to the same queue.
Out of scope here.

## Environment (verified 2026-08-11, WSL2)

Audio was entirely non-functional at session start; all of it is now fixed except mic passthrough.

- **No sound hardware.** `/dev/snd` holds only `timer`. WSL2 emulates no sound card; WSLg bridges
  to Windows over RDP via `unix:/mnt/wslg/PulseServer` (`RDPSink` out, `RDPSource` in, mono 44.1kHz).
- **PortAudio was blind.** Built with host APIs `['ALSA', 'OSS']` — no PulseAudio — so it asked
  ALSA, ALSA found no cards, and `sd.query_devices()` returned 0 devices.
- **Fix:** `sudo apt install libasound2-plugins pulseaudio-utils sox libsox-fmt-pulse`.
  PortAudio now enumerates 1 device (`pulse`, 32 in / 32 out). Playback confirmed by ear.
  This also unblocks kaizen's voice backends on this machine.
- **Mic passthrough is broken.** Windows side is healthy — `Microphone Array (Realtek(R) Audio)`
  `state=1` (active) and confirmed working in Windows itself; all three privacy gates `Allow`;
  `RDPSource` unmuted at 100% and streaming. But captured samples are digital silence
  (peak 1/32767 via `parec`). Diagnosis: stale WSLg session. **Fix: `wsl --shutdown` and restart**
  (kills the Claude Code session; resume with `claude -c`). Not yet performed.

Output-only work is unblocked regardless — the mic affects input only, and input is Claude Code's
feature, not our code.

### Update 2026-08-14

- **`jq` was never installed.** Upstream's `speak-response.sh` parses the hook payload with it and
  the README's Prerequisites never declares it, so the plugin could not have run here at all,
  independent of audio. Installed via `sudo apt install -y jq` (1.7.1, `/usr/bin/jq`). Note `sudo`
  cannot prompt from inside Claude Code — the `!` prefix provides no TTY.
- **Output works end to end.** Kokoro installed, `/narrator:on` enabled, spoken line audible.
  Measured on this x86 machine: **cold start 13.1s** (upstream claims ~10s), **warm enqueue 56ms
  and 49ms** (upstream claims <50ms). The warm figure is FIFO enqueue only — synthesis and
  playback happen afterwards in the daemon, so it is not perceived latency.
- **The plan's cold-start recipe is wrong.** `pkill -f speak-daemon.py` matches its own command
  line and kills the calling shell; use `pkill -f '[s]peak-daemon.py'`. The daemon also ignores
  SIGTERM while blocked reading the FIFO and needs `kill -9`. Without both fixes the "cold"
  measurement silently measures a still-running warm daemon.
- **Mic passthrough is still dead**, `wsl --shutdown` still not performed. Measured with `rec`:
  ambient max 0.000153 / RMS 0.000014; **five seconds of continuous speech max 0.000275 / RMS
  0.000015**. Speech is indistinguishable from an empty room, confirming the channel carries no
  signal rather than a weak one.
- **`/voice` is not entitlement-gated — the capability does not exist.** Grepping the CLI bundle
  at `2.1.233` returns zero hits for `VOICE_HANDSFREE`, `handsFree`, `hands-free`, and
  `tap to toggle`; `hold space` appears 4 times. Claude Code's voice input is push-to-talk by
  construction. Hands-free input cannot come from Claude Code and must be built outside it.

## Risks

- ~~**`/voice` may be entitlement-gated.**~~ **Resolved 2026-08-14: worse than gated — absent.**
  The settings schema still references `feature(VOICE_HANDSFREE)`, but no such string exists in the
  shipped bundle, and neither does any hands-free or tap-to-toggle affordance. Voice input is
  push-to-talk only. The input half must come from kaizen's Whisper stack; see the Environment
  update above.
- **Discipline dependency.** The spoken line only exists if the assistant emits it. The fallback
  truncation bounds the damage to "verbose", never "silent".
- **`wsl --shutdown` is disruptive** and unverified as the mic fix.
- **Upstream divergence.** Narrator is one author, 36 commits. Our changes touch `speak-response.sh`
  and `hooks.json`; keeping them small preserves the ability to merge upstream.

## Implementation order

**Dev-workflow trap:** hooks execute from the plugin cache
(`~/.claude/plugins/cache/.../narrator/<version>/`), not this repo, and `/reload-plugins` does not
refresh the cache unless the version changes. Every script edit must be copied to the cache — or
the version bumped — before it can be tested. Budget for this in every step below.

1. **Run narrator unmodified on this box.** Install deps into its venv at `~/.claude-narrator-venv`
   (Python 3.13 needs kokoro/misaki from git with `--no-deps` plus manual cp313 spacy wheels — see
   its `kokoro-speak.py` bootstrap), start the daemon, speak a line.
   → verify: Kokoro audio comes out of the speakers through WSLg; record cold-start and warm-synth times.
2. **Fix mic + verify `/voice`.** `wsl --shutdown`, restart, `rec` a speaking sample and check the
   level is real, then `/voice` and confirm hold-to-talk is offered.
   → verify: non-trivial RMS on capture; dictation transcribes into the prompt.
3. **Spoken-line contract.** Choose the marker; rewrite `speak-response.sh` to extract it with
   fallback; write the always-loaded skill defining how to write the line.
   → verify: a turn with 🔊 speaks only that line; 🔇 speaks nothing; neither speaks the truncation.
4. **Disable `PostToolUse`; wire deliberate narration.**
   → verify: no per-tool chatter; a manual `speak.sh` call speaks mid-turn.
5. **Real session.** Hold an actual spoken coding conversation and tune line style from what it
   feels like to listen to.
   → verify: the user can follow the work without reading the screen.

## Attribution

Fork of claude-code-narrator, MIT © 2026 Shreyas Rao. Upstream retained as the `upstream` remote;
LICENSE and attribution preserved.
