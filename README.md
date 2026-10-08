# claude-code-statusline

A single-line status bar for [Claude Code](https://claude.com/claude-code), written in bash.

```
312k/1.0m | Opus 5.5 | ⎇ main | ~/proj | 7 turns (25 steps) | ⚡ 82.1t/s 6.1s ↑2 ↓503 | $0.831 (r$0.30 + w$0.19 + i$0.0002 + o$0.273) [M:$0.759 | S:$0.071] | 5h ███████░░░ 76% -1h38m 0.7x 2h13m | week ... | cpu 12%
```

| Segment | Meaning |
|---|---|
| `312k/1.0m` | context used / window, colored by fill (green → cyan → yellow → red) |
| model, branch, cwd | model display name, git branch, working dir |
| `N turns (M steps)` | real user turns / assistant API calls, parsed from the transcript |
| `⚡ tok/s` | speed of the last response |
| `$total (r=cache read + w=cache write + i=input + o=output) [M:main \| S:subagents]` | **session cost in USD**, computed from token usage × `pricing.json`; subagents included |
| `5h` / `week` | subscription quota bars with burn-rate (subscription users only) |
| `cpu` | system CPU since the last render |

Unlike pi, cache read and cache write are shown separately: Anthropic charges for cache writes (1.25x/2x input), and in long sessions they can cost as much as the output. The cost layout otherwise mirrors the `status-footer` extension of [pi-extensions](https://github.com/yu1745/pi-extensions).

## Install

**If you are an AI agent, read [`INSTALL.md`](INSTALL.md) and follow it.**

Human quick start:

```bash
git clone https://github.com/yu1745/claude-code-statusline
cd claude-code-statusline
cp statusline.sh pricing.json ~/.claude/
```

Then add to `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "bash ~/.claude/statusline.sh", "padding": 0, "refreshInterval": 1 }
```

Requires `bash`, `jq`, `awk`, `git`, GNU coreutils (`stat`, `timeout`, `tail`, `head`). Linux; macOS needs GNU coreutils/`gstat`.

## Pricing

`pricing.json` is USD per million tokens, matched by longest model-id prefix. Models not listed are counted as $0, so add a row when a new model ships. Prices were checked against the [official pricing page](https://platform.claude.com/docs/en/about-claude/pricing) on 2026-10-08. The figure is an estimate from public API prices, not your actual bill (subscriptions differ).

## License

MIT
