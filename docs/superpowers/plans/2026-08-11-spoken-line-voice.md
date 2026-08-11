# Voice Conversation for Claude Code — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn this fork of claude-code-narrator into a voice layer that speaks one deliberate, compressed line per turn instead of reading the assistant's response aloud.

**Architecture:** Claude Code plugin. Hooks fire on session events, extract text, and enqueue it to a FIFO read by a persistent Python daemon holding Kokoro TTS warm in memory. We change what gets enqueued, not how it plays: the `Stop` hook extracts an explicit `🔊` line from the assistant's final message, and per-tool chatter is replaced by deliberate `speak.sh --force` calls.

**Tech Stack:** Bash (hooks, enqueuer, tests), Python 3 (Kokoro daemon), `jq`, Kokoro TTS via `~/.claude-narrator-venv`, PulseAudio/WSLg for audio out.

## Global Constraints

- **Marker is `🔊 `** as the prefix of a line; the spoken text is everything after it. Last match wins.
- **Silence marker is a line of exactly `🔇`.** It suppresses the fallback.
- **Precedence:** `🔇` present → speak nothing. Else `🔊` line present → speak only that. Else → narrator's sentence-aligned truncation. Silence is never the failure mode of a *missing* marker.
- **The emoji is never spoken.** Strip markers from every path that reaches `speak.sh`, including the plan-mode and fallback branches.
- **Do not swap Kokoro to kokoro-onnx int8.** Measured ~2× *slower* on ARMv8.2 (2026-07-18); the in-repo "2-3× faster" comment is stale. Unmeasured on x86. Keep `kokoro.KPipeline`.
- **Piper TTS is rejected** (voice quality, 2026-07-18). Do not introduce it.
- **Keep `sounddevice`** for playback. `paplay` is a fallback only if sounddevice regresses.
- **Hooks run from the plugin cache, not this repo.** `/reload-plugins` does not refresh the cache unless the version changes. Develop with `claude --plugin-dir` (verified in Task 1) or copy to the cache before testing.
- **Preserve upstream attribution.** MIT © 2026 Shreyas Rao; `LICENSE` and the `upstream` remote stay.
- **Plugin keeps the name `narrator`** and its `/narrator:*` commands. Renaming is churn across `plugin.json`, `marketplace.json`, all commands, all skills, and the README for no functional gain.

---

## File Structure

| File | Responsibility | Status |
|---|---|---|
| `hooks/scripts/spoken-line.sh` | Sourceable pure-bash functions: `extract_spoken_line`, `strip_marker_lines`. No I/O beyond stdout. | Create |
| `tests/test-spoken-line.sh` | Tests sourcing the real functions (not a copy of the regex). | Create |
| `hooks/scripts/speak-response.sh` | `Stop` hook. Gains marker extraction ahead of the existing truncation. | Modify |
| `hooks/hooks.json` | Drop `PostToolUse`; add `SessionStart`. | Modify |
| `hooks/scripts/inject-spoken-line-rules.sh` | `SessionStart` hook emitting the contract as `additionalContext`, gated on enabled state. | Create |
| `README.md`, `CLAUDE.md` | Document the fork's divergence. | Modify |

`speak.sh`, `speak-daemon.py`, `speak-daemon.sh`, `hush-on-input.sh`, `kokoro-speak.py`, `extract-command.sh` are **untouched**.

---

### Task 1: Verify the inherited stack works on this machine

No code. This is the empirical gate: if Kokoro can't reach the speakers through WSLg, every later task is built on sand.

**Files:** none

**Interfaces:**
- Consumes: nothing
- Produces: a working plugin install and two measured numbers (cold start, warm synth) recorded in the commit message of Task 2

- [ ] **Step 1: Confirm the dev-loading flag exists**

Run: `claude --help 2>&1 | grep -A2 -- "--plugin-dir"`
Expected: the flag is documented. If it is absent, every later task must copy scripts to
`~/.claude/plugins/cache/.../narrator/<version>/` before testing — note that in the plan and continue.

- [ ] **Step 2: Load the plugin from this repo**

```bash
cd /home/daedalus/linux/claude-voice
claude --plugin-dir .
```

In that session, run `/narrator:on`. First run installs Kokoro into `~/.claude-narrator-venv` and takes several minutes.

