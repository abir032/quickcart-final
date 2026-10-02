terraform {
  backend "s3" {
    bucket       = "qc-tfstate-126052242757"
    key          = "envs/dev/us-east-1/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
