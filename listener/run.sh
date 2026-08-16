#!/usr/bin/env bash
# Start the hands-free listener with the audio setup it needs.
#
# Usage:
#   listener/run.sh                      # print transcripts only
#   CLAUDE_TMUX_TARGET=voice listener/run.sh
#   AUTO_SUBMIT=true CLAUDE_TMUX_TARGET=voice listener/run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAIZEN_ROOT="${KAIZEN_ROOT:-$HOME/linux/kaizen}"
VENV_PYTHON="$KAIZEN_ROOT/.venv/bin/python"

# Capture gain. RDPSource comes up at 100%, where it clips so hard that speech
# and an empty room measure the same (~0.9995 peak for both). 40% gives clean
# speech with headroom. This resets on every reboot, which is why it lives here
# rather than in a setup step someone runs once and forgets.
INPUT_GAIN="${INPUT_GAIN:-40%}"

if [[ ! -x "$VENV_PYTHON" ]]; then
    echo "kaizen venv not found at $VENV_PYTHON" >&2
    echo "Set KAIZEN_ROOT, or build the venv in that checkout." >&2
    exit 1
fi

if command -v pactl >/dev/null 2>&1; then
    if pactl list short sources 2>/dev/null | grep -q RDPSource; then
        pactl set-source-volume RDPSource "$INPUT_GAIN"
        echo "Input gain: RDPSource at $INPUT_GAIN" >&2
    else
        # Not WSLg. Leave whatever the machine's own default is alone.
        echo "No RDPSource — leaving input gain untouched." >&2
    fi
fi

if [[ -z "${CLAUDE_TMUX_TARGET:-}" ]]; then
    echo "CLAUDE_TMUX_TARGET unset — transcripts will print, not submit." >&2
    echo "Panes available:" >&2
    tmux list-panes -a -F '  #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null \
        || echo "  (no tmux server running)" >&2
fi

exec env KAIZEN_ROOT="$KAIZEN_ROOT" "$VENV_PYTHON" "$SCRIPT_DIR/claude_listener.py"
