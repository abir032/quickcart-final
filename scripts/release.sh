#!/usr/bin/env bash
# Apply one environment with explicit release settings.
#
#   scripts/release.sh ENV_DIR [--stable TAG] [--canary TAG] [--weight N] [--plan-file FILE]
#
# Any setting not given keeps its current live value, read from Terraform's
# outputs. That way a canary change never accidentally resets the stable version.
# With --plan-file, it only writes a plan for someone to approve.
set -euo pipefail

dir=${1:?usage: release.sh ENV_DIR [options]}
shift

stable="" canary="" weight="" planfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stable)       stable=$2; shift 2 ;;
    --canary)       canary=$2; shift 2 ;;
    --weight)       weight=$2; shift 2 ;;
    --plan-file)    planfile=$2; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

terraform -chdir="$dir" init -input=false >/dev/null

current() { terraform -chdir="$dir" output -raw "$1" 2>/dev/null || true; }
: "${stable:=$(current stable_image_tag)}"
: "${canary:=$(current canary_image_tag)}"
: "${weight:=$(current canary_weight)}"

# Only pass values we know. On the very first apply there are no outputs yet,
# so terraform.tfvars supplies them instead.
vars=()
[ -n "$stable" ] && vars+=(-var "stable_image_tag=$stable")
[ -n "$canary" ] && vars+=(-var "canary_image_tag=$canary")
[ -n "$weight" ] && vars+=(-var "canary_weight=$weight")

echo "Release settings for $dir: stable=${stable:-tfvars} canary=${canary:-tfvars} weight=${weight:-tfvars}"

if [ -n "$planfile" ]; then
  terraform -chdir="$dir" plan -input=false -out="$planfile" "${vars[@]}"
else
  terraform -chdir="$dir" apply -input=false -auto-approve "${vars[@]}"
fi
