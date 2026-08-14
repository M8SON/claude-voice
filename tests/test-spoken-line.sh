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
