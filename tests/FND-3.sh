#!/usr/bin/env bash
# FND-3 acceptance checks: AWS organization, accounts and Identity Center access.
#
# Runs against the real accounts and only reads state. The exceptions are the
# ones the test plan names: a scratch clone of this repo (TC54, TC66) and a
# held Terraform state lock (TC58). Both are removed or released on exit.
# Short assume-role sessions (TC47) stay in memory. Denials are checked only
# with the IAM policy simulator, never with the real call.
#
# Output (stdout): exactly one line per acceptance criterion, in the order
# AC1..AC16 with AC7b after AC7, then REG-TC67 and REG-TC68:
#     PASS|FAIL|MANUAL <ID> <text>
# A FAIL lists the sub-checks (test plan case IDs) that failed. Exit 1 if any
# line is FAIL. Diagnostics, the AC8 inventory and the TC70/TC71 PR evidence
# go to stderr. Raw AWS and Terraform errors go to a scratch log that is
# deleted on exit (set FND3_DEBUG=1 to see them on stderr instead).
#
# Inputs (environment):
#   FND_MANAGEMENT_ADMIN            default fnd-management-admin
#   FND_ABC_BANK_ADMIN              default fnd-abc-bank-admin
#   FND_OFFERS_PLATFORM_ADMIN       default fnd-offers-platform-admin
#   FND_ABC_BANK_ENGINEERING        default fnd-abc-bank-engineering
#   FND_OFFERS_PLATFORM_ENGINEERING default fnd-offers-platform-engineering
#   FND3_BASELINE_DIR   pre-invitation Offers Platform baseline (design 3.8
#                       step 0), default $HOME/.fnd-3-baseline. Must hold
#                       users.json, access-keys.json and roles.json.
#   FND3_STATE_BUCKET   override for the state bucket name (default: the
#                       bootstrap output state_bucket_name, else the backend).
#   FND3_CLONE_SOURCE   what to clone for the fresh-clone checks (default:
#                       this repo, current branch; only committed files).
#   FND3_TMPDIR         parent directory for the scratch directory.
#
# Account IDs are never written here: they come from each profile's
# sts get-caller-identity and are cross-checked with the Terraform outputs.
#
# Expected baseline shapes (design 3.8 step 0). Each file may be the raw CLI
# output or a list of such outputs; the script searches the JSON:
#   users.json        objects with UserName (aws iam list-users)
#   access-keys.json  objects with UserName, AccessKeyId, Status
#   roles.json        a list (or {"Roles": [...]}) of entries, one per role:
#                     {"Role": <get-role .Role>, "AttachedPolicies": [...],
#                      "PolicyNames": [...],
#                      "RolePolicies": [{"PolicyName", "PolicyDocument"}]}
#                     (the role fields may also sit at the top of the entry).

set -euo pipefail

export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off
export TF_IN_AUTOMATION=1
export TF_INPUT=0

FND3_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$FND3_SCRIPT_DIR/.." && pwd)

P_MGMT=${FND_MANAGEMENT_ADMIN:-fnd-management-admin}
P_ABC_ADMIN=${FND_ABC_BANK_ADMIN:-fnd-abc-bank-admin}
P_OP_ADMIN=${FND_OFFERS_PLATFORM_ADMIN:-fnd-offers-platform-admin}
P_ABC_ENG=${FND_ABC_BANK_ENGINEERING:-fnd-abc-bank-engineering}
P_OP_ENG=${FND_OFFERS_PLATFORM_ENGINEERING:-fnd-offers-platform-engineering}
ALL_PROFILES="$P_MGMT $P_ABC_ADMIN $P_OP_ADMIN $P_ABC_ENG $P_OP_ENG"

BASELINE_DIR=${FND3_BASELINE_DIR:-$HOME/.fnd-3-baseline}

# Contract names (design 3.3, 3.4, 3.7). Not account-specific.
BOUNDARY_NAME=EngineeringPermissionsBoundary
OTHER_BOUNDARY=arn:aws:iam::aws:policy/AdministratorAccess
ADMIN_ACCESS=arn:aws:iam::aws:policy/AdministratorAccess
KMS_ALIAS=alias/abc-bank-kms-key
OAAR=OrganizationAccountAccessRole
SIM=fnd3-sim
PS_ADMIN_NAME=Administrator
PS_ABC_NAME=ABCBankEngineering
PS_OP_NAME=OffersPlatformEngineering
REGION=us-east-1
ALLOW_ALL='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}]}'
# Only a 0-key placeholder; no real key is referenced (test plan Q6).
FAKE_KMS_KEY_ID=00000000-0000-0000-0000-000000000000

AC_IDS="AC1 AC2 AC3 AC4 AC5 AC6 AC7 AC7b AC8 AC9 AC10 AC11 AC12 AC13 AC14 AC15 AC16"
REG_IDS="REG-TC67 REG-TC68"

ERRLOG=/dev/null
WORK=""
CLONE=""
ANY_FAIL=0

# Discovered context (filled by discover; empty means "not found").
ACCT_MGMT="" ACCT_ABC="" ACCT_OP=""
SSO_INSTANCE_ARN="" IDENTITY_STORE_ID=""
PS_ADMIN_ARN="" PS_ABC_ARN="" PS_OP_ARN=""
ROLE_MGMT_ADMIN="" ROLE_ABC_ADMIN="" ROLE_OP_ADMIN="" ROLE_ABC_ENG="" ROLE_OP_ENG=""
BOUNDARY_ABC="" BOUNDARY_OP=""
STATE_BUCKET="" BUCKET_POLICY=""
ROOTS=""

# ---------------------------------------------------------------- helpers

log() { printf '%s\n' "$*" >&2; }

# awsp PROFILE ARGS...: aws call with the profile; raw errors go to ERRLOG.
awsp() {
  local p=$1
  shift
  aws --profile "$p" --region "$REGION" "$@" 2>>"$ERRLOG"
}

jqq() { jq "$@" 2>>"$ERRLOG"; }

days_ago() { date -u -v-"$1"d +%F 2>/dev/null || date -u -d "$1 days ago" +%F; }

expected_tag() {
  case "$1" in
    data-product) echo aws-foundations ;;
    environment) echo shared ;;
    owner) echo Lakshmi100 ;;
    cost-center) echo offers-platform-portfolio ;;
  esac
}

role_arn() { printf 'arn:aws:iam::%s:role%s' "$1" "$2"; }

ctx_boundary() {
  printf '[{"ContextKeyName":"iam:PermissionsBoundary","ContextKeyValues":["%s"],"ContextKeyType":"string"}]' "$1"
}

CTX_KMS='[{"ContextKeyName":"kms:ResourceAliases","ContextKeyValues":["alias/abc-bank-kms-key"],"ContextKeyType":"stringList"}]'

# ctx_principal PRINCIPAL_ARN SECURE(true|false)
ctx_principal() {
  printf '[{"ContextKeyName":"aws:PrincipalArn","ContextKeyValues":["%s"],"ContextKeyType":"string"},{"ContextKeyName":"aws:SecureTransport","ContextKeyValues":["%s"],"ContextKeyType":"boolean"}]' "$1" "$2"
}

# sim_run MODE PROFILE SOURCE RESOURCE CONTEXT ACTIONS...
#   MODE principal: SOURCE is the role ARN (simulate-principal-policy).
#   MODE custom:    SOURCE is the identity policy JSON (simulate-custom-policy);
#                   SIM_BOUNDARY, if set, is the permissions-boundary input.
#   Optional globals: SIM_RESOURCE_POLICY, SIM_RESOURCE_OWNER, SIM_CALLER_ARN.
# Prints "<action> <decision>" per action. Non-zero if the call failed.
sim_run() {
  local mode=$1 profile=$2 source=$3 resource=$4 context=$5
  shift 5
  local -a args
  if [ "$mode" = principal ]; then
    args=(iam simulate-principal-policy --policy-source-arn "$source")
  else
    args=(iam simulate-custom-policy --policy-input-list "$source")
    if [ -n "${SIM_BOUNDARY:-}" ]; then
      args+=(--permissions-boundary-policy-input-list "$SIM_BOUNDARY")
    fi
  fi
  args+=(--action-names "$@" --resource-arns "$resource")
  if [ -n "$context" ]; then args+=(--context-entries "$context"); fi
  if [ -n "${SIM_RESOURCE_POLICY:-}" ]; then args+=(--resource-policy "$SIM_RESOURCE_POLICY"); fi
  if [ -n "${SIM_RESOURCE_OWNER:-}" ]; then args+=(--resource-owner "$SIM_RESOURCE_OWNER"); fi
  if [ -n "${SIM_CALLER_ARN:-}" ]; then args+=(--caller-arn "$SIM_CALLER_ARN"); fi
  local out
  out=$(awsp "$profile" "${args[@]}" --output json) || return 1
  printf '%s\n' "$out" | jqq -r '.EvaluationResults[] | "\(.EvalActionName) \(.EvalDecision)"'
}

# expect_sim EXPECT(allowed|denied) TAG MODE PROFILE SOURCE RESOURCE CONTEXT ACTIONS...
# Prints one problem line per action whose decision is not the expected one.
# Denials record which kind (implicitDeny or explicitDeny) on stderr.
expect_sim() {
  local expect=$1 tag=$2
  shift 2
  local source=$3 resource=$4
  if [ -z "$source" ]; then
    echo "$tag: principal or policy not found, cannot simulate"
    return 0
  fi
  case "$resource" in
    arn:aws:iam:::* | arn:aws:kms:*::* | arn:aws:rds-db:*::*)
      echo "$tag: account ID unknown, cannot simulate"
      return 0
      ;;
  esac
  local res
  if ! res=$(sim_run "$@"); then
    echo "$tag: simulation call failed"
    return 0
  fi
  shift 5
  local a d
  for a in "$@"; do
    d=$(printf '%s\n' "$res" | awk -v a="$a" '$1 == a { print $2; exit }')
    case "$expect:$d" in
      allowed:allowed) ;;
      denied:implicitDeny | denied:explicitDeny) log "  $tag $a: $d" ;;
      *) echo "$tag $a expected $expect, got ${d:-no result}" ;;
    esac
  done
}

# get_policy_doc PROFILE POLICY_ARN: default version document, compact JSON.
get_policy_doc() {
  local v
  v=$(awsp "$1" iam get-policy --policy-arn "$2" --query Policy.DefaultVersionId --output text) || return 1
  [ -n "$v" ] && [ "$v" != None ] || return 1
  awsp "$1" iam get-policy-version --policy-arn "$2" --version-id "$v" \
    --query PolicyVersion.Document --output json | jqq -c 'if type == "string" then fromjson else . end'
}

# find_sso_role PROFILE PERMISSION_SET_NAME: ARN of the AWSReservedSSO_<name>_ role.
find_sso_role() {
  local out
  out=$(awsp "$1" iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ --output json) || return 0
  printf '%s\n' "$out" | jqq -r --arg p "AWSReservedSSO_$2_" \
    '[.Roles[] | select(.RoleName | startswith($p)) | .Arn] | if length == 1 then .[0] else empty end'
}

