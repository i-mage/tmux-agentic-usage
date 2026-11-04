#!/usr/bin/env bash
# Run: tests/test_claude_oauth.sh  (exit 0 = pass)
set -euo pipefail
cd "$(dirname "$0")/.."
JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
fail=0
check() { # $1 = jq expr on output, $2 = expected
  local got; got=$("$JQ" -r "$1" <<<"$OUT")
  if [ "$got" != "$2" ]; then echo "FAIL $1: got '$got', want '$2'"; fail=1; fi
}

IN='{"usage":{"limits":[
  {"kind":"session","percent":1,"resets_at":"2026-11-04T21:59:59.929393+00:00","scope":null},
  {"kind":"weekly_all","percent":46,"resets_at":"2026-11-09T16:59:59.929416+00:00","scope":null},
  {"kind":"weekly_scoped","percent":48,"resets_at":"2026-11-09T16:59:59.929578+00:00",
   "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]},
 "profile":{"account":{"email":"martin@example.com"},
            "organization":{"rate_limit_tier":"default_claude_max_20x"}}}'
OUT=$("$JQ" -c -f scripts/claude_oauth.jq <<<"$IN")
check '.provider' 'claude'
check '.source' 'oauth'
check '.usage.identity.accountEmail' 'martin@example.com'
check '.usage.identity.loginMethod' 'Claude Max 20x'
check '.usage.primary.usedPercent' '1'
check '.usage.primary.windowMinutes' '300'
check '.usage.primary.resetsAt' '2026-11-04T21:59:59Z'
check '.usage.secondary.usedPercent' '46'
check '.usage.secondary.resetsAt' '2026-11-09T16:59:59Z'
check '.usage.extraRateWindows[0].title' 'Fable'
check '.usage.extraRateWindows[0].window.usedPercent' '48'

# No session limit in the payload: no Session row, never a crash.
OUT=$("$JQ" -c -f scripts/claude_oauth.jq <<<'{"usage":{"limits":[]},"profile":{}}')
check '.usage.primary' 'null'
check '.usage.identity.loginMethod' 'Claude'

[ $fail -eq 0 ] && echo "ok"
exit $fail
