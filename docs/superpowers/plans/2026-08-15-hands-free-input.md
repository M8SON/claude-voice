# Hands-Free Voice Input — Implementation Plan

> **Status 2026-08-15: all five tasks implemented, 51 tests green.** Every piece is
> verified individually — wake word and transcription live by ear, tmux submission
> against a real pane, the finished-speaking edge against the running daemon. What has
> NOT been done is the full loop end to end: talking to Claude Code and answering it
> back without touching the keyboard. See Verification below.
>
> Two changes from the plan as written, both forced by what the code turned out to do:
> Task 1 marks the utterance rather than detecting drain, and target validation
> enumerates panes because `display-message -t` accepts anything.

**Goal:** Talk to Claude Code and have it answer, with no keypress at any point — no
hold-space, no Enter. Narrator already owns the output half; this is the input half.

**Architecture:** A listener process reuses kaizen's voice stack unchanged and submits
transcribed text into a `claude` session running inside tmux.

```
wake word ──▶ VAD-endpointed capture ──▶ faster-whisper tiny ──▶ tmux send-keys + Enter
   ▲                                                                      │
   └──────────── mic reopens on narrator's "finished speaking" edge ◀──────┘
```

**Write no voice code.** Everything below reuses what already exists:

| Need | Existing thing | Where |
|---|---|---|
| Wake word | `OpenWakeWordBackend`, `build_wake_backend` | `kaizen/core/voice_backends.py:47`, `:361` |
| Endpointing | `SileroVadBackend`, `build_vad_backend` | `:142`, `:187` |
| STT | `FasterWhisperBackend`, `build_stt_backend` | `:265`, `:306` |
| The loop | `VoiceInterface.wait_for_wake_word()` / `.listen()` | `kaizen/core/voice.py:220`, `:276` |

Construct with `enable_tts=False` — narrator owns output. **Verified 2026-08-15:** this
constructs, selects `cpu:tiny (faster-whisper)`, and shuts down cleanly.

## Global constraints — all measured, do not relitigate

- **`RDPSource` gain must be 40%.** At its default 100% it clips so hard that ambient and
  speech are indistinguishable (both ~0.9995). At 40%: max 0.066, RMS 0.014, no clipping.
  Not persistent across reboots — the launcher must set it.
- **~1.5s of dead air at stream open.** Hold the input stream open; do not reopen per
  utterance or the first 1.5s of every reply is lost.
- **RDP suppresses silence to literal zeros** (RMS ~0.00001). This is a feature for VAD, not
  a fault. Do not "fix" it.
- **`tiny`, not `base`.** RTF 0.20 vs 1.02 measured on real captured speech. `base` is
  real-time and too slow to converse with.
- **Never open the mic while Kokoro is speaking.** This is the whole reason the trigger is
  the finished-speaking edge. Violating it creates a transcription feedback loop.
- **Stay small against upstream.** Everything new lives in `listener/`, a directory upstream
  does not have, so it can never conflict on merge.

---

### Task 1: Narrator publishes a "finished speaking" edge

`speak-daemon.py` knows when playback drains; nothing else can know it. Today it publishes
no such state — only hush via `SIGUSR1` (`:65-72`).

**Files:** modify `speak-daemon.py`, `speak.sh`, `speak-response.sh`; test
`tests/test-speech-state.sh`

**Done 2026-08-15.** Drain detection was the wrong signal: a mid-turn
`speak.sh --force` progress call also drains the queue, so it would have opened the
microphone in the middle of a turn. The edge must mean *the turn ended*.

- [x] `speak.sh` gains `--final`, which adds `"final":true` to the FIFO JSON. Flags parse
      in any order and are never spoken as text.
- [x] `speak-response.sh` passes `--final` on all three end-of-turn paths (marker, fallback,
      plan mode). Mid-turn `--force` calls do not.
