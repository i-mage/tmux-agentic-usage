# tmux-agentic-usage

A tmux popup showing how much of your AI coding quota is left, and whether you are burning it faster than it refills.

Press a key, get an instant modal with your Claude and Codex (and any other [CodexBar](https://github.com/steipete/codexbar) provider) rate limits:

```
 CLAUDE
  Session   97% left  ███████████████████░  resets in 4h 45m (19:40)
  ▸ 5% of session elapsed · too early to project
  Weekly    66% left  █████████████░░░░░░░  resets in 3d 13h (Thu 5.11. 18:00)
  ▸ 49% of week elapsed · 34% used · 15% under pace · lasts until reset
  Fable     52% left  ██████████░░░░░░░░░░  resets in 3d 13h (Thu 5.11. 18:00)
  ▸ 49% of week elapsed · 48% used · 1% under pace · lasts until reset

 CODEX plus
  Session   32% left  ██████░░░░░░░░░░░░░░  resets in 2h 17m (17:09)
  ▸ 53% of session elapsed · 68% used · 15% over pace · runs out in 2h 23m
  Weekly    86% left  █████████████████░░░  resets in 2d 19h (Sun 8.11. 12:09)
  ▸ 60% of week elapsed · 14% used · 46% under pace · lasts until reset
  Reset credits: 2 available

 updated 2m ago · r refresh · q quit
```

The pace lines are the point. Each window is a tank that refills at the reset, so the line compares how much of the window is gone with how much of the quota is gone: `84% of week elapsed · 1% used` means the week is almost over and you barely touched it, so you are `83% under pace`. Green means the window lasts until reset, yellow means you are over pace but still fine, red means you are projected to run out before the reset. Under 10% of a window elapsed the line says `too early to project` instead of extrapolating a few minutes into a false alarm.

On narrow clients (a phone SSH session with the keyboard up) the popup switches to a compact layout that fits about 30 columns:

```
 CLAUDE
 Session  90% ███████░ 0h13m
 ▸ 96% of session gone · 86% under pace
 Weekly   64% █████░░░ 3d9h
 ▸ 52% of week gone · 16% under pace
 Fable    51% ████░░░░ 3d9h
 ▸ 52% of week gone · 3% over pace
```

## How it works

Claude is read from the same OAuth endpoints Claude Code uses (token from the `Claude Code-credentials` keychain item), so the popup shows the account Claude Code is logged into, not whichever account the browser is signed in to on claude.ai. If that token or endpoint is unavailable, CodexBar's Claude data is used instead.

### Several Claude subscriptions

If you switch Claude Code between accounts with `/login`, the popup keeps every account it has seen. Each refresh copies the logged-in account's OAuth credentials into a keychain item of its own (`tmux-agentic-usage-claude`, one per account), so an account you switched away from is still read: its access token while it is valid, then a new one from its refresh token. The account Claude Code is logged into is never refreshed by the plugin, so its tokens are never rotated under Claude Code. Usage of an account counts everything on it, the claude.ai web app included.

An account is picked up the first time Claude Code is logged into it while tmux runs. With two or more accounts a pool block comes first: each window summed over the accounts (two subscriptions = 200% a week), with a pace line that compares the mean share used with the mean share of the week elapsed, so accounts that reset at different hours still add up:

```
 CLAUDE POOL 2 accounts
  Weekly   147% left  ██████████████░░░░░░  of 200%
  ▸ 12% of week elapsed · 27% of pool used · 15% over pace · runs out before reset

 CLAUDE Claude Max 20x you@work.io ●
  ...
 CLAUDE Claude Max 20x you@home.io
  ...
```

`●` marks the account Claude Code is logged into. A session row is shown for another account only while that session is in use. `stale 25m` means the last fetch failed and the numbers are that old; `/login to this account to refresh` means its stored refresh token no longer works. To forget an account, delete its uuid from `~/.cache/tmux-agentic-usage/claude-accounts`, its `claude-<uuid>.json` there, and `security delete-generic-password -s tmux-agentic-usage-claude -a <uuid>`.

### Cache

Fetching usage takes 20 to 25 seconds (the CodexBar CLI talks to provider APIs), so the popup never fetches in the foreground. A small daemon, started with the tmux server, refreshes a JSON cache every 5 minutes and dies with the server. The popup renders from the cache instantly and shows the cache age in the footer. `r` forces a refresh, and opening the popup on a stale cache kicks a background refresh automatically.

When a provider omits pace data (right after a session reset, for example), the plugin derives it from elapsed window time versus used percent, so the pace line is always there.

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
