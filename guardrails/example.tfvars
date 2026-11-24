# Copy to terraform.tfvars (untracked) and fill in the real values.
# Never commit terraform.tfvars.

alert_email = "alerts@example.com"

# Defaults, shown for reference:
# posture                   = "lean" # or "working"
# budget_limit_override_usd = null   # 0.01 only for the AC3 test alert
# anomaly_monitor_name      = "aws-foundations-services"
# anomaly_subscription_name = "aws-foundations-daily-summary"
# anomaly_threshold_usd     = 10
# trail_name                = "aws-foundations-organization-trail"
# trail_bucket_name         = "aws-foundations-cloudtrail-lakshmi100"
