---
description: Disable narrator voice output
allowed-tools: Bash, Read, Edit, Write
---

# Disable Narrator Voice Output

To disable narrator voice output:

## Step 1: Determine Scope

Check if the user specified `--local` (e.g., `/narrator:off --local`). If so, changes apply to the **local** config file in the current working directory.

- **Global** (default): `~/.claude-code-narrator/config`
- **Local** (`--local`): `<cwd>/.claude-code-narrator/config`

## Step 2: Update State File

### Global mode (no `--local`):

Read `~/.claude-code-narrator/config`. If the file exists, use the Edit tool to change the `enabled=` line to `enabled=false`. If the file does not exist, create it with the Write tool containing just `enabled=false`.

### Local mode (`--local`):

Read `<cwd>/.claude-code-narrator/config`. If the file exists and has an `enabled=` line, use the Edit tool to change it to `enabled=false`. If the file exists but has no `enabled=` line, use the Edit tool to add `enabled=false`. If the file does not exist, create the `<cwd>/.claude-code-narrator/` directory if needed, then create the `config` file with the Write tool containing just `enabled=false`.

To remove the local override entirely (reverting to global state), delete the `<cwd>/.claude-code-narrator/` directory instead.

IMPORTANT: Do NOT use `sed` to edit state files — use the Read and Edit tools instead.

## Step 3: Auto-Hush — nothing to do

Auto-hush lives in the plugin's `hooks/hooks.json` and is not registered in
user settings, so there is nothing to unregister. The hook reads the enabled
state itself and does nothing while narrator is off.

## Step 4: Confirm

For global mode, inform the user: "Narrator is now disabled. Voice output is off."

For local mode, inform the user: "Narrator is now disabled for this directory. Global setting is unchanged."

Do NOT attempt to speak this confirmation (narrator is now off).
