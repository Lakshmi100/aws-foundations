output "budget_name" {
  description = "Name of the organization-wide monthly cost budget."
  value       = aws_budgets_budget.organization.name
}

output "budget_limit_usd" {
  description = "Effective monthly budget limit in USD (posture limit, or the AC3 override when set)."
  value       = local.budget_limit
}

output "anomaly_monitor_arn" {
  description = "ARN of the per-service Cost Anomaly Detection monitor."
  value       = aws_ce_anomaly_monitor.services.arn
}

output "anomaly_subscription_arn" {
  description = "ARN of the daily anomaly email subscription."
  value       = aws_ce_anomaly_subscription.daily.arn
}

output "trail_arn" {
  description = "ARN of the organization CloudTrail trail."
  value       = aws_cloudtrail.organization.arn
}

output "trail_home_region" {
  description = "Home region of the organization CloudTrail trail."
  value       = aws_cloudtrail.organization.home_region
}

output "trail_bucket_name" {
  description = "Name of the S3 bucket that holds the trail's logs."
  value       = aws_s3_bucket.trail.id
}

output "trail_bucket_arn" {
  description = "ARN of the S3 bucket that holds the trail's logs."
  value       = aws_s3_bucket.trail.arn
}

output "active_cost_allocation_tags" {
  description = "Cost-allocation tag keys set to Active."
  value       = sort([for t in aws_ce_cost_allocation_tag.this : t.tag_key])
}