# caller_json PROFILE: cached sts get-caller-identity.
caller_json() {
  local f="$WORK/caller.$1.json"
  if [ ! -s "$f" ]; then
    awsp "$1" sts get-caller-identity --output json >"$f" || { rm -f "$f"; return 1; }
  fi
  cat "$f"
}

caller_account() { caller_json "$1" | jqq -r '.Account // empty'; }

# tf_out ROOT NAME: Terraform output from the scratch clone (strings raw, others JSON).
tf_out() {
  local f="$WORK/tfout.$1.json"
  [ -s "$f" ] || return 0
  jqq -r --arg n "$2" '(.[$n].value) as $v | if $v == null then empty elif ($v | type) == "string" then $v else ($v | tojson) end' "$f"
}

# cred_report PROFILE LABEL: credential report CSV (cached in WORK).
cred_report() {
  local f="$WORK/cred.$2.csv" state i
  if [ ! -s "$f" ]; then
    i=0
    while [ $i -lt 30 ]; do
      state=$(awsp "$1" iam generate-credential-report --query State --output text) || return 1
      case "$state" in
        COMPLETE) break ;;
        STARTED | INPROGRESS) sleep 2 ;;
        *) return 1 ;;
      esac
      i=$((i + 1))
    done
    [ "$state" = COMPLETE ] || return 1
    awsp "$1" iam get-credential-report --query Content --output text | base64 --decode >"$f" 2>>"$ERRLOG" || { rm -f "$f"; return 1; }
    [ -s "$f" ] || return 1
  fi
  cat "$f"
}

# csv_rows FILE: prints "user|mfa_active|ak1_active|ak2_active" per row.
csv_rows() {
  awk -F, 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
    { print $h["user"] "|" $h["mfa_active"] "|" $h["access_key_1_active"] "|" $h["access_key_2_active"] }'
}

baseline_ok() { [ -s "$BASELINE_DIR/$1" ] && [ -r "$BASELINE_DIR/$1" ] && jq -e . "$BASELINE_DIR/$1" >/dev/null 2>&1; }

