terraform {
  backend "s3" {
    bucket       = "qc-tfstate-126052242757"
    key          = "envs/prod/us-east-1/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
