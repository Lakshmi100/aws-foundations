# No profile here: credentials come from AWS_PROFILE (fnd-management-admin).
terraform {
  backend "s3" {
    bucket       = "aws-foundations-tfstate-lakshmi100"
    key          = "organization/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