If plugin installation fails with `EXDEV: cross-device link not permitted`, relaunch as:
```bash
mkdir -p ~/.cache/tmp && TMPDIR=~/.cache/tmp claude --plugin-dir .
```

- [ ] **Step 3: Prove audio reaches the speakers**

```bash
echo "Narrator is speaking through WSLg." | bash hooks/scripts/speak.sh --force
```
Expected: audible speech. If silent, check `~/.claude-code-narrator/daemon.pid` exists and
`python3 -c "import sounddevice as sd; print(len(sd.query_devices()))"` returns ≥1 inside
`~/.claude-narrator-venv`.

- [ ] **Step 4: Measure cold start and warm synth**

```bash
pkill -f speak-daemon.py || true
rm -f ~/.claude-code-narrator/daemon.pid
time (echo "Cold start measurement." | bash hooks/scripts/speak.sh --force)
time (echo "Warm synth measurement." | bash hooks/scripts/speak.sh --force)
```
Record both numbers. Expected from upstream docs: ~10s cold, <50ms warm (plus playback duration).

- [ ] **Step 5: Confirm the baseline behavior we intend to replace**

Have a normal exchange in the plugin session and listen. Expected: it reads up to ~1000 characters
of the reply, and announces tool calls. That is the behavior Tasks 3 and 4 remove.

---

### Task 2: Spoken-line extraction functions

**Files:**
- Create: `hooks/scripts/spoken-line.sh`
- Test: `tests/test-spoken-line.sh`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `extract_spoken_line <message>` — prints the spoken text on stdout; returns `0` (speak), `1` (no marker, caller falls back), `2` (silent).
  - `strip_marker_lines <message>` — prints the message with all `🔊`/`🔇` lines removed.

- [ ] **Step 1: Write the failing test**

Create `tests/test-spoken-line.sh`:

```bash
#!/usr/bin/env bash
# Tests for the 🔊 / 🔇 spoken-line contract.
# Run: bash tests/test-spoken-line.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../hooks/scripts/spoken-line.sh"

PASS=0
FAIL=0

# assert_extract <description> <input> <expected_status> <expected_stdout>
assert_extract() {
    local description="$1" input="$2" expected_status="$3" expected_text="$4"
    local actual_text actual_status

    set +e
    actual_text=$(extract_spoken_line "$input")
    actual_status=$?
    set -e

    if [[ "$actual_status" == "$expected_status" && "$actual_text" == "$expected_text" ]]; then
        echo "  PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $description"
        echo "        expected: status=$expected_status text=\"$expected_text\""
        echo "        actual:   status=$actual_status text=\"$actual_text\""
        FAIL=$((FAIL + 1))
    fi
}

# assert_strip <description> <input> <expected_stdout>
assert_strip() {
    local description="$1" input="$2" expected="$3"
    local actual
    actual=$(strip_marker_lines "$input")
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $description"
        echo "        expected: \"$expected\""
        echo "        actual:   \"$actual\""
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Speak marker ==="
assert_extract "simple line" \
    "Here is the full answer."$'\n'"🔊 Tests pass, one is flaky." \
    0 "Tests pass, one is flaky."
assert_extract "marker is only content" \
    "🔊 Done." \
    0 "Done."
assert_extract "last marker wins" \
    "🔊 First."$'\n'"body"$'\n'"🔊 Second." \
    0 "Second."
assert_extract "marker not on last line" \
    "🔊 Spoken."$'\n'"Trailing prose." \
    0 "Spoken."
assert_extract "leading whitespace tolerated" \
    "   🔊 Indented." \
    0 "Indented."
assert_extract "extra space after marker" \
    "🔊    Padded." \
    0 "Padded."

echo ""
echo "=== Silence marker ==="
assert_extract "silence alone" \
    "Housekeeping done."$'\n'"🔇" \
    2 ""
assert_extract "silence wins over speak" \
    "🔊 Should not be spoken."$'\n'"🔇" \
    2 ""
assert_extract "silence with whitespace" \
    "  🔇  " \
    2 ""

echo ""
echo "=== No marker ==="
assert_extract "plain message" \
    "Just a normal response with no markers." \
    1 ""
assert_extract "empty speak marker falls back" \
    "Body text."$'\n'"🔊" \
    1 ""
assert_extract "empty message" \
    "" \
    1 ""
assert_extract "emoji mid-sentence is not a marker" \
    "The 🔊 icon means audio." \
    1 ""

echo ""
echo "=== Stripping ==="
assert_strip "removes speak line" \
    "Body."$'\n'"🔊 Spoken." \
    "Body."
assert_strip "removes silence line" \
    "Body."$'\n'"🔇" \
    "Body."
assert_strip "leaves plain text alone" \
    "Body."$'\n'"More body." \
    "Body."$'\n'"More body."
assert_strip "removes indented marker" \
    "Body."$'\n'"  🔊 Spoken." \
    "Body."

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-spoken-line.sh`
Expected: FAIL — `hooks/scripts/spoken-line.sh: No such file or directory`

