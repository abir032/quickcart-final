#!/usr/bin/env bash
# Pull an app's logs for a time window into a file.
#
# Reads from the environment:
#   LOG_GROUP   e.g. /ecs/qc-dev-use1-orders
#   START, END  UTC, e.g. "2026-09-29 14:00"
#   FILTER      optional CloudWatch filter pattern, e.g. ERROR
set -euo pipefail
: "${LOG_GROUP:?}" "${START:?}" "${END:?}" "${FILTER:=}"

start_s=$(date -u -d "$START" +%s) || { echo "Could not read START: $START" >&2; exit 2; }
end_s=$(date -u -d "$END" +%s)     || { echo "Could not read END: $END" >&2; exit 2; }
[ "$end_s" -gt "$start_s" ] || { echo "END must be after START." >&2; exit 2; }
[ $((end_s - start_s)) -le 86400 ] || { echo "Keep the window to 24 hours or less." >&2; exit 2; }

args=(--log-group-name "$LOG_GROUP" --start-time "${start_s}000" --end-time "${end_s}000")
[ -n "$FILTER" ] && args+=(--filter-pattern "$FILTER")

file="logs-$(printf '%s' "$LOG_GROUP" | tr '/' '_')-$(date -u -d "$START" +%Y%m%dT%H%M).txt"

aws logs filter-log-events "${args[@]}" --output json \
  | jq -r '.events[] | "\((.timestamp / 1000 | floor | strftime("%Y-%m-%dT%H:%M:%SZ")))  \(.logStreamName)  \(.message)"' \
  > "$file"

echo "Wrote $(wc -l < "$file") lines from $LOG_GROUP between $START and $END UTC${FILTER:+ matching $FILTER} to $file"
