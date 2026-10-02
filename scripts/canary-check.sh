#!/usr/bin/env bash
# Judge a running canary against criteria written down BEFORE the release.
# See docs/canary-criteria.md.
#
#   scripts/canary-check.sh URL CANARY_VERSION [MINUTES] [MAX_ERROR_PERCENT]
#
# Sends steady traffic, and uses the version each response reports to tell
# canary responses apart from stable ones. Exits non-zero to abort.
set -euo pipefail
url=${1:?usage: canary-check.sh URL CANARY_VERSION [MINUTES] [MAX_ERROR_PERCENT]}
canary=${2:?canary version required}
minutes=${3:-5}
max_pct=${4:-1}

ok=0 bad=0 unknown_fail=0
end=$((SECONDS + minutes * 60))
echo "Watching $url for $minutes minutes. Abort if canary errors exceed $max_pct%."

while [ "$SECONDS" -lt "$end" ]; do
  resp=$(curl -sk -m 3 -w '\n%{http_code}' "$url/orders" || printf '\n000')
  code=${resp##*$'\n'}
  body=${resp%$'\n'*}
  version=$(printf '%s' "$body" | jq -r '.version // empty' 2>/dev/null || true)

  if [ "$version" = "$canary" ]; then
    if [ "$code" = "200" ]; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
  elif [ "$code" != "200" ] && [ -z "$version" ]; then
    # A failure with no version: the load balancer itself answered, e.g. 502.
    unknown_fail=$((unknown_fail + 1))
  fi
  sleep 0.2
done

total=$((ok + bad))
echo "Canary responses: $total   ok: $ok   failed: $bad   unattributed failures: $unknown_fail"

if [ "$total" -lt 20 ]; then
  echo "ABORT: only $total canary responses — too few to judge. Is the canary running and weighted?"
  exit 1
fi
if [ "$unknown_fail" -gt 5 ]; then
  echo "ABORT: $unknown_fail failures came from the load balancer itself."
  exit 1
fi
if awk -v b="$bad" -v t="$total" -v m="$max_pct" 'BEGIN { exit !((b * 100 / t) > m) }'; then
  echo "ABORT: canary error rate $(awk -v b="$bad" -v t="$total" 'BEGIN { printf "%.1f", b * 100 / t }')% is above $max_pct%."
  exit 1
fi
echo "PASS: canary error rate is within $max_pct%."
