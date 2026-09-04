# tmux-agentic-usage

A tmux popup showing how much of your AI coding quota is left, and whether you are burning it faster than it refills.

Press a key, get an instant modal with your Claude and Codex (and any other [CodexBar](https://github.com/steipete/codexbar) provider) rate limits:

```
 CLAUDE
  Session   97% left  ███████████████████░  resets in 4h 45m
  ▸ On pace · Expected 4% used · Lasts until reset
  Weekly    66% left  █████████████░░░░░░░  resets in 3d 13h
  ▸ 15% in reserve · Expected 49% used · Lasts until reset
  Fable     52% left  ██████████░░░░░░░░░░  resets in 3d 13h

 CODEX plus
  Session   94% left  ██████████████████░░  resets in 4h 45m
  Weekly    86% left  █████████████████░░░  resets in 2d 19h
  ▸ 46% in reserve · Expected 60% used · Lasts until reset · 1.5× headroom
  Reset credits: 2 available

 updated 2m ago · r refresh · q quit
```

The pace lines are the point: green means you have reserve and the window lasts until reset, yellow means you are ahead of pace, red means you are projected to run out before the reset.

On narrow clients (a phone SSH session with the keyboard up) the popup switches to a compact layout that fits about 30 columns:

```
 CLAUDE
 Session  90% ███████░ 0h13m
 ▸ 85% in reserve
 Weekly   64% █████░░░ 3d9h
 ▸ 16% in reserve
 Fable    51% ████░░░░ 3d9h
```

## How it works

Fetching usage takes 20 to 25 seconds (the CodexBar CLI talks to provider APIs), so the popup never fetches in the foreground. A small daemon, started with the tmux server, refreshes a JSON cache every 5 minutes and dies with the server. The popup renders from the cache instantly and shows the cache age in the footer. `r` forces a refresh, and opening the popup on a stale cache kicks a background refresh automatically.

When a provider omits pace data (right after a session reset, for example), the plugin synthesizes it from elapsed window time versus used percent, so the reserve line is always there.

## Requirements

- macOS with [CodexBar](https://github.com/steipete/codexbar) installed (the menu bar app ships the `codexbar` CLI)
- `jq`
- tmux 3.2 or newer (for `display-popup`)

## Install

With [TPM](https://github.com/tmux-plugins/tpm):

```tmux
set -g @plugin 'i-mage/tmux-agentic-usage'
```

Press `prefix + I` to install. Then hit `Alt+Shift+u`.

Manual install:

```sh
git clone https://github.com/i-mage/tmux-agentic-usage ~/.tmux/plugins/tmux-agentic-usage
echo "run-shell ~/.tmux/plugins/tmux-agentic-usage/agentic-usage.tmux" >> ~/.tmux.conf
tmux source-file ~/.tmux.conf
```

## Options

Set in `.tmux.conf` before the plugin line:

```tmux
set -g @agentic-usage-key 'M-U'        # popup key (root table), default Alt+Shift+u
set -g @agentic-usage-interval '300'   # cache refresh seconds, 0 disables the daemon
set -g @agentic-usage-providers 'both' # passed to `codexbar usage --provider`
```

`@agentic-usage-providers` accepts anything the CodexBar CLI accepts: `both` (Claude + Codex), `all` (every provider enabled in the app), or a single provider like `claude`, `gemini`, `cursor`, `copilot`.

## Keys inside the popup

| Key | Action |
|-----|--------|
| `r` | Force refresh (blocks ~25s) |
| `q` / `Esc` | Close |

## Credits

All the data comes from [CodexBar](https://github.com/steipete/codexbar) by [@steipete](https://github.com/steipete). This plugin is just a tmux-shaped window into it.

## License

[MIT](LICENSE)
