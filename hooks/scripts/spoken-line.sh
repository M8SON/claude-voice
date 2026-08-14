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