# Normalised baseline roles, one compact JSON object per line.
baseline_roles() {
  jqq -c '
    def doc: if type == "string" then (try fromjson catch .) else . end;
    (if type == "object" then (.Roles // [.]) else . end) | .[]
    | (.Role // .) as $r
    | {
        name: $r.RoleName,
        path: $r.Path,
        trust: ($r.AssumeRolePolicyDocument | doc),
        boundary: ($r.PermissionsBoundary // null),
        has_policy_data: (has("AttachedPolicies") or has("AttachedRolePolicies") or ($r | has("AttachedPolicies"))),
        attached: ([(.AttachedPolicies // .AttachedRolePolicies // $r.AttachedPolicies // [])[] | .PolicyArn] | sort),
        inline_names: ((.PolicyNames // ((.RolePolicies // .InlinePolicies // []) | map(.PolicyName))) | sort),
        inline: ((.RolePolicies // .InlinePolicies // []) | map({key: .PolicyName, value: (.PolicyDocument | doc)}) | from_entries)
      }' "$BASELINE_DIR/roles.json"
}

# ---------------------------------------------------------------- pure checks (self-tested)

# ac1_eval ORG_JSON CALLER_ACCOUNT EXPECTED_MGMT_ID
ac1_eval() {
  local fs master
  fs=$(printf '%s' "$1" | jqq -r '.Organization.FeatureSet // empty') || fs=""
  master=$(printf '%s' "$1" | jqq -r '.Organization.MasterAccountId // empty') || master=""
  [ "$fs" = ALL ] || echo "TC01 FeatureSet is ${fs:-unknown}, not ALL"
  if [ -z "$master" ] || [ -z "$2" ] || [ "$master" != "$2" ]; then
    echo "TC02 the management profile's account is not the management account"
  fi
  if [ -z "$3" ] || [ "$master" != "$3" ]; then
    echo "TC02 management account differs from the Terraform output (or output missing)"
  fi
  return 0
}

# ac2_eval ACCOUNTS_JSON MGMT_ID ABC_ID OP_ID
ac2_eval() {
  local j=$1 n bad id label c jm
  n=$(printf '%s' "$j" | jqq '.Accounts | length') || n=""
  [ "$n" = 3 ] || echo "TC05 ${n:-unknown} accounts listed, expected 3"
  bad=$(printf '%s' "$j" | jqq '[.Accounts[]? | select(((.State // .Status) // "") != "ACTIVE")] | length') || bad=""
  [ "$bad" = 0 ] || echo "TC05 ${bad:-unknown} account(s) not ACTIVE"
  for label in management abc_bank offers_platform; do
    case $label in management) id=$2 ;; abc_bank) id=$3 ;; offers_platform) id=$4 ;; esac
    if [ -z "$id" ]; then
      echo "TC06 expected $label account ID unknown"
      continue
    fi
    c=$(printf '%s' "$j" | jqq --arg id "$id" '[.Accounts[]? | select(.Id == $id)] | length') || c=""
    if [ "$c" != 1 ]; then
      echo "TC06 $label account listed ${c:-0} times, expected once"
      continue
    fi
    jm=$(printf '%s' "$j" | jqq -r --arg id "$id" '.Accounts[] | select(.Id == $id) | .JoinedMethod // empty')
    case $label in
      abc_bank) [ "$jm" = CREATED ] || echo "TC06 abc_bank JoinedMethod is ${jm:-unknown}, expected CREATED" ;;
      offers_platform) [ "$jm" = INVITED ] || echo "TC06 offers_platform JoinedMethod is ${jm:-unknown}, expected INVITED" ;;
    esac
  done
  return 0
}

# tags_eval TAG LABEL TAGS_JSON_ARRAY ([{"Key":..,"Value":..}]); exact keys and values.
tags_eval() {
  local tag=$1 label=$2 j=$3 k v e
  if [ -z "$j" ] || ! printf '%s' "$j" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "$tag $label: tags could not be read"
    return 0
  fi
  for k in data-product environment owner cost-center; do
    e=$(expected_tag "$k")
    v=$(printf '%s' "$j" | jqq -r --arg k "$k" '[.[] | select(.Key == $k) | .Value][0] // empty')
    if [ -z "$v" ]; then
      echo "$tag $label: tag $k missing"
    elif [ "$v" != "$e" ]; then
      echo "$tag $label: tag $k=$v, expected $e"
    fi
  done
  return 0
}

# ---------------------------------------------------------------- discovery

discover() {
  local p
  for p in $ALL_PROFILES; do caller_json "$p" >/dev/null || log "profile $p: sts get-caller-identity failed"; done
  ACCT_MGMT=$(caller_account "$P_MGMT")
  ACCT_ABC=$(caller_account "$P_ABC_ADMIN")
  ACCT_OP=$(caller_account "$P_OP_ADMIN")

  local inst
  if inst=$(awsp "$P_MGMT" sso-admin list-instances --output json); then
    printf '%s\n' "$inst" >"$WORK/sso-instances.json"
    SSO_INSTANCE_ARN=$(printf '%s' "$inst" | jqq -r 'if (.Instances | length) == 1 then .Instances[0].InstanceArn else empty end')
    IDENTITY_STORE_ID=$(printf '%s' "$inst" | jqq -r 'if (.Instances | length) == 1 then .Instances[0].IdentityStoreId else empty end')
  fi
  if [ -n "$SSO_INSTANCE_ARN" ]; then
    local ps name
    : >"$WORK/permission-sets.txt"
    for ps in $(awsp "$P_MGMT" sso-admin list-permission-sets --instance-arn "$SSO_INSTANCE_ARN" --query 'PermissionSets[]' --output text); do
      name=$(awsp "$P_MGMT" sso-admin describe-permission-set --instance-arn "$SSO_INSTANCE_ARN" --permission-set-arn "$ps" \
        --query PermissionSet.Name --output text) || name=""
      printf '%s %s\n' "$name" "$ps" >>"$WORK/permission-sets.txt"
    done
    PS_ADMIN_ARN=$(awk -v n="$PS_ADMIN_NAME" '$1 == n { print $2 }' "$WORK/permission-sets.txt")
    PS_ABC_ARN=$(awk -v n="$PS_ABC_NAME" '$1 == n { print $2 }' "$WORK/permission-sets.txt")
    PS_OP_ARN=$(awk -v n="$PS_OP_NAME" '$1 == n { print $2 }' "$WORK/permission-sets.txt")
  fi

  ROLE_MGMT_ADMIN=$(find_sso_role "$P_MGMT" "$PS_ADMIN_NAME")
  ROLE_ABC_ADMIN=$(find_sso_role "$P_ABC_ADMIN" "$PS_ADMIN_NAME")
  ROLE_OP_ADMIN=$(find_sso_role "$P_OP_ADMIN" "$PS_ADMIN_NAME")
  ROLE_ABC_ENG=$(find_sso_role "$P_ABC_ADMIN" "$PS_ABC_NAME")
  ROLE_OP_ENG=$(find_sso_role "$P_OP_ADMIN" "$PS_OP_NAME")
  [ -z "$ACCT_ABC" ] || BOUNDARY_ABC="arn:aws:iam::$ACCT_ABC:policy/$BOUNDARY_NAME"
  [ -z "$ACCT_OP" ] || BOUNDARY_OP="arn:aws:iam::$ACCT_OP:policy/$BOUNDARY_NAME"

  setup_clone
  STATE_BUCKET=${FND3_STATE_BUCKET:-}
  [ -n "$STATE_BUCKET" ] || STATE_BUCKET=$(tf_out bootstrap state_bucket_name)
  if [ -z "$STATE_BUCKET" ] && [ -s "$CLONE/bootstrap/.terraform/terraform.tfstate" ]; then
    STATE_BUCKET=$(jqq -r '.backend.config.bucket // empty' "$CLONE/bootstrap/.terraform/terraform.tfstate")
  fi
  if [ -n "$STATE_BUCKET" ]; then
    BUCKET_POLICY=$(awsp "$P_MGMT" s3api get-bucket-policy --bucket "$STATE_BUCKET" --query Policy --output text) || BUCKET_POLICY=""
  fi
  return 0
}

# Fresh clone of the committed branch, then init and state list in every root (TC54).
setup_clone() {
  local branch src root name
  src=${FND3_CLONE_SOURCE:-$REPO_DIR}
  branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>>"$ERRLOG") || branch=HEAD
  CLONE="$WORK/clone"
  if [ "$branch" = HEAD ]; then
    git clone --quiet "$src" "$CLONE" >>"$ERRLOG" 2>&1 || { log "git clone failed"; CLONE=""; return 0; }
  else
    git clone --quiet --branch "$branch" "$src" "$CLONE" >>"$ERRLOG" 2>&1 || { log "git clone failed"; CLONE=""; return 0; }
  fi
  ROOTS=""
  for root in "$CLONE"/*/; do
    name=$(basename "$root")
    case "$name" in docs | tests) continue ;; esac
    ls "$root"*.tf >/dev/null 2>&1 || continue
    ROOTS="$ROOTS $name"
  done
  for name in $ROOTS; do
    tf_root "$name" init -input=false -no-color >>"$ERRLOG" 2>&1
    echo $? >"$WORK/init.$name.rc"
    tf_root "$name" state list >"$WORK/state.$name" 2>>"$ERRLOG"
    echo $? >"$WORK/statelist.$name.rc"
    tf_root "$name" output -json >"$WORK/tfout.$name.json" 2>>"$ERRLOG" || : >"$WORK/tfout.$name.json"
  done
  return 0
}

# tf_root ROOT ARGS...: terraform in the clone's root, as the management admin.
tf_root() {
  local name=$1
  shift
  AWS_PROFILE=$P_MGMT terraform -chdir="$CLONE/$name" "$@"
}

has_root() { case " $ROOTS " in *" $1 "*) return 0 ;; esac; return 1; }

varfile_args() { [ -f "$REPO_DIR/$1/terraform.tfvars" ] && printf -- '-var-file=%s' "$REPO_DIR/$1/terraform.tfvars"; return 0; }

# ---------------------------------------------------------------- AC checks
# Each prints problem lines (or "@MANUAL <text>") on stdout.

check_ac1() {
  local org mo
  org=$(awsp "$P_MGMT" organizations describe-organization --output json) || { echo "TC01 describe-organization failed (management profile)"; org='{}'; }
  ac1_eval "$org" "$ACCT_MGMT" "$(tf_out organization management_account_id)"
  local p label id master
  for p in "$P_ABC_ADMIN" "$P_OP_ADMIN"; do
    label=$p
    mo=$(awsp "$p" organizations describe-organization --output json) || { echo "TC03 describe-organization failed ($label)"; continue; }
    id=$(printf '%s' "$mo" | jqq -r '.Organization.Id // empty')
    master=$(printf '%s' "$mo" | jqq -r '.Organization.MasterAccountId // empty')
    [ -n "$id" ] && [ "$id" = "$(printf '%s' "$org" | jqq -r '.Organization.Id // empty')" ] || echo "TC03 $label sees a different organization"
    [ -n "$master" ] && [ "$master" = "$ACCT_MGMT" ] || echo "TC03 $label sees a different management account"
    [ "$(caller_account "$p")" != "$master" ] || echo "TC03 $label account is the management account"
  done
}

check_ac2() {
  local acc abc op tf
  acc=$(awsp "$P_MGMT" organizations list-accounts --output json) || { echo "TC05 list-accounts failed"; acc='{}'; }
  abc=$ACCT_ABC
  op=$ACCT_OP
  tf=$(tf_out organization abc_bank_account_id)
  [ -n "$tf" ] && [ "$tf" = "$abc" ] || echo "TC06 ABC Bank admin profile account differs from the Terraform output (or output missing)"
  tf=$(tf_out organization offers_platform_account_id)
  [ -n "$tf" ] && [ "$tf" = "$op" ] || echo "TC06 Offers Platform admin profile account differs from the Terraform output (or output missing)"
  if baseline_ok roles.json && [ -n "$op" ]; then
    local pre
    pre=$(jqq -r '[.. | strings | select(test("^arn:aws:iam::[0-9]{12}:role/")) | capture("^arn:aws:iam::(?<a>[0-9]{12}):").a] | unique | if length == 1 then .[0] else empty end' "$BASELINE_DIR/roles.json")
    [ -z "$pre" ] || [ "$pre" = "$op" ] || echo "TC06 Offers Platform account is not the pre-existing account from the baseline"
  fi
  ac2_eval "$acc" "$ACCT_MGMT" "$abc" "$op"

  local hs
  hs=$(awsp "$P_MGMT" organizations list-handshakes-for-organization --output json) || { echo "TC08 list-handshakes-for-organization failed"; return 0; }
  local open accepted
  open=$(printf '%s' "$hs" | jqq '[.Handshakes[]? | select(.State == "OPEN")] | length')
  [ "$open" = 0 ] || echo "TC08 ${open:-unknown} handshake(s) left OPEN"
  accepted=$(printf '%s' "$hs" | jqq --arg op "$op" '[.Handshakes[]? | select(.Action == "INVITE" and .State == "ACCEPTED" and any(.Parties[]?; .Type == "ACCOUNT" and .Id == $op))] | length')
  [ -n "$op" ] && [ "${accepted:-0}" -ge 1 ] 2>/dev/null || echo "TC08 no ACCEPTED invitation for the Offers Platform account (handshakes are listed for 30 days only)"
}

check_ac3() {
  local n users
  if [ ! -s "$WORK/sso-instances.json" ]; then
    echo "TC09 sso-admin list-instances failed"
  else
    n=$(jqq '.Instances | length' "$WORK/sso-instances.json")
    [ "$n" = 1 ] || echo "TC09 ${n:-0} Identity Center instances in $REGION, expected 1"
  fi
  if [ -n "$IDENTITY_STORE_ID" ]; then
    users=$(awsp "$P_MGMT" identitystore list-users --identity-store-id "$IDENTITY_STORE_ID" --query 'length(Users)' --output text) || users=""
    [ "$users" = 1 ] || echo "TC09 ${users:-unknown} Identity Center users, expected 1"
  else
    echo "TC09 identity store not found"
  fi
  echo "@MANUAL sign out of the Identity Center portal and sign in again, then again in a private window: MFA is asked both times (TC10); Settings > Authentication > MFA shows every sign-in, authenticator app or security key only, registration required (TC11). Evidence in the PR"
}

check_ac4() {
  local p acct arn expect_acct expect_ps tc
  for p in $ALL_PROFILES; do
    if ! aws configure list-profiles 2>>"$ERRLOG" | grep -qxF "$p"; then
      echo "TC15 profile $p is not configured"
      continue
    fi
    [ -z "$(aws configure get aws_access_key_id --profile "$p" 2>>"$ERRLOG" || true)" ] || echo "TC15 profile $p has a stored access key"
    if [ -z "$(aws configure get sso_session --profile "$p" 2>>"$ERRLOG" || true)" ] &&
      [ -z "$(aws configure get sso_start_url --profile "$p" 2>>"$ERRLOG" || true)" ]; then
      echo "TC15 profile $p is not an Identity Center profile"
    fi
  done
  for p in $ALL_PROFILES; do
    case $p in
      "$P_MGMT") expect_acct=$(tf_out organization management_account_id); expect_ps=$PS_ADMIN_NAME; tc=TC12 ;;
      "$P_ABC_ADMIN") expect_acct=$(tf_out organization abc_bank_account_id); expect_ps=$PS_ADMIN_NAME; tc=TC12 ;;
      "$P_OP_ADMIN") expect_acct=$(tf_out organization offers_platform_account_id); expect_ps=$PS_ADMIN_NAME; tc=TC12 ;;
      "$P_ABC_ENG") expect_acct=$(tf_out organization abc_bank_account_id); expect_ps=$PS_ABC_NAME; tc=TC13 ;;
      "$P_OP_ENG") expect_acct=$(tf_out organization offers_platform_account_id); expect_ps=$PS_OP_NAME; tc=TC14 ;;
    esac
    acct=$(caller_account "$p")
    arn=$(caller_json "$p" | jqq -r '.Arn // empty')
    if [ -z "$acct" ]; then
      echo "$tc $p: get-caller-identity failed"
      continue
    fi
    [ -n "$expect_acct" ] && [ "$acct" = "$expect_acct" ] || echo "$tc $p: account is not the expected one (or Terraform output missing)"
    case "$arn" in
      *":assumed-role/AWSReservedSSO_${expect_ps}_"*) ;;
      *) echo "$tc $p: caller is not the $expect_ps permission-set role" ;;
    esac
  done

  # TC16 assignments.
  if [ -z "$SSO_INSTANCE_ARN" ]; then
    echo "TC16 Identity Center instance not found"
    return 0
  fi
  local ps psarn label id n want
  for ps in "$PS_ADMIN_NAME" "$PS_ABC_NAME" "$PS_OP_NAME"; do
    case $ps in "$PS_ADMIN_NAME") psarn=$PS_ADMIN_ARN ;; "$PS_ABC_NAME") psarn=$PS_ABC_ARN ;; *) psarn=$PS_OP_ARN ;; esac
    if [ -z "$psarn" ]; then
      echo "TC16 permission set $ps not found"
      continue
    fi
    for label in management abc_bank offers_platform; do
      case $label in management) id=$ACCT_MGMT ;; abc_bank) id=$ACCT_ABC ;; *) id=$ACCT_OP ;; esac
      [ -n "$id" ] || { echo "TC16 $label account ID unknown"; continue; }
      n=$(awsp "$P_MGMT" sso-admin list-account-assignments --instance-arn "$SSO_INSTANCE_ARN" --account-id "$id" \
        --permission-set-arn "$psarn" --query 'length(AccountAssignments)' --output text) || { echo "TC16 list-account-assignments failed ($ps, $label)"; continue; }
      case "$ps:$label" in
        "$PS_ADMIN_NAME":*) want=yes ;;
        "$PS_ABC_NAME":abc_bank | "$PS_OP_NAME":offers_platform) want=yes ;;
        *) want=no ;;
      esac
      if [ "$want" = yes ] && [ "${n:-0}" -lt 1 ] 2>/dev/null; then echo "TC16 $ps not assigned in $label"; fi
      if [ "$want" = no ] && [ "${n:-0}" != 0 ]; then echo "TC16 $ps is assigned in $label"; fi
    done
  done
}

check_ac5() {
  local r=$ROLE_ABC_ENG a=$ACCT_ABC b
  b=$(ctx_boundary "$BOUNDARY_ABC")
  expect_sim allowed TC17 principal "$P_ABC_ADMIN" "$r" '*' "" \
    rds:CreateDBInstance ec2:CreateSecurityGroup ec2:CreateInstanceConnectEndpoint ssm:StartSession \
    dms:CreateReplicationInstance secretsmanager:CreateSecret logs:CreateLogGroup tag:GetResources iam:ListUsers
  expect_sim allowed TC17 principal "$P_ABC_ADMIN" "$r" "arn:aws:rds-db:$REGION:$a:dbuser:db-FND3SIM/$SIM" "" rds-db:connect
  expect_sim allowed "TC18 with-boundary" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" "/eng/$SIM")" "$b" iam:CreateRole

  # TC19: real Cost Explorer call, last 7 days.
  local ce
  ce=$(awsp "$P_ABC_ENG" ce get-cost-and-usage --time-period "Start=$(days_ago 7),End=$(days_ago 0)" \
    --granularity DAILY --metrics UnblendedCost --output json) || ce=""
  printf '%s' "$ce" | jq -e '.ResultsByTime | type == "array"' >/dev/null 2>&1 || echo "TC19 ce get-cost-and-usage failed for the ABC Bank engineering profile"

  expect_sim allowed "TC20 eng-role" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" "/eng/$SIM")" "" \
    iam:PassRole iam:DeleteRole iam:UpdateRole
  expect_sim allowed "TC20 eng-instance-profile" principal "$P_ABC_ADMIN" "$r" "arn:aws:iam::$a:instance-profile/eng/$SIM" "" \
    iam:CreateInstanceProfile
  expect_sim allowed TC20 principal "$P_ABC_ADMIN" "$r" '*' "" \
    ec2-instance-connect:OpenTunnel ec2:RunInstances ec2:CreateNetworkInterface ec2:CreateVpcEndpoint iam:GetRole iam:ListRoles
  expect_sim allowed "TC73 dms-vpc-role with-boundary" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" /dms-vpc-role)" "$b" iam:CreateRole
  expect_sim allowed "TC73 dms-cloudwatch-logs-role with-boundary" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" /dms-cloudwatch-logs-role)" "$b" iam:CreateRole
}

check_ac6() {
  local r=$ROLE_ABC_ENG a=$ACCT_ABC b key
  b=$(ctx_boundary "$BOUNDARY_ABC")
  key="arn:aws:kms:$REGION:$a:key/$FAKE_KMS_KEY_ID"
  expect_sim denied "TC21 no-boundary" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" "/eng/$SIM")" "" iam:CreateRole
  expect_sim denied TC21 principal "$P_ABC_ADMIN" "$r" '*' "" \
    iam:CreateUser iam:CreateAccessKey iam:DeleteRolePermissionsBoundary organizations:LeaveOrganization \
    account:CloseAccount sso:CreatePermissionSet aws-portal:ModifyBilling
  expect_sim denied "TC22 OAAR" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" "/$OAAR")" "" iam:PassRole
  expect_sim denied "TC22 root-path" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" "/$SIM")" "" iam:PassRole
  expect_sim denied "TC23 abc-bank-kms-key" principal "$P_ABC_ADMIN" "$r" "$key" "$CTX_KMS" kms:ScheduleKeyDeletion kms:PutKeyPolicy
  expect_sim denied "TC24 other-boundary" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" "/eng/$SIM")" "$(ctx_boundary "$OTHER_BOUNDARY")" iam:CreateRole
  expect_sim denied "TC24 no-context" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" "/eng/$SIM")" "" iam:CreateRole
  expect_sim denied "TC25 OAAR" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" "/$OAAR")" "" \
    iam:AttachRolePolicy iam:PutRolePolicy iam:UpdateAssumeRolePolicy iam:DeleteRole
  expect_sim denied "TC25 OAAR other-boundary" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" "/$OAAR")" "$(ctx_boundary "$OTHER_BOUNDARY")" \
    iam:PutRolePermissionsBoundary
  expect_sim denied "TC26 key" principal "$P_ABC_ADMIN" "$r" "$key" "$CTX_KMS" kms:DisableKey
  expect_sim denied TC26 principal "$P_ABC_ADMIN" "$r" '*' "" \
    kms:CreateKey organizations:CreateAccount sso:CreateAccountAssignment sso:DeletePermissionSet account:PutAlternateContact
  expect_sim denied "TC27 boundary-policy" principal "$P_ABC_ADMIN" "$r" "$BOUNDARY_ABC" "" iam:CreatePolicyVersion iam:DeletePolicy
  expect_sim denied "TC27 new-policy" principal "$P_ABC_ADMIN" "$r" "arn:aws:iam::$a:policy/$SIM" "" iam:CreatePolicy
  expect_sim denied "TC73 root-path with-boundary" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" "/$SIM")" "$b" iam:CreateRole
  expect_sim denied "TC73 dms-vpc-role no-context" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" /dms-vpc-role)" "" iam:CreateRole
  expect_sim denied "TC73 dms-cloudwatch-logs-role no-context" principal "$P_ABC_ADMIN" "$r" "$(role_arn "$a" /dms-cloudwatch-logs-role)" "" iam:CreateRole
}

check_ac7() {
  local r=$ROLE_OP_ENG a=$ACCT_OP b
  b=$(ctx_boundary "$BOUNDARY_OP")
  expect_sim denied "TC27 boundary-policy" principal "$P_OP_ADMIN" "$r" "$BOUNDARY_OP" "" iam:CreatePolicyVersion iam:DeletePolicy
  expect_sim denied "TC27 new-policy" principal "$P_OP_ADMIN" "$r" "arn:aws:iam::$a:policy/$SIM" "" iam:CreatePolicy

  expect_sim allowed TC28 principal "$P_OP_ADMIN" "$r" '*' "" s3:ListBucket glue:StartJobRun
  expect_sim allowed "TC28 with-boundary" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" "/eng/$SIM")" "$b" iam:CreateRole
  expect_sim allowed "TC28 eng-role" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" "/eng/$SIM")" "" iam:PassRole

  expect_sim denied "TC29 no-boundary" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" "/eng/$SIM")" "" iam:CreateRole
  expect_sim denied TC29 principal "$P_OP_ADMIN" "$r" '*' "" \
    iam:CreateUser iam:CreateAccessKey iam:DeleteRolePermissionsBoundary organizations:LeaveOrganization \
    account:CloseAccount sso:CreatePermissionSet aws-portal:ModifyBilling billing:UpdateBillingPreferences

  # TC30: identity = the engineering role's policies, boundary = the Offers Platform boundary.
  local idpol bdoc
  idpol=$(role_policies_json "$P_OP_ADMIN" "$r") || idpol=""
  bdoc=$(get_policy_doc "$P_OP_ADMIN" "$BOUNDARY_OP") || bdoc=""
  if [ -z "$idpol" ] || [ -z "$bdoc" ]; then
    echo "TC30 engineering role policies or boundary document could not be read"
  else
    SIM_BOUNDARY=$bdoc expect_sim_multi denied TC30 "$P_OP_ADMIN" "$idpol" '*' "" iam:CreateUser
  fi

  expect_sim denied "TC31 other-boundary" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" "/eng/$SIM")" "$(ctx_boundary "$OTHER_BOUNDARY")" iam:CreateRole
  expect_sim denied "TC31 OAAR" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" "/$OAAR")" "" iam:PassRole
  expect_sim denied "TC31 root-path" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" "/$SIM")" "" iam:PassRole

  expect_sim allowed TC32 principal "$P_OP_ADMIN" "$r" '*' "" \
    iam:GetRole iam:ListRoles iam:ListUsers ce:GetCostAndUsage budgets:ViewBudget kms:CreateKey
  expect_sim allowed "TC32 with-boundary" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" "/eng/$SIM")" "$b" \
    iam:AttachRolePolicy iam:DetachRolePolicy iam:PutRolePolicy iam:DeleteRolePolicy
  expect_sim allowed "TC32 eng-role" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" "/eng/$SIM")" "" iam:DeleteRole
  expect_sim allowed "TC32 eng-instance-profile" principal "$P_OP_ADMIN" "$r" "arn:aws:iam::$a:instance-profile/eng/$SIM" "" iam:CreateInstanceProfile

  # TC33: the recovery role and one existing v1/v2 role from the baseline.
  expect_sim denied "TC33 OAAR" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" "/$OAAR")" "" \
    iam:AttachRolePolicy iam:PutRolePolicy iam:UpdateAssumeRolePolicy iam:DeleteRole
  if ! baseline_ok roles.json; then
    echo "TC33 baseline roles.json missing or unreadable"
  else
    local v name path
    v=$(baseline_roles | jqq -r -s '([.[] | select(.path == "/")] + [.[] | select((.path // "/") | startswith("/eng/") | not)]) | .[0] // empty | "\(.name) \(.path // "/")"')
    if [ -z "$v" ]; then
      echo "TC33 no v1/v2 role found in the baseline"
    else
      read -r name path <<<"$v"
      expect_sim denied "TC33 v1/v2 role $name" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" "$path$name")" "" \
        iam:AttachRolePolicy iam:PutRolePolicy iam:UpdateAssumeRolePolicy iam:DeleteRole
    fi
  fi

  expect_sim denied TC34 principal "$P_OP_ADMIN" "$r" '*' "" \
    sso:CreateAccountAssignment sso:DeletePermissionSet organizations:CreateAccount account:PutAlternateContact \
    aws-portal:ModifyAccount billing:PutContractInformation
  expect_sim denied "TC34 boundary-policy" principal "$P_OP_ADMIN" "$r" "$BOUNDARY_OP" "" iam:CreatePolicyVersion

  expect_sim denied "TC73 root-path with-boundary" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" "/$SIM")" "$b" iam:CreateRole
  expect_sim denied "TC73 dms-vpc-role with-boundary" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" /dms-vpc-role)" "$b" iam:CreateRole
  expect_sim denied "TC73 dms-cloudwatch-logs-role with-boundary" principal "$P_OP_ADMIN" "$r" "$(role_arn "$a" /dms-cloudwatch-logs-role)" "$b" iam:CreateRole
}

# role_policies_json PROFILE ROLE_ARN: newline-free list of the role's policy
# documents (inline and attached), one compact JSON document per line.
role_policies_json() {
  local name pn pa out=""
  [ -n "$2" ] || return 1
  name=${2##*/}
  for pn in $(awsp "$1" iam list-role-policies --role-name "$name" --query 'PolicyNames[]' --output text); do
    out="$out$(awsp "$1" iam get-role-policy --role-name "$name" --policy-name "$pn" --query PolicyDocument --output json | jqq -c 'if type == "string" then fromjson else . end')
"
  done
  for pa in $(awsp "$1" iam list-attached-role-policies --role-name "$name" --query 'AttachedPolicies[].PolicyArn' --output text); do
    out="$out$(get_policy_doc "$1" "$pa")
"
  done
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# expect_sim_multi EXPECT TAG PROFILE POLICY_LINES RESOURCE CONTEXT ACTIONS...
# simulate-custom-policy with several identity policies (one per line).
expect_sim_multi() {
  local expect=$1 tag=$2 profile=$3 pols=$4 resource=$5 context=$6
  shift 6
  local -a args
  args=(iam simulate-custom-policy --policy-input-list)
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && args+=("$line")
  done <<<"$pols"
  if [ -n "${SIM_BOUNDARY:-}" ]; then args+=(--permissions-boundary-policy-input-list "$SIM_BOUNDARY"); fi
  args+=(--action-names "$@" --resource-arns "$resource")
  if [ -n "$context" ]; then args+=(--context-entries "$context"); fi
  local out a d
  if ! out=$(awsp "$profile" "${args[@]}" --output json); then
    echo "$tag: simulation call failed"
    return 0
  fi
  for a in "$@"; do
    d=$(printf '%s' "$out" | jqq -r --arg a "$a" '[.EvaluationResults[] | select(.EvalActionName == $a) | .EvalDecision][0] // empty')
    case "$expect:$d" in
      allowed:allowed) ;;
      denied:implicitDeny | denied:explicitDeny) log "  $tag $a: $d" ;;
      *) echo "$tag $a expected $expect, got ${d:-no result}" ;;
    esac
  done
}

check_ac7b() {
  local label profile acct barn doc out
  local tfb
  tfb=$(tf_out organization boundary_policy_arns)
  for label in abc_bank offers_platform; do
    case $label in
      abc_bank) profile=$P_ABC_ADMIN acct=$ACCT_ABC barn=$BOUNDARY_ABC ;;
      *) profile=$P_OP_ADMIN acct=$ACCT_OP barn=$BOUNDARY_OP ;;
    esac
    if [ -z "$barn" ]; then
      echo "TC35 $label account ID unknown"
      continue
    fi
    out=$(printf '%s' "$tfb" | jqq -r --arg l "$label" '.[$l] // empty')
    [ -n "$out" ] && [ "$out" = "$barn" ] || echo "TC35 $label boundary ARN differs from the Terraform output (or output missing)"
    if ! doc=$(get_policy_doc "$profile" "$barn") || ! printf '%s' "$doc" | jq -e '.Statement' >/dev/null 2>&1; then
      echo "TC35 $label boundary policy missing or its document does not parse"
      continue
    fi
    local eng="arn:aws:iam::$acct:role/eng/$SIM"
    SIM_BOUNDARY=$doc expect_sim denied "TC36 $label" custom "$profile" "$ALLOW_ALL" '*' "" \
      iam:CreateUser iam:CreateAccessKey iam:DeleteRolePermissionsBoundary organizations:LeaveOrganization \
      account:CloseAccount sso:CreatePermissionSet aws-portal:ModifyBilling
    SIM_BOUNDARY=$doc expect_sim denied "TC36 $label no-boundary" custom "$profile" "$ALLOW_ALL" "$eng" "" iam:CreateRole
    if [ $label = abc_bank ]; then
      SIM_BOUNDARY=$doc expect_sim denied "TC37 $label abc-bank-kms-key" custom "$profile" "$ALLOW_ALL" \
        "arn:aws:kms:$REGION:$acct:key/$FAKE_KMS_KEY_ID" "$CTX_KMS" kms:Decrypt
      SIM_BOUNDARY=$doc expect_sim denied "TC38 $label cap" custom "$profile" "$ALLOW_ALL" '*' "" ec2:CreateVpc
      SIM_BOUNDARY=$doc expect_sim allowed "TC39 $label" custom "$profile" "$ALLOW_ALL" '*' "" logs:CreateLogGroup rds:CreateDBInstance
    else
      SIM_BOUNDARY=$doc expect_sim denied "TC38 $label cap" custom "$profile" "$ALLOW_ALL" '*' "" iam:CreateOpenIDConnectProvider
      SIM_BOUNDARY=$doc expect_sim allowed "TC39 $label" custom "$profile" "$ALLOW_ALL" '*' "" s3:ListBucket glue:StartJobRun
    fi
    SIM_BOUNDARY=$doc expect_sim allowed "TC39 $label with-boundary" custom "$profile" "$ALLOW_ALL" "$eng" "$(ctx_boundary "$barn")" iam:CreateRole
    SIM_BOUNDARY=$doc expect_sim denied "TC40 $label other-boundary" custom "$profile" "$ALLOW_ALL" "$eng" "$(ctx_boundary "$OTHER_BOUNDARY")" \
      iam:PutRolePermissionsBoundary iam:CreateRole
    SIM_BOUNDARY=$doc expect_sim denied "TC40 $label no-context" custom "$profile" "$ALLOW_ALL" "$eng" "" iam:CreateRole
  done
}

