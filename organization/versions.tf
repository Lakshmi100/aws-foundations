terraform {
  # 1.10 or later is needed for S3-native state locking (use_lockfile).
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