- [ ] **Step 3: Write the implementation**

Create `hooks/scripts/spoken-line.sh`:

```bash
#!/usr/bin/env bash
# Spoken-line contract helpers.
#
# A response may end with a line prefixed "🔊 " carrying a compressed spoken
# version of the answer, or a line of exactly "🔇" meaning say nothing.
# These functions are sourced by hook scripts; they perform no I/O beyond stdout.

# Trim leading and trailing whitespace from a string.
_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# extract_spoken_line <message>
#   stdout: the spoken text (marker stripped) when one is present
#   return: 0 speak, 1 no marker (caller should fall back), 2 stay silent
extract_spoken_line() {
    local msg="${1:-}"
    local line content result=""
    local found_speak=false found_silent=false

    while IFS= read -r line; do
        line="$(_trim "$line")"
        if [[ "$line" == "🔇" ]]; then
            found_silent=true
        elif [[ "$line" == "🔊"* ]]; then
            content="$(_trim "${line#🔊}")"
            if [[ -n "$content" ]]; then
                found_speak=true
                result="$content"
            fi
        fi
    done <<< "$msg"

    if [[ "$found_silent" == true ]]; then
        return 2
    fi
    if [[ "$found_speak" == true ]]; then
        printf '%s\n' "$result"
        return 0
    fi
    return 1
}

# strip_marker_lines <message>
#   stdout: the message with every marker line removed
strip_marker_lines() {
    local msg="${1:-}"
    printf '%s\n' "$msg" | grep -vE '^[[:space:]]*(🔊|🔇)' || true
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-spoken-line.sh`
Expected: PASS — `Results: 17 passed, 0 failed`

- [ ] **Step 5: Run the whole suite for regressions**

Run: `bash tests/run-all.sh`
Expected: `All test suites passed!`

- [ ] **Step 6: Commit**

```bash
git add hooks/scripts/spoken-line.sh tests/test-spoken-line.sh
git commit -m "feat(spoken-line): extract 🔊 / 🔇 markers from assistant messages

Pure-bash helpers with no I/O. Precedence: 🔇 silences, 🔊 speaks
(last match wins), neither returns 1 so the caller falls back.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Wire the contract into the Stop hook

**Files:**
- Modify: `hooks/scripts/speak-response.sh:1-86` (whole file)

**Interfaces:**
- Consumes: `extract_spoken_line`, `strip_marker_lines` from `hooks/scripts/spoken-line.sh`
- Produces: nothing consumed by later tasks

- [ ] **Step 1: Write the failing test**

Append to `tests/test-spoken-line.sh`, immediately before the `echo "=============================="` results block:

```bash
echo ""
echo "=== Stop hook end-to-end ==="

# Drive speak-response.sh with a fake speak.sh on PATH that records its stdin.
assert_hook() {
    local description="$1" message="$2" expected="$3"
    local tmpdir actual
    tmpdir=$(mktemp -d)

    mkdir -p "$tmpdir/scripts"
    cp "$SCRIPT_DIR/../hooks/scripts/speak-response.sh" "$tmpdir/scripts/"
    cp "$SCRIPT_DIR/../hooks/scripts/spoken-line.sh" "$tmpdir/scripts/"
    cat > "$tmpdir/scripts/speak.sh" <<'STUB'
#!/usr/bin/env bash
cat >> "$SPOKEN_LOG"
STUB
    chmod +x "$tmpdir/scripts/speak.sh"

    : > "$tmpdir/spoken.log"
    printf '%s' "$message" \
        | jq -Rs '{last_assistant_message: ., cwd: "/tmp", permission_mode: "default"}' \
        | SPOKEN_LOG="$tmpdir/spoken.log" bash "$tmpdir/scripts/speak-response.sh"

    actual=$(cat "$tmpdir/spoken.log")
    rm -rf "$tmpdir"

    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $description"
        echo "        expected: \"$expected\""
        echo "        actual:   \"$actual\""
        FAIL=$((FAIL + 1))
    fi
}