check_ac8() {
  local users u keys csv readme="$REPO_DIR/README.md" n_users=0 n_keys=0
  users=$(awsp "$P_OP_ADMIN" iam list-users --query 'Users[].UserName' --output text) || { echo "TC41 Offers Platform list-users failed"; return 0; }
  csv=$(cred_report "$P_OP_ADMIN" offers_platform) || echo "TC41 Offers Platform credential report failed"
  if [ ! -f "$readme" ] || ! grep -qiE '^#+ .*inventory' "$readme"; then
    echo "TC41 README.md has no Offers Platform IAM inventory section"
  fi
  log "---- AC8 Offers Platform IAM inventory (compare with README.md) ----"
  for u in $users; do
    [ "$u" = None ] && continue
    n_users=$((n_users + 1))
    keys=$(awsp "$P_OP_ADMIN" iam list-access-keys --user-name "$u" --output json) || { echo "TC41 list-access-keys failed for a user"; continue; }
    if [ "$(printf '%s' "$keys" | jqq '.AccessKeyMetadata | length')" = 0 ]; then
      log "user $u: no keys"
      continue
    fi
    local k st lu
    while read -r k st; do
      [ -n "$k" ] || continue
      n_keys=$((n_keys + 1))
      lu=$(awsp "$P_OP_ADMIN" iam get-access-key-last-used --access-key-id "$k" --output json |
        jqq -r '.AccessKeyLastUsed | if .LastUsedDate then "\(.LastUsedDate) \(.ServiceName) \(.Region)" else "never used" end') || lu="last-used lookup failed"
      log "user $u: key ...${k: -4} $st, last used: $lu"
    done < <(printf '%s' "$keys" | jqq -r '.AccessKeyMetadata[] | "\(.AccessKeyId) \(.Status)"')
  done
  if baseline_ok roles.json; then
    baseline_roles | jqq -r '"v1/v2 role: \(.name) path \(.path)"' >&2
  else
    echo "TC41 baseline roles.json missing (defines the v1/v2 roles)"
  fi
  if [ -n "${csv:-}" ]; then
    log "credential report rows (user, password_last_used, access_key_1_last_used_date, access_key_2_last_used_date):"
    printf '%s\n' "$csv" | awk -F, 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
      { print "  " $h["user"] " " $h["password_last_used"] " " $h["access_key_1_last_used_date"] " " $h["access_key_2_last_used_date"] }' >&2
  fi
  log "---- end AC8 inventory ----"
  echo "@MANUAL compare the inventory printed on stderr ($n_users users, $n_keys keys) with README.md: every user, key (last used, service), and v1/v2 role listed, edge entries shown as such (TC41, TC42)"
}

