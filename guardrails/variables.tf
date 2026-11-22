# Personal values (the alert email) go in the untracked terraform.tfvars;
# example.tfvars shows the shape.

variable "alert_email" {
  description = "The engineer's email address: subscriber for the budget alerts and the daily anomaly summary. Set only in the untracked terraform.tfvars."
  type        = string
  sensitive   = true
}

variable "posture" {
  description = "Spending posture that sets the monthly budget limit: lean ($100) or working ($300). Lowercase only."
  type        = string
  default     = "lean"

  validation {
    condition     = contains(["lean", "working"], var.posture)
    error_message = "posture must be exactly lean or working (lowercase)."
  }
}

variable "budget_limits_usd" {
  description = "Monthly budget limit in USD for each posture."
  type        = map(number)
  default = {
    lean    = 100
    working = 300
  }
}

variable "budget_limit_override_usd" {
  description = "Temporary budget limit in USD, used only for the AC3 test alert (0.01). Leave null; it must be null again when the test is done."
  type        = number
  default     = null
  nullable    = true

  validation {
    condition     = var.budget_limit_override_usd == null ? true : var.budget_limit_override_usd > 0
    error_message = "budget_limit_override_usd must be null or greater than 0."
  }
}

variable "budget_name" {
  description = "Name of the organization-wide monthly cost budget."
  type        = string
  default     = "aws-foundations-monthly-cost"
}

variable "anomaly_monitor_name" {
  description = "Name of the per-service Cost Anomaly Detection monitor. When an existing monitor is imported, this is its current name so the import shows no rename."
  type        = string
  default     = "aws-foundations-services"
}

variable "anomaly_subscription_name" {
  description = "Name of the daily anomaly email subscription. When an existing subscription is imported, this may be its current name if the API does not rename it in place."
  type        = string
  default     = "aws-foundations-daily-summary"
}

variable "anomaly_threshold_usd" {
  description = "Total cost impact in USD at or above which an anomaly is included in the daily email summary."
  type        = number
  default     = 10
}

variable "trail_name" {
  description = "Name of the organization CloudTrail trail."
  type        = string
  default     = "aws-foundations-organization-trail"
}

variable "trail_bucket_name" {
  description = "Name of the S3 bucket in the management account that holds the trail's logs. Must be globally unique."
  type        = string
  default     = "aws-foundations-cloudtrail-lakshmi100"
}

variable "log_retention_days" {
  description = "Days after which current log objects in the trail bucket are deleted."
  type        = number
  default     = 90
}

variable "noncurrent_retention_days" {
  description = "Days after an object version is replaced or deleted before that earlier version is deleted."
  type        = number
  default     = 30
}

variable "cost_tags" {
  description = "The four cost-allocation tags applied to every taggable resource through default_tags (values from AGENTS.md). The keys are also the cost-allocation tags set to Active."
  type        = map(string)
  default = {
    data-product = "aws-foundations"
    environment  = "shared"
    owner        = "Lakshmi100"
    cost-center  = "offers-platform-portfolio"
  }
}
