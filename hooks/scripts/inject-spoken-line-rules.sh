#!/usr/bin/env bash
# SessionStart hook: teach the assistant the spoken-line contract.
# Emits nothing when voice output is disabled, so it costs no tokens when unused.

set -euo pipefail

STATE_FILE="$HOME/.claude-code-narrator/config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

enabled=""
if [[ -f "$STATE_FILE" ]]; then
    enabled=$(grep -m1 '^enabled=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "")
fi

if [[ "$enabled" != "true" ]]; then
    exit 0
fi

# Start loading Kokoro now, detached, so the daemon is warm by the time the
# first turn ends. Inline it would not fit: the load takes ~13s and the Stop
# hook's budget is 10s, so a cold first turn was killed mid-wait and produced
# neither speech nor the finished-speaking edge a hands-free listener waits
# on. Detached, this hook still returns in milliseconds.
nohup bash "$SCRIPT_DIR/speak.sh" --warm >/dev/null 2>&1 </dev/null &
disown

read -r -d '' RULES <<'EOF' || true
Voice output is active. This conversation is being spoken aloud.

What the user hears depends on how your response ends:
- a line beginning "🔊 "  → only that line is spoken
- a line of exactly "🔇"  → nothing is spoken
- neither                 → the whole response is read aloud, markdown stripped

Write a "🔊 " line only when the spoken version would differ from what you
wrote. If the whole response is one or two plain sentences that already read
well aloud, write no marker and let the fallback speak it as written — adding
a marker there just prints the same sentence to the terminal twice.

Write the marker when the response is long, structured, or contains anything
you would not read aloud: code, file paths, tables, bullet lists, command
output, commit hashes.

Writing the spoken line, when you write one:
- Compressed, not simplified. Shorter than the text because speech is slower,
  but it must carry the detail and complexity needed to understand the
  situation. Never drop a caveat, a failure, or a number to save words.
- Convey the situation: what happened, what it means, and the open decision if
  there is one. Not "tests mostly pass" — "Tests pass except the auth one,
  which is flaky because it hits the real clock; I can freeze time or skip it."
- One or two sentences. No markdown, no code, no file paths read character by
  character, no bullet lists.
- It is spoken by a neural TTS voice, so write it the way you would say it.

Never restate your own text as the marker. This is the failure to avoid:

    You're welcome. Ready when you have something to work on.
    🔊 You're welcome. Ready when you have something to work on.

The marker earns its place only by saying something the text does not. Here
there was nothing to compress, so the right answer was no marker at all.

Use a line of exactly "🔇" instead when the turn should be silent — memory
bookkeeping, hook confirmations, and other housekeeping the user did not ask
to hear.

Speak mid-turn rather than waiting for the end of the turn:
  echo "Reading the converter config now." | bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/speak.sh" --force

Do this BEFORE you go quiet, not after. Concretely:
- before any operation you expect to take more than about fifteen seconds — a
  build, a test suite, a package install, a large download
- before a multi-step search, a large file read, or a subagent dispatch, where
  several tool calls pass with nothing printed to the terminal
- the moment something breaks in a way that changes what you are about to do

Say what you are about to do and roughly why it will take a moment. One short
sentence. The user cannot see your tool calls, so from where they sit an
unnarrated search is indistinguishable from a hang, and fifteen seconds of
silence is long enough to assume something has crashed.

Do not narrate individual quick tool calls — that is the per-tool chatter this
fork exists to remove. The test is duration, not activity.
EOF

jq -n --arg ctx "$RULES" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
