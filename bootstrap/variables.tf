variable "state_bucket_name" {
  description = "Name of the S3 bucket that holds Terraform state for every aws-foundations root. Must equal the bucket in every backend.tf."
  type        = string
  default     = "aws-foundations-tfstate-lakshmi100"
}

variable "cost_tags" {
  description = "The four cost-allocation tags applied to every taggable resource through the provider's default_tags (values from AGENTS.md)."
  type        = map(string)
  default = {
    data-product = "aws-foundations"
    environment  = "shared"
    owner        = "Lakshmi100"
    cost-center  = "offers-platform-portfolio"
  }
}