assert_hook "speaks only the marker line" \
    "Here is a long detailed answer with lots of prose."$'\n'"🔊 Short spoken version." \
    "Short spoken version."
assert_hook "silence marker speaks nothing" \
    "Housekeeping."$'\n'"🔇" \
    ""
assert_hook "no marker falls back to the message" \
    "Plain answer with no marker." \
    "Plain answer with no marker."
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-spoken-line.sh`
Expected: FAIL on "speaks only the marker line" — the current hook speaks the whole message,
so actual contains the prose *and* a literal `🔊`.

- [ ] **Step 3: Rewrite the hook**

Replace the entire contents of `hooks/scripts/speak-response.sh` with:

```bash
#!/usr/bin/env bash
# Stop hook: speaks the assistant's deliberate spoken line.
#
# Precedence:
#   🔇 line          → say nothing
#   🔊 line          → speak only that line
#   neither          → fall back to a sentence-aligned truncation of the reply
#
# Receives hook JSON on stdin with last_assistant_message.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/spoken-line.sh"

HOOK_INPUT=$(cat)

export NARRATOR_CWD=$(printf '%s\n' "$HOOK_INPUT" | jq -r '.cwd // ""')
LAST_TEXT=$(printf '%s\n' "$HOOK_INPUT" | jq -r '.last_assistant_message // ""')

if [[ -z "$LAST_TEXT" ]]; then
    exit 0
fi

# ── Spoken-line contract ──
set +e
SPOKEN=$(extract_spoken_line "$LAST_TEXT")
MARKER_STATUS=$?
set -e

if [[ $MARKER_STATUS -eq 2 ]]; then
    exit 0
fi

if [[ $MARKER_STATUS -eq 0 ]]; then
    printf '%s\n' "$SPOKEN" | bash "$SCRIPT_DIR/speak.sh"
    exit 0
fi

# ── Fallback: no marker present ──
# Strip any malformed marker lines so the emoji is never spoken.
LAST_TEXT=$(strip_marker_lines "$LAST_TEXT")

clean_markdown() {
    awk '
        /^```/ { fence = !fence; next }
        fence { next }
        { print }
    ' | sed -E '
        s/`([^`]+)`/\1/g
        s/\[([^]]+)\]\([^)]+\)/\1/g
        s/^#{1,6} //
        s/\*\*([^*]+)\*\*/\1/g
        s/\*([^*]+)\*/\1/g
        s/^---+$//
        s/^[[:space:]]*$//
        /^$/d
    '
}

CLEANED=$(printf '%s\n' "$LAST_TEXT" | clean_markdown)

if [[ -z "$CLEANED" ]]; then
    exit 0
fi

PERMISSION_MODE=$(printf '%s\n' "$HOOK_INPUT" | jq -r '.permission_mode // ""')

if [[ "$PERMISSION_MODE" == "plan" ]]; then
    printf '%s\n' "$CLEANED" | bash "$SCRIPT_DIR/speak.sh"
