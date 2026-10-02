#!/usr/bin/env bash
# Run ONE SQL statement against an environment's database, inside a transaction,
# from a task inside the VPC. Dry-run rolls back; commit keeps the change.
#
# Reads from the environment (Jenkins parameters become environment variables):
#   ENV_DIR    infra/envs/dev/us-east-1
#   SQL        the statement
#   MODE       dry-run | commit
#   TICKET     why — required, recorded on the task
#   ALLOW_DDL  true to allow CREATE / ALTER
set -euo pipefail
: "${ENV_DIR:?}" "${SQL:?SQL is empty}" "${MODE:?}" "${TICKET:=}" "${ALLOW_DDL:=false}"

die() { echo "REFUSED: $*" >&2; exit 2; }

# ---- the guard rails ----
[ -n "$TICKET" ] || die "TICKET is required. Every change to data needs a reason on record."
case "$MODE" in dry-run|commit) ;; *) die "MODE must be dry-run or commit." ;; esac

statement=$(printf '%s' "$SQL" | sed -e 's/[[:space:]]*;[[:space:]]*$//')
upper=$(printf '%s' "$statement" | tr '[:lower:]' '[:upper:]')

case "$statement" in *";"*) die "One statement per run. Remove the semicolons inside it." ;; esac

if printf '%s' "$upper" | grep -Eq '\b(DROP|TRUNCATE)\b'; then
  die "DROP and TRUNCATE are never run from this job. They need a reviewed migration."
fi

if printf '%s' "$upper" | grep -Eq '^[[:space:]]*(CREATE|ALTER|RENAME|GRANT|REVOKE)\b'; then
  [ "$ALLOW_DDL" = "true" ] || die "This changes the schema. Tick ALLOW_DDL if that is intended."
  [ "$MODE" = "commit" ] || die "Schema changes cannot be dry-run: MySQL commits them immediately, even inside a transaction. Use commit mode."
fi

if printf '%s' "$upper" | grep -Eq '^[[:space:]]*(UPDATE|DELETE)\b' && ! printf '%s' "$upper" | grep -Eq '\bWHERE\b'; then
  die "UPDATE and DELETE need a WHERE clause. Without one they change every row."
fi

# ---- where to run it: read from Terraform, never typed ----
terraform -chdir="$ENV_DIR" init -input=false >/dev/null
out() { terraform -chdir="$ENV_DIR" output -json "$1"; }
cluster=$(out cluster_name | jq -r .)
family=$(out ops_sql_task_family | jq -r .)
log_group=$(out ops_sql_log_group | jq -r .)
subnets=$(out task_subnet_ids | jq -r 'join(",")')
sg=$(out app_security_group_id | jq -r .)
public_ip=$(out assign_public_ip | jq -r 'if . then "ENABLED" else "DISABLED" end')
[ "$family" != "null" ] || die "$ENV_DIR has no database. Set enable_database = true first."

sql_b64=$(printf '%s' "$statement" | base64 -w0)
started_by=$(printf 'sql-%s' "$TICKET" | tr -cd 'A-Za-z0-9_-' | cut -c1-36)

overrides=$(jq -cn --arg sql "$sql_b64" --arg mode "$MODE" \
  '{containerOverrides: [{name: "sql", environment: [{name: "SQL_B64", value: $sql}, {name: "MODE", value: $mode}]}]}')

echo "Running in $cluster, mode $MODE, ticket $TICKET:"
echo "  $statement"

task_arn=$(aws ecs run-task --cluster "$cluster" --task-definition "$family" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=$public_ip}" \
  --overrides "$overrides" --started-by "$started_by" \
  --query 'tasks[0].taskArn' --output text)

aws ecs wait tasks-stopped --cluster "$cluster" --tasks "$task_arn"
exit_code=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" --query 'tasks[0].containers[0].exitCode' --output text)

# Logs can arrive a few seconds after the task stops.
sleep 5
aws logs get-log-events --log-group-name "$log_group" \
  --log-stream-name "ops/sql/${task_arn##*/}" --start-from-head \
  --output json | jq -r '.events[].message'

if [ "$exit_code" != "0" ]; then
  echo "The statement failed (exit code $exit_code). Nothing was committed."
  exit 1
fi
