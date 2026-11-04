# Build the cache entry for Claude from the OAuth endpoints Claude Code itself uses.
# Input: {"usage": <GET /api/oauth/usage>, "profile": <GET /api/oauth/profile>}
# Output: one entry in the shape codexbar writes, so popup.sh reads it unchanged.
#
# Why not CodexBar: its Claude "web" source reads claude.ai browser cookies, which
# can belong to a different account than the one Claude Code is logged into, and its
# "oauth" source cannot read the keychain item. These endpoints answer for exactly
# the account in "Claude Code-credentials".

def iso: if . == null then null else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") end;

def plan($tier):
  if ($tier // "") | test("max_20x") then "Claude Max 20x"
  elif ($tier // "") | test("max_5x") then "Claude Max 5x"
  elif ($tier // "") | test("max") then "Claude Max"
  elif ($tier // "") | test("pro") then "Claude Pro"
  else "Claude" end;

def win($l; $minutes):
  if $l == null then null
  else {usedPercent: ($l.percent // 0), windowMinutes: $minutes, resetsAt: ($l.resets_at | iso)}
  end;

(.usage.limits // []) as $limits
| {
    provider: "claude",
    source: "oauth",
    error: null,
    usage: {
      identity: {
        loginMethod: plan(.profile.organization.rate_limit_tier),
        accountEmail: (.profile.account.email // null)
      },
      primary: win(($limits | map(select(.kind == "session")) | first); 300),
      secondary: win(($limits | map(select(.kind == "weekly_all")) | first); 10080),
      extraRateWindows: [
        $limits[] | select(.kind == "weekly_scoped")
        | {title: (.scope.model.display_name // .scope.surface // "Scoped"),
           window: win(.; 10080)}
      ]
    }
  }
