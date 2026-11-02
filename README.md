# AWS Foundations

Organization-wide AWS setup shared by every project: the AWS Organization and
its accounts, IAM Identity Center, budgets and cost anomaly alerts, and the
organization CloudTrail trail.

> Part of the Offers Platform portfolio project. Project-wide docs (roadmap,
> business problem, ADRs) live in
> [offers-platform-workspace](https://github.com/Lakshmi100/offers-platform-workspace).

## What is here

| Path | What it holds |
|------|---------------|
| `bootstrap/` | The S3 bucket that holds Terraform state for every root here (versioned, encrypted, TLS only, no public access, S3-native locking) |
| `organization/` | The organization, the three accounts, Identity Center (user, permission sets, assignments), the permissions boundary in each member account, and `OrganizationAccountAccessRole` in Offers Platform |
| `tests/FND-3.sh` | Acceptance checks for FND-3, run against the real accounts (read-only) |
| `Makefile` | `make test` (terraform validate for every root) and `make lint` (terraform fmt -check) |

The three accounts:

| Account | How it gets into the organization |
|---------|-----------------------------------|
| Management + Shared Services | Signed up by hand; it is the management account |
| ABC Bank | Created by `organization/` |
| Offers Platform | Existing account; invited and joins |

Region: everything uses `us-east-1`. Cost: the only billed resource is the
state bucket (a few KB of state, SSE-S3, no DynamoDB table, no KMS key), well
under $0.05 per month. Organizations, Identity Center, permission sets and
assignments are free.

## Tools

- Terraform 1.10 or later (S3-native state locking needs it)
- AWS CLI v2 (for `aws sso login`)
- `jq` and `bash`
- `make test` and `make lint` need no AWS credentials

## Manual steps

AWS allows these only by hand, or they come before Terraform can run. They are
done by the owner, in this order, as part of [Setup](#setup):

| Step | Who and where | What |
|------|---------------|------|
| 0 | Owner, Offers Platform, existing credentials, read only | Take the IAM baseline (before the invitation) |
| 1 | Owner, management account root, console | Sign up, root MFA, enable Identity Center and its MFA setting, create the engineer user and the `Administrator` permission set and its assignment, enable Cost Explorer, then sign out of root |
| 3 | Owner, `fnd-management-admin` | Tag the Identity Center instance (CLI), send the invitation to Offers Platform (CLI) |
| 4 | Owner, Offers Platform, existing credentials | Accept the invitation |
| 6 | Owner, ABC Bank and Offers Platform root users | Set root MFA in ABC Bank; confirm root MFA and no root access keys in Offers Platform |

Agents never use, change or create root credentials, and nothing here creates
IAM users or access keys.

## CLI profiles

Every Terraform run and every test uses Identity Center profiles; there are no
stored keys. Add this to `~/.aws/config` (replace the placeholders; the
start URL is on the Identity Center settings page, and the account IDs are in
`aws organizations list-accounts` or the `organization/` outputs). Add each
member-account profile once its assignment exists (Setup steps 3 and 5).

```ini
[sso-session fnd]
sso_start_url = https://<your-identity-center-subdomain>.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile fnd-management-admin]
sso_session = fnd
sso_account_id = <management-account-id>
sso_role_name = Administrator
region = us-east-1

[profile fnd-abc-bank-admin]
sso_session = fnd
sso_account_id = <abc-bank-account-id>
sso_role_name = Administrator
region = us-east-1

[profile fnd-offers-platform-admin]
sso_session = fnd
sso_account_id = <offers-platform-account-id>
sso_role_name = Administrator
region = us-east-1

[profile fnd-abc-bank-engineering]
sso_session = fnd
sso_account_id = <abc-bank-account-id>
sso_role_name = ABCBankEngineering
region = us-east-1

[profile fnd-offers-platform-engineering]
sso_session = fnd
sso_account_id = <offers-platform-account-id>
sso_role_name = OffersPlatformEngineering
region = us-east-1
```

Sign in once per session with `aws sso login --sso-session fnd` (MFA is asked
every time). Check a profile with `aws sts get-caller-identity --profile <name>`.

| Profile | Use it for |
|---------|------------|
| `fnd-management-admin` | Terraform in this repo (`AWS_PROFILE`), organization and Identity Center changes, recovery of member accounts |
| `fnd-abc-bank-admin`, `fnd-offers-platform-admin` | Used by `organization/` for member-account resources; setup and recovery only |
| `fnd-abc-bank-engineering` | Day-to-day ABC Bank session work (ABC-6 on) |
| `fnd-offers-platform-engineering` | Day-to-day new work in Offers Platform |

Administrator profiles are for setup, recovery and long-lived foundations,
not day-to-day work. The tests read the profile names from
`FND_MANAGEMENT_ADMIN`, `FND_ABC_BANK_ADMIN`, `FND_OFFERS_PLATFORM_ADMIN`,
`FND_ABC_BANK_ENGINEERING` and `FND_OFFERS_PLATFORM_ENGINEERING`, defaulting
to the names above.

### Roles that engineering roles create

Both engineering roles can create, change and delete IAM roles and instance
profiles only under the path `/eng/` and only with the permissions boundary
`EngineeringPermissionsBoundary` attached (in ABC Bank, also DMS's fixed
`dms-vpc-role` and `dms-cloudwatch-logs-role` names at path `/`, still with
the boundary). Later Terraform must set `path = "/eng/"` and
`permissions_boundary = "arn:aws:iam::<account-id>:policy/EngineeringPermissionsBoundary"`
on every such role. Neither role can create or edit customer-managed
policies: bounded roles use inline policies or existing managed policies.

## Setup

The first apply, once. Run every command from the repo root unless a step says
otherwise. Do the steps in order; each step says who does it.

### Step 0: Offers Platform IAM baseline (owner, before the invitation)

Before Offers Platform is invited (step 3), take a read-only snapshot of its
IAM users, access keys and roles with the credentials you use for that account
today. Nothing is created or changed. The regression checks (`REG-TC67`,
`REG-TC68` in `tests/FND-3.sh`) compare against it, and the roles in it are by
definition the "existing v1/v2 roles".

The snapshot goes to `${FND3_BASELINE_DIR:-$HOME/.fnd-3-baseline}`, **outside
the repo**. It holds full key IDs, ARNs and the account ID, so never commit
it, paste it into a PR, or set `FND3_BASELINE_DIR` to a path inside this
repo.

```bash
export OP_PROFILE=<your existing Offers Platform profile>
bash <<'EOF'
set -euo pipefail
B=${FND3_BASELINE_DIR:-$HOME/.fnd-3-baseline}
P=${OP_PROFILE:?set OP_PROFILE to your existing Offers Platform profile}
mkdir -p "$B" && chmod 700 "$B"

# users.json: aws iam list-users
aws --profile "$P" iam list-users --output json >"$B/users.json"

# access-keys.json: aws iam list-access-keys for each user
jq -r '.Users[].UserName' "$B/users.json" | while read -r u; do
  aws --profile "$P" iam list-access-keys --user-name "$u" --output json
done | jq -s . >"$B/access-keys.json"

# roles.json: every role outside /aws-reserved/ and /aws-service-role/, with
# get-role, its attached policies, its inline policy names and documents
aws --profile "$P" iam list-roles --output json |
  jq -r '.Roles[] | select((.Path | startswith("/aws-reserved/") or startswith("/aws-service-role/")) | not) | .RoleName' |
  while read -r r; do
    role=$(aws --profile "$P" iam get-role --role-name "$r" --query Role --output json)
    attached=$(aws --profile "$P" iam list-attached-role-policies --role-name "$r" --query AttachedPolicies --output json)
    names=$(aws --profile "$P" iam list-role-policies --role-name "$r" --query PolicyNames --output json)
    inline=$(jq -r '.[]' <<<"$names" | while read -r p; do
      aws --profile "$P" iam get-role-policy --role-name "$r" --policy-name "$p" \
        --query '{PolicyName: PolicyName, PolicyDocument: PolicyDocument}' --output json
    done | jq -s .)
    jq -n --argjson role "$role" --argjson attached "$attached" --argjson names "$names" --argjson inline "$inline" \
      '{Role: $role, AttachedPolicies: $attached, PolicyNames: $names, RolePolicies: $inline}'
  done | jq -s . >"$B/roles.json"

ls -l "$B"
EOF
```

Check before going on: the three files exist and are not empty, and
`OrganizationAccountAccessRole` is **not** in `roles.json`
(`jq -r '.[].Role.RoleName' "${FND3_BASELINE_DIR:-$HOME/.fnd-3-baseline}/roles.json"`).
If it is, stop and decide with the owner what to do before step 5.

### Step 1: management account, by hand as root (owner, console)

1. Sign up the Management + Shared Services account. Set MFA on the root user
   (authenticator app or security key). Create no root access keys.
2. Account settings: turn on **IAM user and role access to Billing
   information** (so the Administrator role can use Cost Explorer).
3. Enable **IAM Identity Center** in `us-east-1`. This creates the
   organization with all features.
4. Identity Center, Settings, Authentication, Multi-factor authentication:
   - prompt users for MFA **every time they sign in**;
   - MFA types: **authenticator apps** and **security keys** only;
   - if a user has no registered MFA device: **require them to register an
     MFA device at sign in**.
5. Identity Center, Users: create the engineer. Use the same values as
   `organization/terraform.tfvars`: user name `engineer_user_name`, first and
   last name `engineer_given_name` and `engineer_family_name`, display name
   `<given name> <family name>`, primary email `engineer_email`.
6. Identity Center, Permission sets: create a custom permission set named
   exactly `Administrator`, session duration 1 hour, with the AWS managed
   policy `AdministratorAccess`. Assign it to the engineer in the management
   account.
7. Billing and Cost Management: open **Cost Explorer** once to enable it. In
   Cost Management preferences keep **linked account access** on (ABC Bank
   reads Cost Explorer from its own account).
8. Sign out of root. From here on, use the portal and the
   `fnd-management-admin` profile. Add the `sso-session` and that profile to
   `~/.aws/config` ([CLI profiles](#cli-profiles)) and run
   `aws sso login --sso-session fnd`.

### Step 2: state bucket (owner, `fnd-management-admin`)

The bucket does not exist yet, so the first apply uses local state, which is
then moved into the bucket.

```bash
export AWS_PROFILE=fnd-management-admin
mv bootstrap/backend.tf bootstrap/backend.tf.off
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply
mv bootstrap/backend.tf.off bootstrap/backend.tf
terraform -chdir=bootstrap init -migrate-state   # answer "yes" to copy the state
rm -f bootstrap/terraform.tfstate bootstrap/terraform.tfstate.backup
terraform -chdir=bootstrap plan                  # no changes
```

If the bucket name is taken, pick another, then set it in
`bootstrap/variables.tf` (`state_bucket_name`) and in every `backend.tf`
together.

### Step 3: organization, ABC Bank and Identity Center (owner, `fnd-management-admin`)

Prepare the root. The member-account profiles do not work yet, so point the
two member-account provider aliases at the management profile for steps 3
and 5. That is safe: every member-account resource has a precondition that
fails the plan if its profile is not the right account.

```bash
cp organization/example.tfvars organization/terraform.tfvars   # fill in the real values
export AWS_PROFILE=fnd-management-admin
export TF_VAR_abc_bank_admin_profile=fnd-management-admin
export TF_VAR_offers_platform_admin_profile=fnd-management-admin
terraform -chdir=organization init
```

Look up the IDs of what step 1 created:

```bash
ORG_ID=$(aws organizations describe-organization --query Organization.Id --output text)
MGMT_ID=$(aws sts get-caller-identity --query Account --output text)
read -r INSTANCE_ARN IDENTITY_STORE_ID <<<"$(aws sso-admin list-instances \
  --query 'Instances[0].[InstanceArn,IdentityStoreId]' --output text)"
USER_ID=$(aws identitystore get-user-id --identity-store-id "$IDENTITY_STORE_ID" \
  --alternate-identifier '{"UniqueAttribute":{"AttributePath":"userName","AttributeValue":"<engineer_user_name>"}}' \
  --query UserId --output text)
for ps in $(aws sso-admin list-permission-sets --instance-arn "$INSTANCE_ARN" --query 'PermissionSets[]' --output text); do
  name=$(aws sso-admin describe-permission-set --instance-arn "$INSTANCE_ARN" --permission-set-arn "$ps" \
    --query PermissionSet.Name --output text)
  [ "$name" = Administrator ] && ADMIN_PS_ARN=$ps
done
echo "$ORG_ID $INSTANCE_ARN $IDENTITY_STORE_ID $USER_ID $ADMIN_PS_ARN"
```

Import them:

```bash
cd organization
terraform import aws_organizations_organization.this "$ORG_ID"
terraform import aws_organizations_account.management "$MGMT_ID"
terraform import aws_identitystore_user.engineer "$IDENTITY_STORE_ID/$USER_ID"
terraform import aws_ssoadmin_permission_set.administrator "$ADMIN_PS_ARN,$INSTANCE_ARN"
terraform import aws_ssoadmin_managed_policy_attachment.administrator \
  "arn:aws:iam::aws:policy/AdministratorAccess,$ADMIN_PS_ARN,$INSTANCE_ARN"
terraform import 'aws_ssoadmin_account_assignment.administrator["management"]' \
  "$USER_ID,USER,$MGMT_ID,AWS_ACCOUNT,$ADMIN_PS_ARN,$INSTANCE_ARN"
```

Create the ABC Bank account (takes a few minutes; AWS creates its
`OrganizationAccountAccessRole`):

```bash
terraform apply -target=aws_organizations_account.abc_bank
```

Apply the organization and Identity Center resources that do not depend on
Offers Platform. This also adds the cost tags to the management account and
the imported `Administrator` permission set. **Read the plan: it must not
create `aws_organizations_account.offers_platform`.** Every Terraform command
before step 5 uses `-target` for that reason.

```bash
terraform apply \
  -target=aws_organizations_organization.this \
  -target=aws_organizations_account.management \
  -target=aws_identitystore_user.engineer \
  -target=aws_ssoadmin_permission_set.administrator \
  -target=aws_ssoadmin_managed_policy_attachment.administrator \
  -target=aws_ssoadmin_permission_set.abc_bank_engineering \
  -target=aws_ssoadmin_permission_set_inline_policy.abc_bank_engineering \
  -target=aws_ssoadmin_permission_set.offers_platform_engineering \
  -target=aws_ssoadmin_account_assignment.abc_bank_engineering
cd ..
```

The plan may show in-place updates to the imported objects (for example the
permission set description, the user's email type, or the organization's
service principals and SCP policy type). Those are expected. A replacement
(`-/+`) of any imported object is not: stop and ask.

Tag the Identity Center instance (Terraform has no resource for it), then
check the tags:

```bash
aws sso-admin tag-resource --instance-arn "$INSTANCE_ARN" --resource-arn "$INSTANCE_ARN" \
  --tags Key=data-product,Value=aws-foundations Key=environment,Value=shared \
         Key=owner,Value=Lakshmi100 Key=cost-center,Value=offers-platform-portfolio
aws sso-admin list-tags-for-resource --instance-arn "$INSTANCE_ARN" --resource-arn "$INSTANCE_ARN"
```

Invite Offers Platform. First, with your existing Offers Platform
credentials, check it is not in another organization (this must fail with
`AWSOrganizationsNotInUseException`) and is not on the AWS Free plan:

```bash
aws organizations describe-organization --profile "$OP_PROFILE"
```

Then, from the management account:

```bash
aws organizations invite-account-to-organization \
  --target Id=<offers-platform-account-id>,Type=ACCOUNT
```

### Step 4: accept the invitation (owner, inside Offers Platform)

Sign in to Offers Platform with your existing credentials. AWS Organizations,
Invitations: accept the invitation from the management account. Billing moves
to the management account from now on. The account's IAM users, keys and
v1/v2 roles are not changed.

### Step 5: Offers Platform and the member-account resources (owner, `fnd-management-admin`)

Still with the two `TF_VAR_..._profile` variables from step 3 set.

First check, with your existing Offers Platform credentials, that there is no
`OrganizationAccountAccessRole` yet. This must fail with `NoSuchEntity`. If
the role exists, stop and ask: do not import it, it may be in use.

```bash
aws iam get-role --role-name OrganizationAccountAccessRole --profile "$OP_PROFILE"
```

Import the account, then apply the remaining Identity Center resources
(administrator assignments in ABC Bank and Offers Platform, the Offers
Platform engineering policy and assignment, and the account's tags):

```bash
cd organization
terraform import aws_organizations_account.offers_platform <offers-platform-account-id>
terraform apply \
  -target=aws_organizations_account.offers_platform \
  -target=aws_ssoadmin_account_assignment.administrator \
  -target=aws_ssoadmin_permission_set_inline_policy.offers_platform_engineering \
  -target=aws_ssoadmin_account_assignment.offers_platform_engineering
```

Add the four member-account profiles to `~/.aws/config`
([CLI profiles](#cli-profiles)), run `aws sso login --sso-session fnd`, and
check each one returns the right account with `aws sts get-caller-identity`.
Then go back to the real member-account profiles and run the full apply. It
creates the two permissions boundaries and Offers Platform's
`OrganizationAccountAccessRole`.

```bash
unset TF_VAR_abc_bank_admin_profile TF_VAR_offers_platform_admin_profile
terraform apply
terraform plan -detailed-exitcode   # exit code 0: no changes
cd ..
```

### Step 6: member-account root users (owner)

- **ABC Bank:** sign in as root with the ABC Bank account email, use "Forgot
  password" to set a password, then set root MFA (authenticator app or
  security key). Create no root access keys.
- **Offers Platform:** confirm the root user has MFA and no access keys.

### Checks

```bash
make lint
make test
bash tests/FND-3.sh          # needs all five profiles signed in and the step 0 baseline
```

`tests/FND-3.sh` only reads (apart from a scratch clone and a held state lock
it releases). It prints one PASS, FAIL or MANUAL line per acceptance
criterion, then `REG-TC67` and `REG-TC68`. Diagnostics go to stderr; MANUAL
lines say what to check by hand. Its output goes in the PR, after checking
it shows no account IDs or key IDs.

Teardown: none. Everything here is long-lived. Accounts, the organization, the
state bucket, the `Administrator` permission set and its assignments have
`prevent_destroy`; accounts also have `close_on_deletion = false`. Never close
an account, leave the organization, or remove the last administrator
assignment.

## Recovery

If Identity Center or a permission set breaks and the portal or the
`fnd-*` profiles stop working:

### Management account: root user with MFA

1. Sign in to the console as the management account **root** user, with its
   MFA device. Root is for recovery only.
2. Fix the cause in IAM Identity Center: re-enable the instance, the user or
   its MFA device, or recreate the `Administrator` permission set
   (`AdministratorAccess`, 1 hour) and its assignment to the engineer in the
   management account.
3. Sign out of root. Sign in through the portal, run
   `terraform -chdir=organization plan` with `fnd-management-admin`, and
   import or apply until it shows no changes.
4. If the state bucket policy ever locks the Administrator role out, root can
   still read and edit the bucket and its policy.

### Member accounts (ABC Bank, Offers Platform): OrganizationAccountAccessRole

From the management account's Administrator role, assume
`OrganizationAccountAccessRole` in the member account. It has
`AdministratorAccess` and trusts only the management account. AWS created it
in ABC Bank; this repo created it in Offers Platform.

```bash
aws sts assume-role --profile fnd-management-admin \
  --role-arn arn:aws:iam::<member-account-id>:role/OrganizationAccountAccessRole \
  --role-session-name recovery
```

Or add a profile and use it directly:

```ini
[profile fnd-abc-bank-recovery]
source_profile = fnd-management-admin
role_arn = arn:aws:iam::<abc-bank-account-id>:role/OrganizationAccountAccessRole
region = us-east-1

[profile fnd-offers-platform-recovery]
source_profile = fnd-management-admin
role_arn = arn:aws:iam::<offers-platform-account-id>:role/OrganizationAccountAccessRole
region = us-east-1
```

If the management account's Administrator role is broken too, first recover
it with root (above). The member accounts' root users have MFA and no access
keys; use them only if both paths above fail (ABC Bank root via password
recovery on its email).

## Offers Platform IAM inventory

What exists in the Offers Platform account today, for the later story that
replaces its IAM users and keys. Nothing here is changed by this repo: the
v1/v2 tools (`customer-spend-analytics`) still use these keys, and the v1/v2
roles carry no permissions boundary.

This repo is public, so the tables hold only: user names (or labels, if a
name is personal), the **last 4 characters** of each key ID, key status, the
last-used date, service and region, and role names and paths. No full key
IDs, ARNs or account IDs. The owner fills them in from the step 0 baseline and
reviews them before commit.

### IAM users

| User | Created |
|------|---------|
| _to be filled by the owner_ | |

Users with no access keys appear here and not in the next table.

### Access keys

| User | Key ID (last 4) | Status | Last used | Service | Region |
|------|-----------------|--------|-----------|---------|--------|
| _to be filled by the owner_ | | | | | |

A key that was never used shows "never used" in the last three columns.

### Existing v1/v2 IAM roles

| Role | Path |
|------|------|
| _to be filled by the owner_ | |

These are exactly the roles in the step 0 baseline `roles.json`. Roles this
repo adds (`OrganizationAccountAccessRole`, the `AWSReservedSSO_` roles) are
not listed.

### How to fill in the tables

Run with your existing Offers Platform profile (or, after step 5,
`fnd-offers-platform-admin`). The output is already redacted to the fields
above; paste it into the tables.

```bash
export OP_PROFILE=<profile>
bash <<'EOF'
set -euo pipefail
P=$OP_PROFILE
B=${FND3_BASELINE_DIR:-$HOME/.fnd-3-baseline}

echo "## users"
aws --profile "$P" iam list-users --query 'Users[].[UserName,CreateDate]' --output text |
  while read -r u c; do echo "| $u | ${c%%T*} |"; done

echo "## access keys"
for u in $(aws --profile "$P" iam list-users --query 'Users[].UserName' --output text); do
  aws --profile "$P" iam list-access-keys --user-name "$u" \
    --query 'AccessKeyMetadata[].[AccessKeyId,Status]' --output text |
    while read -r k s; do
      read -r d svc reg <<<"$(aws --profile "$P" iam get-access-key-last-used --access-key-id "$k" \
        --query 'AccessKeyLastUsed.[LastUsedDate,ServiceName,Region]' --output text)"
      if [ "$d" = None ]; then d="never used" svc="never used" reg="never used"; fi
      echo "| $u | ${k: -4} | $s | ${d%%T*} | $svc | $reg |"
    done
done

echo "## v1/v2 roles (from the baseline)"
jq -r '.[] | (.Role // .) | "| \(.RoleName) | \(.Path) |"' "$B/roles.json"
EOF
```

Cross-check with the credential report (`aws iam generate-credential-report`,
then `aws iam get-credential-report --query Content --output text | base64 --decode`):
its `access_key_N_last_used_date` and `access_key_N_last_used_service`
columns must agree with the table.
