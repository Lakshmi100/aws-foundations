# AWS can activate a tag only after it has seen it on a billed resource
# (README pre-check). Cost Explorer itself is enabled by FND-3.
resource "aws_ce_cost_allocation_tag" "this" {
  for_each = toset(keys(var.cost_tags))

  tag_key = each.key
  status  = "Active"
}
