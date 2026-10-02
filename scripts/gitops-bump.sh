#!/usr/bin/env bash
# Point one environment at a new image tag in the GitOps repository, and push.
# Argo CD notices the commit and rolls it out. Nothing here talks to the cluster.
#
#   scripts/gitops-bump.sh ENV TAG
#
# Also the EKS rollback: run it with an older tag.
#
# Needs: GITHUB_TOKEN (write access to the GitOps repo), GITOPS_REPO (owner/name).
# GITOPS_URL overrides the clone address (for testing against a local repo).
set -euo pipefail

env_name=${1:?usage: gitops-bump.sh ENV TAG}
tag=${2:?usage: gitops-bump.sh ENV TAG}
: "${GITHUB_TOKEN:?}" "${GITOPS_REPO:?}"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Give git the token through a credential helper, so it never appears in a URL,
# in the clone's config, or in the log. The helper reads it from the environment.
# shellcheck disable=SC2016
git_auth=(-c 'credential.helper=!f() { echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f')

git "${git_auth[@]}" clone --quiet "${GITOPS_URL:-https://github.com/$GITOPS_REPO.git}" "$workdir"
cd "$workdir"

file="envs/$env_name/values.yaml"
[ -f "$file" ] || { echo "No $file in $GITOPS_REPO" >&2; exit 1; }

# The line Jenkins owns is marked:   tag: "abc1234" # quickcart:image-tag
current=$(sed -n 's/.*tag: "\([^"]*\)".*# quickcart:image-tag.*/\1/p' "$file")
[ -n "$current" ] || { echo "No line marked '# quickcart:image-tag' in $file" >&2; exit 1; }

if [ "$current" = "$tag" ]; then
  echo "$env_name already runs $tag. Nothing to change."
  exit 0
fi

sed -i.bak "s/tag: \"$current\"\(.*# quickcart:image-tag\)/tag: \"$tag\"\1/" "$file"
rm -f "$file.bak"

git -c user.name="Jenkins" -c user.email="jenkins@quickcart.invalid" \
  commit --quiet -am "Deploy $tag to $env_name (was $current)"

# Someone may have pushed in the meantime: rebase onto their change and retry.
branch=$(git rev-parse --abbrev-ref HEAD)
for attempt in 1 2 3; do
  if git "${git_auth[@]}" push --quiet origin "$branch"; then
    echo "$env_name: $current -> $tag. Argo CD will roll it out."
    exit 0
  fi
  echo "Push rejected (attempt $attempt). Rebasing and retrying." >&2
  git "${git_auth[@]}" pull --quiet --rebase origin "$branch"
done

echo "Could not push to $GITOPS_REPO after 3 attempts." >&2
exit 1