check_ac9() {
  local label profile n csv row user mfa k1 k2
  for label in management abc_bank; do
    case $label in management) profile=$P_MGMT ;; *) profile=$P_ABC_ADMIN ;; esac
    n=$(awsp "$profile" iam list-users --query 'length(Users)' --output text) || n=""
    [ "$n" = 0 ] || echo "TC43 $label: ${n:-unknown} IAM users (list-users), expected 0"
  done
  for label in management abc_bank offers_platform; do
    case $label in management) profile=$P_MGMT ;; abc_bank) profile=$P_ABC_ADMIN ;; *) profile=$P_OP_ADMIN ;; esac
    if ! csv=$(cred_report "$profile" "$label"); then
      echo "TC44 $label: credential report could not be read"
      continue
    fi
    local root_seen=no
    while IFS='|' read -r user mfa k1 k2; do
      if [ "$user" = "<root_account>" ]; then
        root_seen=yes
        [ "$mfa" = true ] || echo "TC45 $label: root user has no MFA"
        [ "$k1" = false ] && [ "$k2" = false ] || echo "TC45 $label: root user has an active access key"
      elif [ "$label" != offers_platform ]; then
        # TC46: Offers Platform users are inventoried, not judged here.
        if [ "$k1" = true ] || [ "$k2" = true ]; then echo "TC44 $label: an IAM user has an active access key"; fi
      fi
    done < <(printf '%s\n' "$csv" | csv_rows)
    [ $root_seen = yes ] || echo "TC45 $label: no root row in the credential report"
  done
}

check_ac10() {
  local label acct creds ak sk st got
  for label in abc_bank offers_platform; do
    case $label in abc_bank) acct=$ACCT_ABC ;; *) acct=$ACCT_OP ;; esac
    [ -n "$acct" ] || { echo "TC47 $label account ID unknown"; continue; }
    creds=$(awsp "$P_MGMT" sts assume-role --role-arn "$(role_arn "$acct" "/$OAAR")" --role-session-name fnd3-test \
      --duration-seconds 900 --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text) || creds=""
    read -r ak sk st <<<"$creds" || true
    if [ -z "${st:-}" ]; then
      echo "TC47 assume-role into $label $OAAR failed"
      continue
    fi
    got=$(env -u AWS_PROFILE AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" AWS_SESSION_TOKEN="$st" \
      aws sts get-caller-identity --region "$REGION" --query Account --output text 2>>"$ERRLOG") || got=""
    unset ak sk st creds
    [ "$got" = "$acct" ] || echo "TC47 assumed $OAAR session is not in the $label account"
  done

  # TC48: Offers Platform OAAR trust, boundary, permissions.
  local role
  if ! role=$(awsp "$P_OP_ADMIN" iam get-role --role-name "$OAAR" --output json); then
    echo "TC48 Offers Platform $OAAR not found"
  else
    local bad
    bad=$(printf '%s' "$role" | jqq -r --arg r "arn:aws:iam::$ACCT_MGMT:root" --arg a "$ACCT_MGMT" '
      .Role.AssumeRolePolicyDocument | (if type == "string" then fromjson else . end) | .Statement
      | ([.[] | select(.Effect == "Allow") | .Principal | if type == "object" then . else {Other: .} end
          | to_entries[] | {k: .key, v: (.value | if type == "array" then .[] else . end)}]) as $p
      | if ($p | length) == 0 then "no principal"
        elif ($p | all(.k == "AWS" and (.v == $r or .v == $a))) then empty
        else "trusts more than the management account" end')
    if [ -z "$ACCT_MGMT" ]; then echo "TC48 management account ID unknown"; elif [ -n "$bad" ]; then echo "TC48 Offers Platform $OAAR $bad"; fi
    [ "$(printf '%s' "$role" | jqq -r '.Role.PermissionsBoundary // empty')" = "" ] || echo "TC48 Offers Platform $OAAR has a permissions boundary"
    awsp "$P_OP_ADMIN" iam list-attached-role-policies --role-name "$OAAR" --query 'AttachedPolicies[].PolicyArn' --output text |
      tr '\t' '\n' | grep -qxF "$ADMIN_ACCESS" || echo "TC48 Offers Platform $OAAR does not have AdministratorAccess"
  fi

  # TC49: engineering roles cannot assume the recovery role.
  local profile eng trust
  for label in abc_bank offers_platform; do
    case $label in
      abc_bank) profile=$P_ABC_ADMIN eng=$ROLE_ABC_ENG acct=$ACCT_ABC ;;
      *) profile=$P_OP_ADMIN eng=$ROLE_OP_ENG acct=$ACCT_OP ;;
    esac
    trust=$(awsp "$profile" iam get-role --role-name "$OAAR" --query Role.AssumeRolePolicyDocument --output json | jqq -c 'if type == "string" then fromjson else . end') || trust=""
    if [ -z "$trust" ] || [ -z "$acct" ]; then
      echo "TC49 $label $OAAR trust policy could not be read"
      continue
    fi
    SIM_RESOURCE_POLICY=$trust SIM_RESOURCE_OWNER="arn:aws:iam::$acct:root" SIM_CALLER_ARN="arn:aws:iam::$acct:user/$SIM" \
      expect_sim denied "TC49 $label" principal "$profile" "$eng" "$(role_arn "$acct" "/$OAAR")" \
      "$(ctx_principal "$eng" true)" sts:AssumeRole
  done
}

