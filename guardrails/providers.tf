# Management account only. Credentials come from AWS_PROFILE
# (fnd-management-admin). This root creates nothing in member accounts, so
# there are no member-account provider aliases.
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = var.cost_tags
  }
}
