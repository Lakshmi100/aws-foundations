# Management account. Credentials come from AWS_PROFILE (fnd-management-admin).
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = var.cost_tags
  }
}
