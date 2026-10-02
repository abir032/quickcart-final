# The database exists when enable_database is true. The pieces after it are
# ECS-only: on EKS, External Secrets reads the secret (see modules/eks).

module "database" {
  source = "../database"
  count  = var.enable_database ? 1 : 0

  name                       = local.name
  vpc_id                     = module.network.vpc_id
  subnet_ids                 = module.network.data_subnet_ids
  allowed_security_group_ids = local.db_clients
  multi_az                   = var.db_multi_az
  deletion_protection        = var.db_deletion_protection
  tags                       = local.tags
}

# The execution role reads the database secret so ECS can hand the username
# and password to the app and the operations task. Scoped to this one secret.
data "aws_iam_policy_document" "read_db_secret" {
  count = var.enable_database && local.is_ecs ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [module.database[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "read_db_secret" {
  count = var.enable_database && local.is_ecs ? 1 : 0

  name   = "read-db-secret"
  role   = aws_iam_role.execution[0].id
  policy = data.aws_iam_policy_document.read_db_secret[0].json
}

resource "aws_cloudwatch_log_group" "ops_sql" {
  count = var.enable_database && local.is_ecs ? 1 : 0

  name              = "/ecs/${local.name}-ops-sql"
  retention_in_days = 30
  tags              = local.tags
}

locals {
  # Runs inside the VPC. Wraps one statement in a transaction and either
  # rolls it back (dry-run) or commits it. The statement arrives base64-encoded
  # so quotes and new lines survive the trip.
  ops_sql_script = <<-EOT
    set -eu
    printf '[client]\nhost=%s\nuser=%s\npassword=%s\n' "$DB_HOST" "$DB_USER" "$DB_PASSWORD" > /tmp/my.cnf
    chmod 600 /tmp/my.cnf
    echo "$SQL_B64" | base64 -d > /tmp/statement.sql
    if [ "$MODE" = "commit" ]; then END_TX="COMMIT"; else END_TX="ROLLBACK"; fi
    printf 'START TRANSACTION;\n%s;\nSELECT ROW_COUNT() AS rows_affected;\n%s;\n' "$(cat /tmp/statement.sql)" "$END_TX" > /tmp/run.sql
    echo "Mode: $MODE. Ending with: $END_TX"
    mysql --defaults-extra-file=/tmp/my.cnf --database="$DB_NAME" --table < /tmp/run.sql
    echo "Finished: $END_TX"
  EOT
}

resource "aws_ecs_task_definition" "ops_sql" {
  count = var.enable_database && local.is_ecs ? 1 : 0

  family                   = "${local.name}-ops-sql"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution[0].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "sql"
    image     = "public.ecr.aws/docker/library/mysql:8.0"
    essential = true

    # Run the script instead of starting a MySQL server.
    entryPoint = ["sh", "-c"]
    command    = [local.ops_sql_script]

    environment = [
      { name = "DB_HOST", value = module.database[0].address },
      { name = "DB_NAME", value = module.database[0].database_name },
      { name = "MODE", value = "dry-run" },
      { name = "SQL_B64", value = "" },
    ]

    secrets = [
      { name = "DB_USER", valueFrom = "${module.database[0].secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${module.database[0].secret_arn}:password::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ops_sql[0].name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ops"
      }
    }
  }])

  tags = local.tags
}
