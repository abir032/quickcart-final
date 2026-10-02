resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  # Must match how the image was built: --platform linux/amd64.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = var.image
    essential = true

    portMappings = [{
      containerPort = var.container_port
      protocol      = "tcp"
    }]

    environment = [for k in sort(keys(var.environment_variables)) : {
      name  = k
      value = var.environment_variables[k]
    }]

    secrets = [for k in sort(keys(var.secrets)) : {
      name      = k
      valueFrom = var.secrets[k]
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])

  tags = var.tags
}

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Replace one task at a time without ever dropping below full strength.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # If new tasks keep failing, stop and go back to the last working version.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = 30

  # Terraform waits until the release has finished before reporting success.
  # This is the "wait for stable" step the pipeline relies on.
  wait_for_steady_state = true

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "app"
    container_port   = var.container_port
  }

  # Once created, the task count belongs to auto scaling. Without this, every
  # apply would reset it to desired_count — scaling down in the middle of a busy period.
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = var.tags
}

# ---------- auto scaling on CPU ----------

resource "aws_appautoscaling_target" "this" {
  count = var.autoscaling == null ? 0 : 1

  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.autoscaling.min
  max_capacity       = var.autoscaling.max
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.autoscaling == null ? 0 : 1

  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  # Add tasks when average CPU is above the target, remove them when below.
  # Scale out fast, scale in slowly, so a short dip doesn't remove capacity.
  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling.cpu_target
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
