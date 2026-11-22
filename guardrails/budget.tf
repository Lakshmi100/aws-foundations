# One monthly cost budget for the whole organization. In the management
# account an unfiltered budget covers the consolidated bill. Cost types are
# left at the AWS defaults (unblended).
resource "aws_budgets_budget" "organization" {
  name         = var.budget_name
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = format("%.2f", local.budget_limit)
  limit_unit   = "USD"

  dynamic "notification" {
    for_each = toset([50, 80, 100])

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}