check_ac11() {
  local readme="$REPO_DIR/README.md" sect
  if [ ! -f "$readme" ]; then
    echo "TC50 README.md missing"
  else
    sect=$(awk 'BEGIN { inside = 0 }
      /^#+ / { if (inside && length($1) <= lvl) exit; if (tolower($0) ~ /recovery/) { inside = 1; lvl = length($1) } }
      inside { print }' "$readme")
    if [ -z "$sect" ]; then
      echo "TC50 README.md has no recovery section"
    else
      printf '%s' "$sect" | grep -qi 'root' || echo "TC50 recovery section does not name the root user"
      printf '%s' "$sect" | grep -q 'MFA' || echo "TC50 recovery section does not mention MFA"
      printf '%s' "$sect" | grep -q "$OAAR" || echo "TC50 recovery section does not name $OAAR"
      printf '%s' "$sect" | grep -q 'ABC Bank' || echo "TC50 recovery section does not cover ABC Bank"
      printf '%s' "$sect" | grep -q 'Offers Platform' || echo "TC50 recovery section does not cover Offers Platform"
    fi
  fi
  echo "@MANUAL README recovery steps present (TC50); the owner signs in as the management root user with MFA and attaches evidence to the PR (TC51)"
}

check_ac12() {
  local svc ce
  svc=$(awsp "$P_MGMT" organizations list-aws-service-access-for-organization --query 'EnabledServicePrincipals[].ServicePrincipal' --output text) || { echo "TC52 list-aws-service-access-for-organization failed"; svc=""; }
  printf '%s' "$svc" | tr '\t' '\n' | grep -qxF cloudtrail.amazonaws.com || echo "TC52 cloudtrail.amazonaws.com trusted access not enabled"
  printf '%s' "$svc" | tr '\t' '\n' | grep -qxF sso.amazonaws.com || echo "TC52 sso.amazonaws.com trusted access not enabled"
  ce=$(awsp "$P_MGMT" ce get-cost-and-usage --time-period "Start=$(days_ago 7),End=$(days_ago 0)" \
    --granularity DAILY --metrics UnblendedCost --output json) || ce=""
  printf '%s' "$ce" | jq -e '.ResultsByTime | type == "array"' >/dev/null 2>&1 || echo "TC53 ce get-cost-and-usage failed in the management account"
}

check_ac13() {
  # TC54
  if [ -z "$CLONE" ]; then
    echo "TC54 fresh clone failed"
  else
    has_root bootstrap || echo "TC54 bootstrap root missing"
    [ -n "$ROOTS" ] || echo "TC54 no Terraform roots in the clone"
    local name
    for name in $ROOTS; do
      [ "$(cat "$WORK/init.$name.rc" 2>/dev/null)" = 0 ] || echo "TC54 $name: terraform init failed"
      if [ "$(cat "$WORK/statelist.$name.rc" 2>/dev/null)" != 0 ]; then
        echo "TC54 $name: terraform state list failed"
      elif [ ! -s "$WORK/state.$name" ]; then
        echo "TC54 $name: terraform state list is empty"
      fi
    done
    # TC55
    local bk
    bk=$(jqq -r 'select(.backend.type == "s3") | .backend.config.key // empty' "$CLONE/bootstrap/.terraform/terraform.tfstate" 2>/dev/null) || bk=""
    if [ -z "$bk" ]; then
      echo "TC55 bootstrap backend is not S3"
    elif [ -n "$STATE_BUCKET" ]; then
      awsp "$P_MGMT" s3api head-object --bucket "$STATE_BUCKET" --key "$bk" >/dev/null || echo "TC55 bootstrap state object not found in the state bucket"
    fi
    [ -z "$(git -C "$CLONE" ls-files '*.tfstate' '*.tfstate.*' '**/*.tfstate' '**/*.tfstate.*' 2>>"$ERRLOG")" ] || echo "TC55 a Terraform state file is tracked in git"
  fi

  if [ -z "$STATE_BUCKET" ]; then
    echo "TC56 state bucket name unknown"
    return 0
  fi
  # TC56
  local v
  v=$(awsp "$P_MGMT" s3api get-bucket-versioning --bucket "$STATE_BUCKET" --query Status --output text) || v=""
  [ "$v" = Enabled ] || echo "TC56 versioning is ${v:-unknown}, not Enabled"
  v=$(awsp "$P_MGMT" s3api get-public-access-block --bucket "$STATE_BUCKET" --output json |
    jqq -r '.PublicAccessBlockConfiguration | [.BlockPublicAcls, .IgnorePublicAcls, .BlockPublicPolicy, .RestrictPublicBuckets] | all(. == true)') || v=""
  [ "$v" = true ] || echo "TC56 public access block is not fully on"
  v=$(awsp "$P_MGMT" s3api get-bucket-policy-status --bucket "$STATE_BUCKET" --query PolicyStatus.IsPublic --output text) || v=""
  [ "$v" = False ] || [ "$v" = false ] || echo "TC56 bucket policy status is not IsPublic=false"
  v=$(awsp "$P_MGMT" s3api get-bucket-encryption --bucket "$STATE_BUCKET" --query 'length(ServerSideEncryptionConfiguration.Rules)' --output text) || v=""
  [ "${v:-0}" -ge 1 ] 2>/dev/null || echo "TC56 no default encryption rule"

  # TC57 static policy check and simulation.
  local barn="arn:aws:s3:::$STATE_BUCKET" obj="arn:aws:s3:::$STATE_BUCKET/${bk:-bootstrap/terraform.tfstate}"
  if [ -z "$BUCKET_POLICY" ]; then
    echo "TC57 bucket policy could not be read"
  else
    v=$(printf '%s' "$BUCKET_POLICY" | jqq -r --arg b "$barn" --arg o "$barn/*" '
      [.Statement[] | select(.Effect == "Deny")
        | select((.Condition.Bool["aws:SecureTransport"] // empty | if type == "array" then .[] else . end | tostring) == "false")
        | (.Resource | if type == "array" then . else [.] end)] | add // []
      | (index($b) != null and index($o) != null)')
    [ "$v" = true ] || echo "TC57 bucket policy has no TLS-only deny on the bucket and its objects"
  fi
  local ctxf ctxt
  if [ -n "$ROLE_MGMT_ADMIN" ]; then
    ctxf=$(ctx_principal "$ROLE_MGMT_ADMIN" false)
    ctxt=$(ctx_principal "$ROLE_MGMT_ADMIN" true)
  fi
  local owner="arn:aws:iam::$ACCT_MGMT:root"
  if [ -z "$BUCKET_POLICY" ] || [ -z "$ACCT_MGMT" ]; then
    echo "TC57 cannot simulate without the bucket policy and the management account ID"
  else
    SIM_RESOURCE_POLICY=$BUCKET_POLICY SIM_RESOURCE_OWNER=$owner SIM_CALLER_ARN="arn:aws:iam::$ACCT_MGMT:user/$SIM" \
      expect_sim denied "TC57 no-TLS" principal "$P_MGMT" "$ROLE_MGMT_ADMIN" "$obj" "${ctxf:-}" s3:GetObject
    # TC59
    SIM_RESOURCE_POLICY=$BUCKET_POLICY SIM_RESOURCE_OWNER=$owner SIM_CALLER_ARN="arn:aws:iam::$ACCT_MGMT:user/$SIM" \
      expect_sim allowed "TC59 management-admin" principal "$P_MGMT" "$ROLE_MGMT_ADMIN" "$obj" "${ctxt:-}" s3:GetObject s3:PutObject
    # TC60, TC61 member-account roles.
    local tag profile role acct
    for tag in "TC60 abc-bank-engineering" "TC60 offers-platform-engineering" "TC61 abc-bank-admin" "TC61 offers-platform-admin"; do
      case $tag in
        *abc-bank-engineering) profile=$P_ABC_ADMIN role=$ROLE_ABC_ENG acct=$ACCT_ABC ;;
        *offers-platform-engineering) profile=$P_OP_ADMIN role=$ROLE_OP_ENG acct=$ACCT_OP ;;
        *abc-bank-admin) profile=$P_ABC_ADMIN role=$ROLE_ABC_ADMIN acct=$ACCT_ABC ;;
        *) profile=$P_OP_ADMIN role=$ROLE_OP_ADMIN acct=$ACCT_OP ;;
      esac
      [ -n "$acct" ] || { echo "$tag account ID unknown"; continue; }
      SIM_RESOURCE_POLICY=$BUCKET_POLICY SIM_RESOURCE_OWNER=$owner SIM_CALLER_ARN="arn:aws:iam::$acct:user/$SIM" \
        expect_sim denied "$tag" principal "$profile" "$role" "$obj" "$(ctx_principal "${role:-none}" true)" s3:GetObject s3:PutObject
    done
    # TC61: another (hypothetical) role in the management account, allow-everything identity.
    SIM_RESOURCE_POLICY=$BUCKET_POLICY SIM_RESOURCE_OWNER=$owner SIM_CALLER_ARN="arn:aws:iam::$ACCT_MGMT:user/$SIM" \
      expect_sim denied "TC61 other-management-role" custom "$P_MGMT" "$ALLOW_ALL" "$obj" \
      "$(ctx_principal "arn:aws:iam::$ACCT_MGMT:role/$SIM" true)" s3:GetObject s3:PutObject
  fi

  # TC58 lock.
  lock_test
}

# Holds the bootstrap state lock with terraform console, then expects a second
# apply to fail with a lock error, releases the lock and checks it is gone.
lock_test() {
  if [ -z "$CLONE" ] || ! has_root bootstrap || [ -z "$STATE_BUCKET" ]; then
    echo "TC58 cannot run: clone, bootstrap root or state bucket missing"
    return 0
  fi
  local key lockkey fifo="$WORK/console.fifo" pid i held=no rc
  key=$(jqq -r '.backend.config.key // empty' "$CLONE/bootstrap/.terraform/terraform.tfstate" 2>/dev/null) || key=""
  [ -n "$key" ] || { echo "TC58 bootstrap backend key unknown"; return 0; }
  lockkey="$key.tflock"
  if awsp "$P_MGMT" s3api head-object --bucket "$STATE_BUCKET" --key "$lockkey" >/dev/null; then
    echo "TC58 a state lock is already held before the test"
    return 0
  fi
  mkfifo "$fifo"
  AWS_PROFILE=$P_MGMT terraform -chdir="$CLONE/bootstrap" console -no-color <"$fifo" >"$WORK/console.log" 2>&1 &
  pid=$!
  echo "$pid" >"$WORK/console.pid"
  exec 3>"$fifo"
  i=0
  while [ $i -lt 30 ]; do
    if awsp "$P_MGMT" s3api head-object --bucket "$STATE_BUCKET" --key "$lockkey" >/dev/null; then held=yes; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
    i=$((i + 1))
  done
  if [ $held = yes ]; then
    # No -auto-approve: even without the lock, -input=false cannot apply.
    rc=0
    AWS_PROFILE=$P_MGMT terraform -chdir="$CLONE/bootstrap" apply -input=false -lock-timeout=0s -no-color $(varfile_args bootstrap) \
      >"$WORK/apply.log" 2>&1 || rc=$?
    if [ $rc -eq 0 ] || ! grep -q 'Error acquiring the state lock' "$WORK/apply.log"; then
      echo "TC58 second apply did not fail with a state-lock error"
    fi
  else
    echo "TC58 terraform console did not hold the state lock"
  fi
  release_console
  rc=0
  AWS_PROFILE=$P_MGMT terraform -chdir="$CLONE/bootstrap" plan -input=false -lock-timeout=0s -no-color -detailed-exitcode $(varfile_args bootstrap) \
    >"$WORK/plan-after-lock.log" 2>&1 || rc=$?
  if grep -q 'Error acquiring the state lock' "$WORK/plan-after-lock.log" ||
    awsp "$P_MGMT" s3api head-object --bucket "$STATE_BUCKET" --key "$lockkey" >/dev/null; then
    echo "TC58 a state lock is left after the test"
    log "WARNING: bootstrap state lock may still be held; check $lockkey in the state bucket"
  elif [ $rc -ne 0 ] && [ $rc -ne 2 ]; then
    echo "TC58 plan after releasing the lock failed"
  fi
}