- [x] The daemon writes `~/.claude-code-narrator/speech-finished` after `sd.wait()` returns
      for an utterance marked final. Mtime is the signal; contents are an epoch timestamp.
- [x] Verified against the running daemon: a non-final utterance leaves the file absent; a
      final one creates it. Note `speak.sh` returns at enqueue, so any check must allow for
      synthesis plus playback before reading the file.

**Known gap:** a `🔇` turn never reaches the daemon, so it publishes no edge and the mic
does not open. Task 4's wake-word fallback covers this — you say the wake word instead.

**Risk:** this repo is a live dependency — the running `claude --plugin-dir .` session
executes `speak-daemon.py` from this path. Restart the daemon deliberately after editing;
do not leave it half-applied.

---

### Task 2: The listener, printing to stdout

Prove the voice half end to end with no tmux involved, so failures are unambiguous.

**Files:** create `listener/claude_listener.py`, `listener/README.md`

- [ ] Construct `VoiceInterface(enable_tts=False, ...)` with wake, VAD and `tiny` STT.
- [ ] Loop: `wait_for_wake_word()` → `listen()` → print the transcript.
- [ ] kaizen is imported, not copied: run under `kaizen/.venv/bin/python` with kaizen's
      root on `PYTHONPATH`. Record the exact invocation in `listener/README.md`.
- [ ] Verify by ear and eye: say the wake word, speak a sentence, see it printed correctly.

---

### Task 3: tmux submission

**Files:** modify `listener/claude_listener.py`; test `tests/test-tmux-submit.sh`

- [ ] `tmux send-keys -t <target> -l "<text>"` then a separate `send-keys -t <target> Enter`.
      `-l` sends the text literally, which is what keeps punctuation and quotes from being
      interpreted as tmux key names.
- [ ] Target from `CLAUDE_TMUX_TARGET`; fail loudly with a usable message if unset or if the
      pane does not exist. Never guess a pane — submitting into the wrong one types at
      whatever is there.
- [ ] Test against a real throwaway tmux session running `cat`, asserting on what arrives.
      Quotes, apostrophes, semicolons, and a trailing newline are the cases that matter.

---

### Task 4: Auto-listen on the finished-speaking edge

This is what removes the wake word from every turn.

**Files:** modify `listener/claude_listener.py`

- [ ] Watch the Task 1 mtime. On change, open a listen window immediately.
- [ ] `listen(max_wait_seconds=N)`: if you say nothing, fall back to wake-word mode rather
      than hanging with the mic open.
- [ ] Wake word only cold-starts a conversation; follow-ups come from the edge.
- [ ] Verify the loop closes: ask a question by voice, hear the answer, answer back without
      touching the keyboard, and confirm the reply submits.

---

### Task 5: Launcher and documentation

**Files:** create `listener/run.sh`; modify `README.md`

- [ ] `run.sh` sets `pactl set-source-volume RDPSource 40%`, then starts the listener.
- [ ] Document the tmux requirement and the one-time `wsl --shutdown` mic fix.
- [ ] Note that the gain reset is required after every reboot.

---

## Verification

End-to-end, by ear, no keyboard:

1. `tmux new -s voice`, run `claude --plugin-dir .` in it, `/narrator:on`
2. `listener/run.sh` in another pane, with `CLAUDE_TMUX_TARGET` pointing at the claude pane
3. Say "hey jarvis", ask a question, hear the answer, reply out loud, hear the next answer

Headless: `bash tests/run-all.sh` stays green — currently 22 tests, plus Tasks 1 and 3.

## Deferred

- **Barge-in.** `VoiceInterface` has `barge_in_enabled`; interrupting mid-sentence is a
  later problem.
- **Gain auto-calibration.** 40% is measured for this room and mic, not derived.
- **Whisper accuracy on technical vocabulary.** `tiny` was verified on counting, which is
  easy. If it mangles identifiers, `build_stt_backend` already supports swapping the model.
