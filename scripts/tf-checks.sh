#!/usr/bin/env bash
# Every Terraform check the pipeline runs on every change. Also run it locally
# before pushing: it is faster to fail here than in the pipeline.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== terraform fmt"
terraform fmt -check -recursive infra

echo "== terraform validate"
for dir in infra/shared infra/jenkins infra/envs/*/*; do
  [ -d "$dir" ] || continue
  echo "   $dir"
  terraform -chdir="$dir" init -input=false -backend=false >/dev/null
  terraform -chdir="$dir" validate -no-color
done

echo "== terraform test"
terraform -chdir=infra/modules/platform init -input=false -backend=false >/dev/null
terraform -chdir=infra/modules/platform test -no-color

echo "== tflint"
tflint --init >/dev/null
tflint --recursive --chdir=infra

echo "== trivy (fails on HIGH or CRITICAL not listed in .trivyignore)"
trivy config --severity HIGH,CRITICAL --exit-code 1 --ignorefile .trivyignore infra

echo "All Terraform checks passed."