release_console() {
  exec 3>&- 2>/dev/null || true
  local pid i
  [ -f "$WORK/console.pid" ] || return 0
  pid=$(cat "$WORK/console.pid")
  i=0
  while kill -0 "$pid" 2>/dev/null && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -INT "$pid" 2>/dev/null || true
    sleep 5
    kill -TERM "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  rm -f "$WORK/console.pid"
}

check_ac14() {
  local j label id n
  # State bucket.
  if [ -z "$STATE_BUCKET" ]; then
    echo "TC62 state bucket name unknown"
  else
    j=$(awsp "$P_MGMT" s3api get-bucket-tagging --bucket "$STATE_BUCKET" --query TagSet --output json) || j=""
    tags_eval TC62 state-bucket "$j"
  fi
  # DynamoDB lock table: only if one exists in state.
  local root t
  for root in $ROOTS; do
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      local tn tarn
      tn=$(tf_root "$root" state show -no-color "$t" 2>>"$ERRLOG" | awk -F'"' '/^ *name *=/ { print $2; exit }')
      tarn=$(awsp "$P_MGMT" dynamodb describe-table --table-name "$tn" --query Table.TableArn --output text) || tarn=""
      j=$(awsp "$P_MGMT" dynamodb list-tags-of-resource --resource-arn "$tarn" --query Tags --output json) || j=""
      tags_eval TC62 "lock-table" "$j"
    done < <(grep -E '^(module\.[^.]+\.)*aws_dynamodb_table\.' "$WORK/state.$root" 2>/dev/null || true)
  done
  # Accounts, management included.
  for label in management abc_bank offers_platform; do
    case $label in management) id=$ACCT_MGMT ;; abc_bank) id=$ACCT_ABC ;; *) id=$ACCT_OP ;; esac
    [ -n "$id" ] || { echo "TC62 $label account ID unknown"; continue; }
    j=$(awsp "$P_MGMT" organizations list-tags-for-resource --resource-id "$id" --query Tags --output json) || j=""
    tags_eval TC62 "$label-account" "$j"
  done
  # Identity Center instance and every permission set.
  local n_ps=0
  if [ -z "$SSO_INSTANCE_ARN" ]; then
    echo "TC62 Identity Center instance not found"
  else
    j=$(awsp "$P_MGMT" sso-admin list-tags-for-resource --instance-arn "$SSO_INSTANCE_ARN" --resource-arn "$SSO_INSTANCE_ARN" --query Tags --output json) || j=""
    tags_eval TC62 identity-center-instance "$j"
    local name arn
    while read -r name arn; do
      [ -n "$arn" ] || continue
      n_ps=$((n_ps + 1))
      j=$(awsp "$P_MGMT" sso-admin list-tags-for-resource --instance-arn "$SSO_INSTANCE_ARN" --resource-arn "$arn" --query Tags --output json) || j=""
      tags_eval TC62 "permission-set-$name" "$j"
    done <"$WORK/permission-sets.txt"
  fi
  # Boundary policies.
  if [ -n "$BOUNDARY_ABC" ]; then
    j=$(awsp "$P_ABC_ADMIN" iam list-policy-tags --policy-arn "$BOUNDARY_ABC" --query Tags --output json) || j=""
    tags_eval TC62 abc_bank-boundary "$j"
  else
    echo "TC62 ABC Bank boundary ARN unknown"
  fi
  if [ -n "$BOUNDARY_OP" ]; then
    j=$(awsp "$P_OP_ADMIN" iam list-policy-tags --policy-arn "$BOUNDARY_OP" --query Tags --output json) || j=""
    tags_eval TC62 offers_platform-boundary "$j"
  else
    echo "TC62 Offers Platform boundary ARN unknown"
  fi
  j=$(awsp "$P_OP_ADMIN" iam list-role-tags --role-name "$OAAR" --query Tags --output json) || j=""
  tags_eval TC62 "offers_platform-$OAAR" "$j"

  # Cross-check with terraform state list (both roots).
  if [ -z "$ROOTS" ]; then
    echo "TC62 no Terraform state to cross-check"
    return 0
  fi
  local types checked
  types=$(cat $(for root in $ROOTS; do printf '%s ' "$WORK/state.$root"; done) 2>/dev/null |
    sed -E 's/^(module\.[^.]+\.)*//' | grep -v '^data\.' | cut -d. -f1 | sort | uniq -c) || types=""
  while read -r n t; do
    [ -n "$t" ] || continue
    case $t in
      aws_s3_bucket) checked=1 ;;
      aws_organizations_account) checked=3 ;;
      aws_ssoadmin_permission_set) checked=$n_ps ;;
      aws_iam_policy) checked=2 ;;
      aws_iam_role) checked=1 ;;
      aws_dynamodb_table) checked=$n ;;
      aws_s3_bucket_versioning | aws_s3_bucket_server_side_encryption_configuration | aws_s3_bucket_public_access_block | \
        aws_s3_bucket_ownership_controls | aws_s3_bucket_policy | aws_organizations_organization | aws_identitystore_user | \
        aws_ssoadmin_managed_policy_attachment | aws_ssoadmin_permission_set_inline_policy | aws_ssoadmin_account_assignment | \
        aws_iam_role_policy_attachment | aws_iam_role_policy) checked=$n ;;
      *) checked=0 ;;
    esac
    if [ "$checked" -lt "$n" ] 2>/dev/null; then
      echo "TC62 $t: $n in state, tags checked for $checked (unchecked taggable resource)"
    fi
  done <<<"$types"
}

check_ac15() {
  local v
  if [ -z "$STATE_BUCKET" ]; then
    echo "TC64 state bucket name unknown"
  else
    v=$(awsp "$P_MGMT" s3api get-bucket-encryption --bucket "$STATE_BUCKET" --output json |
      jqq -r '[.ServerSideEncryptionConfiguration.Rules[].ApplyServerSideEncryptionByDefault
        | if .SSEAlgorithm == "AES256" then "ok"
          elif (.SSEAlgorithm | startswith("aws:kms")) and ((.KMSMasterKeyID // "") == "" or ((.KMSMasterKeyID // "") | test("alias/aws/s3$"))) then "ok"
          else "cmk" end] | if length > 0 and all(. == "ok") then "ok" else "bad" end') || v=""
    [ "$v" = ok ] || echo "TC64 state bucket encryption is not SSE-S3 or the AWS-managed key"
  fi
  local root hits
  for root in $ROOTS; do
    hits=$(sed -E 's/^(module\.[^.]+\.)*//' "$WORK/state.$root" 2>/dev/null | cut -d. -f1 |
      grep -xE 'aws_kms_key|aws_nat_gateway|aws_instance|aws_db_instance|aws_rds_cluster|aws_rds_cluster_instance|aws_lb|aws_alb|aws_elb|aws_vpc_endpoint|aws_ec2_instance_connect_endpoint|aws_eip|aws_dms_replication_instance|aws_elasticache_cluster|aws_redshift_cluster|aws_directory_service_directory|aws_ec2_client_vpn_endpoint|aws_networkfirewall_firewall' |
      sort -u | tr '\n' ' ') || hits=""
    [ -z "$hits" ] || echo "TC64 $root state has a customer-managed key or hourly-billed resource: $hits"
  done
  echo "@MANUAL check the PR states the expected monthly cost, under \$0.50 (TC64); bucket encryption and state checked"
}

check_ac16() {
  if [ -z "$CLONE" ] || [ -z "$ROOTS" ]; then
    echo "TC65 no Terraform roots in the clone"
  fi
  local name rc
  for name in $ROOTS; do
    rc=0
    tf_root "$name" plan -detailed-exitcode -input=false -no-color -lock-timeout=60s $(varfile_args "$name") \
      >"$WORK/plan.$name.log" 2>&1 || rc=$?
    case $rc in
      0) ;;
      2) echo "TC65 $name: plan shows changes" ;;
      *) echo "TC65 $name: plan failed (exit $rc)" ;;
    esac
    rc=0
    tf_root "$name" validate -no-color >>"$ERRLOG" 2>&1 || rc=$?
    [ $rc -eq 0 ] || echo "TC66 $name: terraform validate failed"
  done
  if [ -n "$CLONE" ]; then
    rc=0
    terraform -chdir="$CLONE" fmt -check -recursive >>"$ERRLOG" 2>&1 || rc=$?
    [ $rc -eq 0 ] || echo "TC66 terraform fmt -check -recursive failed"
    # make targets in a second fresh clone, so they do not reuse the backend init.
    local mk="$WORK/clone-make"
    if git clone --quiet "$CLONE" "$mk" >>"$ERRLOG" 2>&1; then
      if [ ! -f "$mk/Makefile" ]; then
        echo "TC66 Makefile missing"
      else
        grep -qE '^test:' "$mk/Makefile" || echo "TC66 Makefile has no test target"
        grep -qE '^lint:' "$mk/Makefile" || echo "TC66 Makefile has no lint target"
        rc=0
        make -C "$mk" test >>"$ERRLOG" 2>&1 || rc=$?
        [ $rc -eq 0 ] || echo "TC66 make test failed"
        rc=0
        make -C "$mk" lint >>"$ERRLOG" 2>&1 || rc=$?
        [ $rc -eq 0 ] || echo "TC66 make lint failed"
      fi
    else
      echo "TC66 second clone for make failed"
    fi
  else
    echo "TC66 fresh clone failed"
  fi
}

# ---------------------------------------------------------------- regressions

