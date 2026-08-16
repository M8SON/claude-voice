#!/usr/bin/env bash
# Tests that claude-voice's hooks only run in claude-voice sessions.
#
# A plain `claude` session should be plain: no speech, no listener, no
# spoken-line rules. Everything in hooks/hooks.json satisfies that for free,
# because a plugin's hooks load only when the plugin does — here, via
# claude-voice's --plugin-dir.
#
# hush-on-input.sh was the exception. Upstream registers it in
# ~/.claude/settings.json, which loads in EVERY session, on the assumption that
# narrator is installed globally. In this fork voice exists only through the
# launcher, so a user-settings registration means a plain session still fires
# the hook — and once auto-hush actually worked (2026-08-16; it had never fired
# before), typing in a plain session would SIGUSR1 the daemon and cut off a
# reply being spoken by a voice session in another terminal.
#
# Run: bash tests/test-hook-scope.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL + 1)); }

echo "=== Auto-hush is a plugin hook, not a global one ==="

if jq -e '.hooks.UserPromptSubmit' "$REPO/hooks/hooks.json" >/dev/null 2>&1; then
    ok "hooks.json registers UserPromptSubmit"
else
    bad "hooks.json registers UserPromptSubmit" \
        "not declared, so auto-hush would not fire in a voice session"
fi

cmd=$(jq -r '.hooks.UserPromptSubmit[]?.hooks[]?.command // empty' \
    "$REPO/hooks/hooks.json" 2>/dev/null)

if grep -q 'hush-on-input.sh' <<< "$cmd"; then
    ok "it runs hush-on-input.sh"
else
    bad "it runs hush-on-input.sh" "got: $cmd"
fi

# Plugin hooks must address scripts through the plugin root. An absolute path
# would work here and break for anyone else who clones this.
if grep -q 'CLAUDE_PLUGIN_ROOT' <<< "$cmd"; then
    ok "it resolves through CLAUDE_PLUGIN_ROOT"
else
    bad "it resolves through CLAUDE_PLUGIN_ROOT" "got: $cmd"
fi

echo ""
echo "=== /narrator:on and /narrator:off no longer touch user settings ==="

# If they still edited ~/.claude/settings.json, running /narrator:on would put
# the global registration straight back and reintroduce the interference.
#
# The check is for the JSON key rather than any mention of settings.json: these
# docs SHOULD name the file, to say explicitly not to register the hook there.
# `"UserPromptSubmit"` in quotes appears only in a block being written into a
# settings file, which is the thing that must be gone.
for f in commands/on.md commands/off.md skills/on/SKILL.md skills/off/SKILL.md; do
    if grep -q '"UserPromptSubmit"' "$REPO/$f" 2>/dev/null; then
        bad "$f does not register the hook in user settings" \
            "still carries a UserPromptSubmit block — /narrator:on would re-register it globally"
    else
        ok "$f does not register the hook in user settings"
    fi
done

echo ""
echo "=== Nothing else reaches outside the plugin ==="

# Every hook command in hooks.json must live under the plugin root, or it is
# not scoped to plugin sessions at all.
outside=$(jq -r '.hooks[][]?.hooks[]?.command' "$REPO/hooks/hooks.json" 2>/dev/null \
    | grep -v 'CLAUDE_PLUGIN_ROOT' || true)
if [[ -z "$outside" ]]; then
    ok "every hook command resolves through the plugin root"
else
    bad "every hook command resolves through the plugin root" "$outside"
fi

echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo "All tests passed!"
fi
