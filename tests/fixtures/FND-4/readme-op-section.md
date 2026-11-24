# AWS Foundations

## Guardrails

Something else.

## Offers Platform existing setup (FND-4)

What was found in the Offers Platform account before the organization trail
was created (baseline taken read-only), and what was done with it.

| Kind | Name | Found | Action |
|------|------|-------|--------|
| Trail | `old-trail` | management events only, no other destination, nothing reads its bucket | Removed after the organization trail was logging; logs copied to `legacy/` |
| Trail | `data-trail` | S3 data events | Kept (requirement 7); about $0.40 per month, counted in the AC13 figure |
| Budget | `offers-v2-monthly` | $50 monthly cost budget | Kept, unchanged |
| Anomaly monitor | none found | | |

### Removing a duplicate trail

1. Check nothing reads the old bucket, with `fnd-offers-platform-admin`:

       aws s3api get-bucket-notification-configuration --bucket "$OLD_BUCKET"
       aws s3api get-bucket-replication --bucket "$OLD_BUCKET"
       aws s3control list-access-points --account-id "$OP_ID" --bucket "$OLD_BUCKET"
       aws s3api get-bucket-policy --bucket "$OLD_BUCKET"
       aws s3api get-bucket-acl --bucket "$OLD_BUCKET"
       aws glue get-tables --database-name "$DB"

2. Copy the logs: download with `fnd-offers-platform-admin`, upload with
   `fnd-management-admin` to `legacy/offers-platform-account-trail/<key>`:

       aws s3api put-object --bucket "$TRAIL_BUCKET" --key "legacy/offers-platform-account-trail/$K" \
         --body "$F" --tagging 'source=offers-platform-account-trail'

3. Check the copy: object counts match (`aws s3api list-objects-v2` on both).

4. Delete the trail:

       aws cloudtrail delete-trail --name "$OLD_TRAIL_ARN"

The old bucket is kept as it is.

## Next section