check_reg67() {
  local f
  for f in users.json access-keys.json; do
    baseline_ok "$f" || { echo "baseline missing or unreadable ($f)"; return 0; }
  done
  local live_users base_users missing extra
  live_users=$(awsp "$P_OP_ADMIN" iam list-users --query 'Users[].UserName' --output json | jqq -r '.[]' | LC_ALL=C sort -u) ||
    { echo "Offers Platform list-users failed"; return 0; }
  base_users=$(jqq -r '[.. | objects | select(has("UserName") and (has("AccessKeyId") | not)) | .UserName] | unique | .[]' "$BASELINE_DIR/users.json" | LC_ALL=C sort -u)
  missing=$(comm -23 <(printf '%s\n' "$base_users" | sed '/^$/d') <(printf '%s\n' "$live_users" | sed '/^$/d') | wc -l | tr -d ' ')
  extra=$(comm -13 <(printf '%s\n' "$base_users" | sed '/^$/d') <(printf '%s\n' "$live_users" | sed '/^$/d') | wc -l | tr -d ' ')
  [ "$missing" = 0 ] || echo "$missing baseline user(s) no longer exist"
  [ "$extra" = 0 ] || echo "$extra user(s) not in the baseline"

  local live_keys="" u k
  for u in $live_users; do
    k=$(awsp "$P_OP_ADMIN" iam list-access-keys --user-name "$u" --output json |
      jqq -r '.AccessKeyMetadata[] | "\(.UserName) \(.AccessKeyId) \(.Status)"') || { echo "list-access-keys failed for a user"; return 0; }
    live_keys="$live_keys$k
"
  done
  local base_keys gone=0 deact=0 newk=0 bu bk bs ls
  base_keys=$(jqq -r '[.. | objects | select(has("AccessKeyId"))] | unique_by(.AccessKeyId) | .[] | "\(.UserName) \(.AccessKeyId) \(.Status)"' "$BASELINE_DIR/access-keys.json")
  while read -r bu bk bs; do
    [ -n "$bk" ] || continue
    ls=$(printf '%s\n' "$live_keys" | awk -v u="$bu" -v k="$bk" '$1 == u && $2 == k { print $3; exit }')
    if [ -z "$ls" ]; then
      gone=$((gone + 1))
    elif [ "$bs" = Active ] && [ "$ls" != Active ]; then
      deact=$((deact + 1))
    fi
  done <<<"$base_keys"
  while read -r bu bk bs; do
    [ -n "$bk" ] || continue
    printf '%s\n' "$base_keys" | awk -v k="$bk" '$2 == k { f = 1 } END { exit !f }' || newk=$((newk + 1))
  done <<<"$live_keys"
  [ $gone = 0 ] || echo "$gone baseline key(s) deleted"
  [ $deact = 0 ] || echo "$deact key(s) that were Active are no longer Active"
  [ $newk = 0 ] || echo "$newk key(s) not in the baseline"
}

check_reg68() {
  baseline_ok roles.json || { echo "baseline missing or unreadable (roles.json)"; return 0; }
  local entries
  entries=$(baseline_roles) || { echo "baseline roles.json could not be parsed"; return 0; }
  [ -n "$entries" ] || { echo "baseline roles.json lists no roles"; return 0; }
  local e name live trust attached names inline pn doc
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    name=$(printf '%s' "$e" | jqq -r '.name // empty')
    [ -n "$name" ] || { echo "baseline role entry without RoleName"; continue; }
    [ "$(printf '%s' "$e" | jqq -r '.has_policy_data')" = true ] || echo "role $name: baseline entry has no attached-policy data"
    if ! live=$(awsp "$P_OP_ADMIN" iam get-role --role-name "$name" --output json); then
      echo "role $name: no longer exists"
      continue
    fi
    [ "$(printf '%s' "$live" | jqq -r '.Role.PermissionsBoundary // empty')" = "" ] || echo "role $name: permissions boundary attached"
    [ "$(printf '%s' "$live" | jqq -r '.Role.Path')" = "$(printf '%s' "$e" | jqq -r '.path')" ] || echo "role $name: path changed"
    trust=$(printf '%s' "$live" | jqq -S -c '.Role.AssumeRolePolicyDocument | if type == "string" then fromjson else . end')
    [ "$trust" = "$(printf '%s' "$e" | jqq -S -c '.trust')" ] || echo "role $name: trust policy changed"
    attached=$(awsp "$P_OP_ADMIN" iam list-attached-role-policies --role-name "$name" --output json | jqq -c '[.AttachedPolicies[].PolicyArn] | sort') || attached="error"
    [ "$attached" = "$(printf '%s' "$e" | jqq -c '.attached')" ] || echo "role $name: attached policies changed"
    names=$(awsp "$P_OP_ADMIN" iam list-role-policies --role-name "$name" --output json | jqq -c '.PolicyNames | sort') || names="error"
    [ "$names" = "$(printf '%s' "$e" | jqq -c '.inline_names')" ] || { echo "role $name: inline policy names changed"; continue; }
    for pn in $(printf '%s' "$names" | jqq -r '.[]'); do
      doc=$(awsp "$P_OP_ADMIN" iam get-role-policy --role-name "$name" --policy-name "$pn" --query PolicyDocument --output json |
        jqq -S -c 'if type == "string" then fromjson else . end') || doc="error"
      inline=$(printf '%s' "$e" | jqq -S -c --arg p "$pn" '.inline[$p] // "absent"')
      [ "$inline" != '"absent"' ] || { echo "role $name: baseline has no document for inline policy $pn"; continue; }
      [ "$doc" = "$inline" ] || echo "role $name: inline policy $pn changed"
    done
  done <<<"$entries"
}

# ---------------------------------------------------------------- PR evidence (no result line)

pr_evidence() {
  log "---- PR evidence (TC70, TC71; not counted in the result) ----"
  local v id
  v=$(awsp "$P_MGMT" organizations list-policies --filter SERVICE_CONTROL_POLICY --query 'Policies[].Name' --output text) || v="(call failed)"
  log "EVIDENCE TC70 SCPs: $v"
  local rootid
  rootid=$(awsp "$P_MGMT" organizations list-roots --query 'Roots[0].Id' --output text) || rootid=""
  if [ -n "$rootid" ] && [ "$rootid" != None ]; then
    v=$(awsp "$P_MGMT" organizations list-policies-for-target --target-id "$rootid" --filter SERVICE_CONTROL_POLICY --query 'Policies[].Name' --output text) || v="(call failed)"
    log "EVIDENCE TC70 SCPs on the root: $v"
    v=$(awsp "$P_MGMT" organizations list-organizational-units-for-parent --parent-id "$rootid" --query 'length(OrganizationalUnits)' --output text) || v="(call failed)"
    log "EVIDENCE TC70 OUs under the root: $v"
  fi
  local label
  for label in management abc_bank offers_platform; do
    case $label in management) id=$ACCT_MGMT ;; abc_bank) id=$ACCT_ABC ;; *) id=$ACCT_OP ;; esac
    [ -n "$id" ] || continue
    v=$(awsp "$P_MGMT" organizations list-policies-for-target --target-id "$id" --filter SERVICE_CONTROL_POLICY --query 'Policies[].Name' --output text) || v="(call failed)"
    log "EVIDENCE TC70 SCPs on $label: $v"
  done
  if [ -n "$CLONE" ]; then
    v=$(git -C "$CLONE" ls-files | grep -E '\.tfvars$' | grep -vE '(^|/)example\.tfvars$' || true)
    log "EVIDENCE TC71 tracked .tfvars other than example.tfvars: ${v:-none}"
    v=$(git -C "$CLONE" ls-files | grep -E '\.tfstate(\.|$)|(^|/)credentials$|\.pem$|(^|/)\.env$' || true)
    log "EVIDENCE TC71 tracked state or credential files: ${v:-none}"
    v=$(git -C "$CLONE" grep -nE 'AKIA[0-9A-Z]{16}|aws_secret_access_key' -- . ':!tests/' 2>/dev/null | cut -d: -f1,2 || true)
    log "EVIDENCE TC71 key-like strings (file:line): ${v:-none}"
    v=$(git -C "$CLONE" grep -nE '(^|[^0-9])[0-9]{12}([^0-9]|$)' -- '*.tf' 2>/dev/null | grep -vE '^[^:]*variables\.tf:' | cut -d: -f1,2 || true)
    log "EVIDENCE TC71 12-digit numbers in .tf outside variables.tf (file:line): ${v:-none}"
    v=$(git -C "$CLONE" grep -nE 'source *= *"hashicorp/aws"' -A2 -- '*.tf' 2>/dev/null | grep -E 'version' | sed 's/^/  /' || true)
    log "EVIDENCE TC71 aws provider version constraints: ${v:-none found}"
    v=$(git -C "$CLONE" grep -nE 'region *= *"' -- '*.tf' 2>/dev/null | grep -v 'us-east-1' | cut -d: -f1,2 || true)
    log "EVIDENCE TC71 region settings other than us-east-1 (file:line): ${v:-none}"
  fi
  log "EVIDENCE TC69 MANUAL: owner runs aws sts get-caller-identity and an aws s3 ls with an existing v1/v2 laptop profile"
  log "---- end PR evidence ----"
}

# ---------------------------------------------------------------- driver

emit() {
  printf '%s %s %s\n' "$1" "$2" "$3"
  [ "$1" != FAIL ] || ANY_FAIL=1
}

# run_check ID FUNCTION PASS_TEXT
run_check() {
  local id=$1 fn=$2 pass_text=$3 out rc=0 reasons manual
  out=$("$fn") || rc=$?
  reasons=$(printf '%s\n' "$out" | grep -v '^@MANUAL ' | sed '/^$/d' | awk 'BEGIN { ORS = "" } { if (NR > 1) print "; "; print }' || true)
  manual=$(printf '%s\n' "$out" | sed -n 's/^@MANUAL //p' | head -n 1)
  if [ -n "$reasons" ]; then
    emit FAIL "$id" "$reasons"
  elif [ $rc -ne 0 ]; then
    emit FAIL "$id" "check aborted (exit $rc)"
  elif [ -n "$manual" ]; then
    emit MANUAL "$id" "$manual"
  else
    emit PASS "$id" "$pass_text"
  fi
}

cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    release_console 2>/dev/null || true
    rm -rf "$WORK"
  fi
}

main() {
  local missing="" tool id
  for tool in aws jq git terraform; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    for id in $AC_IDS $REG_IDS; do emit FAIL "$id" "required tool(s) missing:$missing"; done
    exit 1
  fi

  WORK=$(mktemp -d "${FND3_TMPDIR:-${TMPDIR:-/tmp}}/fnd3.XXXXXX")
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  if [ "${FND3_DEBUG:-0}" = 1 ]; then ERRLOG=/dev/stderr; else ERRLOG="$WORK/errors.log"; fi

  discover || true

  run_check AC1 check_ac1 "organization has all features; the management profile's account is the management account"
  run_check AC2 check_ac2 "exactly the three expected accounts, all ACTIVE; Offers Platform invited and accepted"
  run_check AC3 check_ac3 ""
  run_check AC4 check_ac4 "all five SSO profiles reach the expected account and permission set; assignments as designed"
  run_check AC5 check_ac5 "ABC Bank engineering allowed actions hold; Cost Explorer call succeeded"
  run_check AC6 check_ac6 "ABC Bank engineering denied actions hold"
  run_check AC7 check_ac7 "Offers Platform engineering allowed and denied actions hold"
  run_check AC7b check_ac7b "boundary exists in both member accounts and denies as required"
  run_check AC8 check_ac8 ""
  run_check AC9 check_ac9 "no IAM users or active keys (management, ABC Bank); root MFA and no root keys in all three"
  run_check AC10 check_ac10 "OrganizationAccountAccessRole assumable from management into both member accounts; engineering roles cannot"
  run_check AC11 check_ac11 ""
  run_check AC12 check_ac12 "CloudTrail trusted access enabled; Cost Explorer works in management"
  run_check AC13 check_ac13 "state bucket: fresh-clone init, versioning, public block, encryption, TLS-only, locking, access"
  run_check AC14 check_ac14 "four cost tags on every taggable resource"
  run_check AC15 check_ac15 ""
  run_check AC16 check_ac16 "no plan changes; fmt, validate, make test and make lint pass"
  run_check REG-TC67 check_reg67 "Offers Platform users and access keys unchanged from the baseline"
  run_check REG-TC68 check_reg68 "Offers Platform v1/v2 roles unchanged from the baseline"

  pr_evidence || true

  [ "$ANY_FAIL" = 0 ] || exit 1
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
