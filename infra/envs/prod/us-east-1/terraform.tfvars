state_bucket = "qc-tfstate-126052242757"

environment = "prod"
region      = "us-east-1"
vpc_cidr    = "10.30.0.0/16"
enable_nat  = true

zone_name   = "codeemit.com"
hostname    = "orders"
alert_email = "fahim.faez@bjitgroup.com"

desired_count      = 2
max_count          = 6
log_retention_days = 30

enable_database = true
# Multi-AZ doubles the database cost. Turn it on for real production.
db_multi_az            = false
db_deletion_protection = true

slo_availability_percent = 99.5

stable_image_tag = "v2"
canary_image_tag = "v2"
canary_weight    = 0
