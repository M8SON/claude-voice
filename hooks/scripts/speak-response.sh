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
    printf '%s\n' "$SPOKEN" | bash "$SCRIPT_DIR/speak.sh" --final
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
    printf '%s\n' "$CLEANED" | bash "$SCRIPT_DIR/speak.sh" --final
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
    printf '%s\n' "$SUMMARY" | bash "$SCRIPT_DIR/speak.sh" --final
fi
