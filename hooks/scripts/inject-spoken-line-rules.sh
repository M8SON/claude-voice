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

For progress on long operations and for errors that surface mid-turn, speak
immediately rather than waiting for the end of the turn:
  echo "Running the test suite now." | bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/speak.sh" --force
Use this sparingly — only when silence would read as a hang, or when something
broke that the user should know about before the turn ends.
EOF

jq -n --arg ctx "$RULES" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