else
    if [[ ${#CLEANED} -le 1000 ]]; then
        SUMMARY="$CLEANED"
    else
        TRIMMED=$(printf '%s' "$CLEANED" | cut -c1-1050)
        SUMMARY=$(printf '%s' "$TRIMMED" | awk '{
            s = s (NR>1 ? " " : "") $0
        }
        END {
            best = 0
            for (i = 1; i <= length(s) && i <= 1000; i++) {
                c = substr(s, i, 1)
                if (c == "." || c == "!" || c == "?") {
                    if (i == length(s) || substr(s, i+1, 1) == " " || substr(s, i+1, 1) == "\n") {
                        best = i
                    }
                }
            }
            if (best > 0) {
                print substr(s, 1, best)
            } else {
                t = substr(s, 1, 1000)
                sub(/[[:space:]][^[:space:]]*$/, "", t)
                print t "..."
            }
        }')
    fi
    printf '%s\n' "$SUMMARY" | bash "$SCRIPT_DIR/speak.sh"
fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-spoken-line.sh`
Expected: PASS — `Results: 20 passed, 0 failed`

- [ ] **Step 5: Run the whole suite**

Run: `bash tests/run-all.sh`
Expected: `All test suites passed!`

- [ ] **Step 6: Verify in a live session**

Relaunch `claude --plugin-dir .`, then in that session ask a question whose answer ends with a
`🔊` line, and separately one that ends with `🔇`.
Expected: only the `🔊` text is spoken; the `🔇` turn is silent; no turn pronounces an emoji.

- [ ] **Step 7: Commit**

```bash
git add hooks/scripts/speak-response.sh tests/test-spoken-line.sh
git commit -m "feat(stop-hook): speak the 🔊 line instead of the first 1000 chars

Marker extraction runs ahead of upstream's truncation, which is retained
as the no-marker fallback so silence is never the failure mode. Marker
lines are stripped from the fallback and plan-mode paths so the emoji is
never sent to TTS.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Replace per-tool chatter with deliberate narration

**Files:**
- Modify: `hooks/hooks.json`

**Interfaces:**
- Consumes: nothing
- Produces: `hooks.json` with `SessionStart` absent for now (added in Task 5) and `PostToolUse` removed

- [ ] **Step 1: Remove the PostToolUse block**

Replace `hooks/hooks.json` with:

```json
{
  "description": "Voice output hooks: deliberate spoken line on turn end, plus notifications",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/speak-response.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/speak-notification.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Verify the config parses and has the right keys**

Run: `jq -r '.hooks | keys | join(",")' hooks/hooks.json`
Expected: `Notification,Stop`

- [ ] **Step 3: Verify no per-tool speech in a live session**

Relaunch `claude --plugin-dir .` and ask for something requiring several tool calls.
Expected: silence during the work, one spoken line at the end. Permission prompts still speak.

- [ ] **Step 4: Verify deliberate mid-turn narration still works**

```bash
echo "Running the test suite now." | bash hooks/scripts/speak.sh --force
```
Expected: audible. This is the call used for mid-turn progress and errors.

- [ ] **Step 5: Commit**

```bash
git add hooks/hooks.json
git commit -m "feat(hooks): drop PostToolUse chatter for deliberate narration

Upstream announced every tool call and also spoke intermediate text
blocks parsed from the transcript; both are silenced. Mid-turn progress
and errors now go through explicit speak.sh --force calls instead.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Inject the spoken-line rules at session start

The contract only works if the assistant knows to emit the marker. Skills are model-invoked on
intent match and are not guaranteed to load, so the rules go in a `SessionStart` hook that emits
`additionalContext` — the same mechanism the user's nexus hook uses.

**Files:**
- Create: `hooks/scripts/inject-spoken-line-rules.sh`
- Modify: `hooks/hooks.json`
- Modify: `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: the `enabled` key of `~/.claude-code-narrator/config`
- Produces: nothing consumed by later tasks

- [ ] **Step 1: Write the failing test**

Append to `tests/test-spoken-line.sh`, before the results block:

```bash
echo ""
echo "=== SessionStart rules injection ==="

assert_inject() {
    local description="$1" enabled="$2" expect_context="$3"
    local tmphome actual has_context
    tmphome=$(mktemp -d)
    mkdir -p "$tmphome/.claude-code-narrator"
    printf 'enabled=%s\n' "$enabled" > "$tmphome/.claude-code-narrator/config"

    actual=$(HOME="$tmphome" bash "$SCRIPT_DIR/../hooks/scripts/inject-spoken-line-rules.sh" </dev/null)
    rm -rf "$tmphome"

    if [[ -z "$actual" ]]; then
        has_context=no
    elif printf '%s' "$actual" | jq -e '.hookSpecificOutput.additionalContext | test("🔊")' >/dev/null 2>&1; then
        has_context=yes
    else
        has_context=malformed
    fi

    if [[ "$has_context" == "$expect_context" ]]; then
        echo "  PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $description"
        echo "        expected: $expect_context"
        echo "        actual:   $has_context ($actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_inject "injects rules when enabled"     "true"  "yes"
assert_inject "stays quiet when disabled"      "false" "no"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test-spoken-line.sh`
Expected: FAIL — `inject-spoken-line-rules.sh: No such file or directory`

- [ ] **Step 3: Write the hook**

Create `hooks/scripts/inject-spoken-line-rules.sh`:

```bash
#!/usr/bin/env bash
# SessionStart hook: teach the assistant the spoken-line contract.
# Emits nothing when voice output is disabled, so it costs no tokens when unused.

set -euo pipefail

STATE_FILE="$HOME/.claude-code-narrator/config"

enabled=""
if [[ -f "$STATE_FILE" ]]; then
    enabled=$(grep -m1 '^enabled=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "")
fi

if [[ "$enabled" != "true" ]]; then
    exit 0
fi

read -r -d '' RULES <<'EOF' || true
Voice output is active. This conversation is being spoken aloud.

End every response with one line beginning "🔊 " containing the spoken version
of your answer. The full text still goes to the terminal; the 🔊 line is what
the user hears.

Writing the spoken line:
- Compressed, not simplified. Shorter than the text because speech is slower,
  but it must carry the detail and complexity needed to understand the
  situation. Never drop a caveat, a failure, or a number to save words.
- Convey the situation: what happened, what it means, and the open decision if
  there is one. Not "tests mostly pass" — "Tests pass except the auth one,
  which is flaky because it hits the real clock; I can freeze time or skip it."
- One or two sentences. No markdown, no code, no file paths read character by
  character, no bullet lists.
- It is spoken by a neural TTS voice, so write it the way you would say it.

Use a line of exactly "🔇" instead when the turn should be silent — memory
bookkeeping, hook confirmations, and other housekeeping the user did not ask
to hear.

For progress on long operations and for errors that surface mid-turn, speak
immediately rather than waiting for the end of the turn:
  echo "Running the test suite now." | bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/speak.sh" --force
Use this sparingly — only when silence would read as a hang, or when something
broke that the user should know about before the turn ends.
EOF

jq -n --arg ctx "$RULES" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
```

Then make it executable:

```bash
chmod +x hooks/scripts/inject-spoken-line-rules.sh
```

- [ ] **Step 4: Register the hook**

In `hooks/hooks.json`, add a `SessionStart` entry alongside `Stop` and `Notification`:

```json
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/inject-spoken-line-rules.sh",
            "timeout": 5
          }
        ]
      }
    ]
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/test-spoken-line.sh`
Expected: PASS — `Results: 22 passed, 0 failed`

Run: `jq -r '.hooks | keys | join(",")' hooks/hooks.json`
Expected: `Notification,SessionStart,Stop`

- [ ] **Step 6: Verify the assistant actually receives the rules**

Relaunch `claude --plugin-dir .` with voice enabled and ask any question.
Expected: the reply ends with a `🔊` line without being told to, and that line is spoken.

- [ ] **Step 7: Document the divergence**

In `README.md`, add a section directly after the project description:

```markdown
## Fork notes

This is a fork of [claude-code-narrator](https://github.com/shreyas-s-rao/claude-code-narrator)
(MIT © 2026 Shreyas Rao) with three changes:

1. **Spoken-line contract.** Instead of reading the first ~1000 characters of a response, it
   speaks a line the assistant writes deliberately: a final line prefixed `🔊 `, compressed for
   the ear but carrying the full situation. A line of exactly `🔇` keeps the turn silent.
   Responses with neither marker fall back to upstream's truncation.
2. **No per-tool chatter.** The `PostToolUse` hook is removed; mid-turn progress and errors are
   spoken deliberately via `speak.sh --force`.
3. **`SessionStart` rules injection.** The contract is taught to the assistant at session start,
   gated on voice being enabled.

Upstream is retained as the `upstream` git remote.
```

In `CLAUDE.md`, update the hook-scripts table: change the `speak-response.sh` row's purpose to
"Extracts the 🔊 spoken line; falls back to sentence-aligned truncation", delete the
`speak-step.sh` row, and add a row for `inject-spoken-line-rules.sh` / `SessionStart` /
"Injects the spoken-line contract when enabled".

- [ ] **Step 8: Commit**

```bash
git add hooks/scripts/inject-spoken-line-rules.sh hooks/hooks.json tests/test-spoken-line.sh README.md CLAUDE.md
git commit -m "feat(session): inject the spoken-line contract at session start

Skills are model-invoked and not guaranteed to load, so the rules go in a
SessionStart hook emitting additionalContext. Gated on enabled=true so it
costs nothing when voice is off.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Restore microphone input and verify `/voice`

Independent of Tasks 2-5 and disruptive — it restarts WSL, killing the session. Do it last, or
in a separate window.

**Files:** none

**Interfaces:**
- Consumes: nothing
- Produces: a verified input path, or the finding that `/voice` is gated

- [ ] **Step 1: Restart WSL**

From a Windows PowerShell window (not inside WSL):

```
wsl --shutdown
```

Wait ten seconds, then reopen the terminal. Resume this work with `claude -c`.

- [ ] **Step 2: Verify the mic now carries signal**

```bash
rec -q -c 1 -r 16000 -b 16 /tmp/mic-test.wav trim 0 4   # talk during this
sox /tmp/mic-test.wav -n stat 2>&1 | grep -E "Maximum amplitude|RMS     amplitude"
```
Expected: maximum amplitude well above `0.01`. Before the fix it was `0.0085` with speech, and
`parec` showed a peak of 1/32767 — digital silence.

If it is still silent, the WSLg RDP audio channel is not carrying capture. Fall back to kaizen's
Whisper STT as the input source; the output half is unaffected.

- [ ] **Step 3: Check whether `/voice` is available to this account**

In a Claude Code session, run `/voice`.
Expected: it offers hold-to-talk or tap-to-toggle. Possible failure modes, all informative:
- "requires a Claude.ai account" → sign in rather than using an API key.
- "not available in this environment" → the `VOICE_HANDSFREE` gate is closed for this account;
  the input half needs kaizen's Whisper instead.
- A SoX complaint → already installed, so re-check `which rec`.

- [ ] **Step 4: Record the outcome in the spec**

Update the Environment and Risks sections of
`docs/superpowers/specs/2026-08-11-claude-code-voice-design.md` with what actually happened —
whether the restart fixed the mic, and whether `/voice` is gated.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-08-11-claude-code-voice-design.md
git commit -m "docs(spec): record mic passthrough and /voice availability outcomes

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Hold a real spoken conversation and tune

The contract's quality target — "shorter than text but carrying the detail needed to understand
the situation" — cannot be unit tested. It is judged by ear.

**Files:**
- Modify: `hooks/scripts/inject-spoken-line-rules.sh` (wording only)

**Interfaces:**
- Consumes: everything above
- Produces: tuned rule wording

- [ ] **Step 1: Work by voice for a real task**

With voice enabled and dictation working, do an actual piece of coding work — a bug fix or a
small feature — without reading the screen except when you choose to.

- [ ] **Step 2: Judge against the bar**

For each spoken line, ask: could you act on it without reading? Watch for the two failure modes:
- **Too thin** — "Done, tests pass" when there was a caveat worth hearing.
- **Too long** — a paragraph read aloud; you stop listening.

Also note whether silence during long tool runs reads as a hang, which would mean mid-turn
narration is being used too sparingly.

- [ ] **Step 3: Tune the rules**

Edit the `RULES` heredoc in `hooks/scripts/inject-spoken-line-rules.sh` based on what you heard.
Add a concrete example of a line that failed and its better version — examples move behavior more
reliably than adjectives.

- [ ] **Step 4: Re-verify and commit**

Run: `bash tests/run-all.sh`
Expected: `All test suites passed!`

```bash
git add hooks/scripts/inject-spoken-line-rules.sh
git commit -m "tune(rules): sharpen spoken-line guidance from live use

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Deferred

- **Kaizen integration.** Kaizen would write to the same FIFO. Out of scope; the seam exists.
- **kokoro-onnx swap.** Only if Task 1's cold-start measurement proves annoying, and only after
  measuring on x86 — the "int8 is faster" claim is false on ARM.
- **Barge-in mid-sentence.** Upstream's hush already stops playback; true interruption while the
  assistant is still generating would need the rejected PTY architecture.
