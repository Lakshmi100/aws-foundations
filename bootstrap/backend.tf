# State lives in the bucket this root creates. For the very first apply this
# file is moved aside (README "Setup", step 2), then restored and the local
# state is moved in with `terraform init -migrate-state`.
#
# No profile here: credentials come from AWS_PROFILE (fnd-management-admin).
terraform {
  backend "s3" {
    bucket       = "aws-foundations-tfstate-lakshmi100"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
