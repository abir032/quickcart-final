#!/usr/bin/env bash
# Plan one environment and post the plan onto the pull request as a comment.
#
#   scripts/plan-comment.sh ENV_DIR
#
# Needs: GITHUB_TOKEN, GH_REPO (owner/name), CHANGE_ID (the pull request number,
# which Jenkins sets on pull request builds).
set -euo pipefail
dir=${1:?usage: plan-comment.sh ENV_DIR}
: "${GITHUB_TOKEN:?}" "${GH_REPO:?}" "${CHANGE_ID:?}"

"$(dirname "$0")/release.sh" "$dir" --plan-file pr.tfplan
terraform -chdir="$dir" show -no-color pr.tfplan > plan.txt
summary=$(grep -E '^(Plan:|No changes)' plan.txt | tail -1 || true)

# GitHub comments are limited to 65,536 characters.
if [ "$(wc -c < plan.txt)" -gt 60000 ]; then
  head -c 60000 plan.txt > plan-short.txt
  printf '\n\n... plan cut short. The full plan is in the Jenkins build artifacts.\n' >> plan-short.txt
else
  cp plan.txt plan-short.txt
fi

jq -Rs --arg dir "$dir" --arg summary "$summary" \
  '{body: ("### Terraform plan for `" + $dir + "`\n\n**" + $summary + "**\n\n<details><summary>Full plan</summary>\n\n```\n" + . + "\n```\n</details>")}' \
  plan-short.txt > comment.json

curl -fsS -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GH_REPO/issues/$CHANGE_ID/comments" \
  --data @comment.json > /dev/null

echo "Posted the plan for $dir to pull request #$CHANGE_ID: $summary"
