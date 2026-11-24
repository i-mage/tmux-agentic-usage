# tmux-agentic-usage

A tmux popup showing how much of your AI coding quota is left, and whether you are burning it faster than it refills. For people who run Claude Code and Codex all day and want to know, at a glance, if the week will last.

Press `Alt+Shift+u`, get an instant modal with your Claude and Codex (and any other [CodexBar](https://github.com/steipete/codexbar) provider) rate limits. macOS only, because the data comes from CodexBar.

```
 CLAUDE Claude Max 20x
  resets Thu 18:00
  Session   97% left  █████████████████████████████░
  resets Mon 19:40
  ▸ 4.2% reserve
  Weekly    66% left  ████████████████████░░░░░░░░░░
  ▸ 4.2% reserve
  Fable     52% left  ████████████████░░░░░░░░░░░░░░
  ▸ 4.2% reserve

 CODEX plus
  Session   32% left  ██████████░░░░░░░░░░░░░░░░░░░░
  resets Mon 17:09
  ▸ 4.2% reserve
  Weekly    86% left  ██████████████████████████░░░░
  resets Sun 12:09
  ▸ 4.2% reserve
  Reset credits: 2 available

 updated 2m ago · r refresh · q quit
```

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

## Reading it

The pace lines are the point. Under each bar one line says how far the use is from an even pace at this second: an even pace allows the quota times the elapsed share of the window, so `2.1% over pace` means 2.1 % more is used than that, `7.5% reserve` means 7.5 % less. Red is more than 3 % over pace, yellow within 3 % either way, green more than 3 % in reserve. It works from the first minute of a window.

A Claude account's week windows (Weekly, Fable) reset together, so the reset is said once under the account's name; every other window (a session, Codex) says its own on a line under its bar. A reset is the moment it happens (`resets Mon 23:00`, a date only when it is a week or more ahead), never a countdown. The bars take the whole width of the popup, which is at least 64 columns.

### Away periods

Time you are away from the computer is not working time, so the quota can be spent faster before it. Add an away period in local time:

```
bash scripts/away.sh "2026-11-28 12:00" "2026-11-29 14:00"   # add
bash scripts/away.sh                                         # list
bash scripts/away.sh clear                                   # remove all
```

The periods live in `~/.config/tmux-agentic-usage/away`, one per line. An even pace is then counted over the working time of the window only: before an away period it allows more, during it nothing more. The popup names the period on its first line (`away Sat 12:00 → Sun 14:00`).

On narrow clients (a phone SSH session with the keyboard up) the popup switches to a compact layout under 50 columns:

```
 CLAUDE you
 resets Thu 18:00
 Session  90% ███████████████████░░
 resets Mon 19:40
 ▸ 4.2% reserve
 Weekly   64% █████████████░░░░░░░
 ▸ 4.2% reserve
```

## How it works

Claude is read from the same OAuth endpoints Claude Code uses (token from the `Claude Code-credentials` keychain item), so the popup shows the account Claude Code is logged into, not whichever account the browser is signed in to on claude.ai. If that token or endpoint is unavailable, CodexBar's Claude data is used instead.

### Several Claude subscriptions

If you switch Claude Code between accounts with `/login`, the popup keeps every account it has seen. Each refresh copies the logged-in account's OAuth credentials into a keychain item of its own (`tmux-agentic-usage-claude`, one per account), so an account you switched away from is still read: its access token while it is valid, then a new one from its refresh token. The account Claude Code is logged into is never refreshed by the plugin, so its tokens are never rotated under Claude Code. Usage of an account counts everything on it, the claude.ai web app included.

An account is picked up the first time Claude Code is logged into it while tmux runs. To add one without switching Claude Code at all, run `bash scripts/add-account.sh [email]`: it logs in once in a throwaway `CLAUDE_CONFIG_DIR` (the browser opens, pick the account), copies that login into the plugin's store, deletes the throwaway login and refreshes the cache. Sessions running in your Claude Code stay on their account. With two or more accounts a pool block comes first: each window summed over the accounts (two subscriptions = 200% a week), with the same pace line: the summed use against the sum of what each account's own pace allows by now, so accounts that reset at different hours still add up:

```
 CLAUDE POOL 2 accounts
  Weekly   147% left  ██████████████████████░░░░░░░░  of 200%
  ▸ 2.1% over pace

 CLAUDE Claude Max 20x you@work.io ●
  ...
 CLAUDE Claude Max 20x you@home.io
  ...
```

`●` marks the account Claude Code is logged into. A session row is shown for another account only while that session is in use. An account whose last update failed gets a line under its name, `⚠ not updated for 45m: <why>` (yellow while it retries, red when only a new login fixes it, then run `scripts/add-account.sh`); an account that was never read at all shows as an error row, never disappears. When a whole refresh fails, the footer says `⚠ last refresh failed at 11:38: <why>`. To forget an account, delete its uuid from `~/.cache/tmux-agentic-usage/claude-accounts`, its `claude-<uuid>.json` there, and `security delete-generic-password -s tmux-agentic-usage-claude -a <uuid>`.

### Cache

Fetching usage takes 20 to 25 seconds (the CodexBar CLI talks to provider APIs), so the popup never fetches in the foreground. A small daemon, started with the tmux server, refreshes a JSON cache every 5 minutes and dies with the server. The popup renders from the cache instantly and shows the cache age in the footer. `r` forces a refresh, and opening the popup on a stale cache kicks a background refresh automatically.

When a provider omits pace data (right after a session reset, for example), the plugin derives it from elapsed window time versus used percent, so the pace line is always there.

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

## Tests

```sh
for t in tests/test_*.sh; do bash "$t"; done
```

Each suite prints `ok` or the failing check with what it got and what it wanted. They need `jq` only, no tmux and no CodexBar.

## Credits

All the data comes from [CodexBar](https://github.com/steipete/codexbar) by [@steipete](https://github.com/steipete). This plugin is just a tmux-shaped window into it.

## License

[MIT](LICENSE)
