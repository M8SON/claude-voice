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

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
