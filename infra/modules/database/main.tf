resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "Database: MySQL from the app and operations tasks only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from allowed security groups"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = var.allowed_security_group_ids
  }

  # No egress block: a database answers connections, it never starts them.

  tags = merge(var.tags, { Name = "${var.name}-db" })
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-mysql8"
  family = "mysql8.0"

  # Log queries slower than 2 seconds, so slow SQL can be found later.
  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2"
  }

  tags = var.tags
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-db"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "quickcart"
  username = "qcadmin"

  # RDS creates the password, keeps it in Secrets Manager and can rotate it.
  # It never appears in this code, in the plan, or in the state file.
  manage_master_user_password = true

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period   = var.backup_retention_days
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.name}-db-final" : null

  tags = var.tags
}
