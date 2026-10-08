# Install guide for AI agents

Goal: install `statusline.sh` + `pricing.json` into the user's `~/.claude/` and register the status line in `~/.claude/settings.json`. Do the steps in order. Do not overwrite the user's existing status line without backing it up.

## 0. Preconditions

```bash
for c in bash jq awk git stat timeout tail head; do command -v $c >/dev/null || echo "MISSING: $c"; done
```
If anything is missing, tell the user and install it with their package manager (e.g. `sudo apt install jq`) only after they agree. On macOS `stat -c` and `timeout` are GNU-only: ask the user to install `coreutils` and make GNU versions come first in PATH, or stop and say so.

## 1. Back up the existing setup

```bash
cd ~/.claude
[ -f statusline.sh ] && cp statusline.sh "statusline.sh.bak.$(date +%Y%m%d%H%M%S)"
[ -f pricing.json ]  && cp pricing.json  "pricing.json.bak.$(date +%Y%m%d%H%M%S)"
cp settings.json "settings.json.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
```

## 2. Copy files

From the root of this repository:

```bash
cp statusline.sh pricing.json ~/.claude/
```
If `~/.claude/pricing.json` already existed and the user customised it, merge instead of overwriting (keep their keys, add missing models).

## 3. Register in settings.json

Merge, do not replace. Keep every other key. With jq:

```bash
f=~/.claude/settings.json; [ -f "$f" ] || echo '{}' > "$f"
jq '.statusLine = {"type":"command","command":"bash ~/.claude/statusline.sh","padding":0,"refreshInterval":1}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
```
If `.statusLine` is already set to something else, show the user the old value first and ask before replacing it.

## 4. Verify

Feed a fake payload (use a real transcript so the cost segment shows):

```bash
t=$(ls -t ~/.claude/projects/*/*.jsonl | head -1)
echo "{\"session_id\":\"install-test\",\"transcript_path\":\"$t\",\"model\":{\"display_name\":\"test\"}}" | bash ~/.claude/statusline.sh
rm -f ~/.claude/.statusline-*-install-test*
```
Expected: one line containing `test`, and `$…` if the transcript has assistant usage. Also run `bash -n ~/.claude/statusline.sh` and `jq empty ~/.claude/pricing.json`. The new status line appears in Claude Code on the next render (no restart needed; a new session if it does not).

## 5. Tell the user

- Cost is an estimate from `pricing.json`, not a bill.
- Models not in `pricing.json` count as $0: add a row (`in`, `out`, `cache_read`, `w5m`, `w1h`, USD per MTok; longest prefix wins).
- Optional `long_threshold` + `long` block bills a whole request at the long-context rates when its prompt exceeds the threshold (used for Haiku 5.5).
- Per-session cache files `~/.claude/.statusline-{turns,speed,cost}-<session_id>` are safe to delete.
- The script also writes `~/.claude/sessions/last_session` (session id for the author's own resume tooling). Harmless; delete the block under "记录当前会话 session_id" if unwanted.

## Uninstall

Remove the `statusLine` key from `settings.json`, delete `~/.claude/statusline.sh`, `~/.claude/pricing.json` and `~/.claude/.statusline-*`.
