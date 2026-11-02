#!/usr/bin/env bash
# FND-3 self-test: checks the logic of tests/FND-3.sh with stubbed responses.
# Needs no AWS credentials and makes no AWS calls: the check functions are
# sourced and fed canned JSON (TC04, TC07, TC63), and the whole script is run
# with stub `aws` and `terraform` commands first on PATH (TC72).
#
# Prints one PASS or FAIL line per self-test case; exits 1 if any FAIL.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/FND-3.sh"

# shellcheck source=FND-3.sh
. "$SCRIPT"

ST_FAIL=0
ST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fnd3-selftest.XXXXXX")
trap 'rm -rf "$ST_TMP"' EXIT

ok() { printf 'PASS %s %s\n' "$1" "$2"; }
ko() {
  printf 'FAIL %s %s\n' "$1" "$2"
  ST_FAIL=1
}

# Fake 12-digit account IDs, built at run time (no literals).
fake_id() { printf '%012d' "$1"; }
M=$(fake_id 1)
A=$(fake_id 2)
O=$(fake_id 3)

# expect_problems CASE DESC FUNC ARGS...: FUNC must print at least one problem.
expect_problems() {
  local case=$1 desc=$2 out
  shift 2
  out=$("$@")
  if [ -n "$out" ]; then ok "$case" "$desc -> $(printf '%s' "$out" | head -n 1)"; else ko "$case" "$desc: no problem reported"; fi
}

# expect_clean CASE DESC FUNC ARGS...: FUNC must print nothing (control case).
expect_clean() {
  local case=$1 desc=$2 out
  shift 2
  out=$("$@")
  if [ -z "$out" ]; then ok "$case" "$desc (control)"; else ko "$case" "$desc: unexpected problem: $out"; fi
}

org_json() { printf '{"Organization":{"Id":"o-fake","FeatureSet":"%s","MasterAccountId":"%s"}}' "$1" "$2"; }

# account ID STATE JOINED
acct() { printf '{"Id":"%s","State":"%s","JoinedMethod":"%s"}' "$1" "$2" "$3"; }
accounts_json() {
  local IFS=,
  printf '{"Accounts":[%s]}' "$*"
}

# ------------------------------------------------------------ TC04 (AC1 logic)
expect_clean TC04 "FeatureSet ALL, caller is management" ac1_eval "$(org_json ALL "$M")" "$M" "$M"
expect_problems TC04 "FeatureSet CONSOLIDATED_BILLING" ac1_eval "$(org_json CONSOLIDATED_BILLING "$M")" "$M" "$M"
expect_problems TC04 "caller is not the management account" ac1_eval "$(org_json ALL "$M")" "$A" "$M"
expect_problems TC04 "Terraform output differs" ac1_eval "$(org_json ALL "$M")" "$M" "$A"
expect_problems TC04 "empty response" ac1_eval '{}' "$M" "$M"

# ------------------------------------------------------------ TC07 (AC2 logic)
GOOD3=$(accounts_json "$(acct "$M" ACTIVE CREATED)" "$(acct "$A" ACTIVE CREATED)" "$(acct "$O" ACTIVE INVITED)")
expect_clean TC07 "three ACTIVE accounts" ac2_eval "$GOOD3" "$M" "$A" "$O"
expect_clean TC07 "legacy Status field ACTIVE" ac2_eval \
  "$(printf '{"Accounts":[{"Id":"%s","Status":"ACTIVE","JoinedMethod":"CREATED"},{"Id":"%s","Status":"ACTIVE","JoinedMethod":"CREATED"},{"Id":"%s","Status":"ACTIVE","JoinedMethod":"INVITED"}]}' "$M" "$A" "$O")" "$M" "$A" "$O"
expect_problems TC07 "two accounts" ac2_eval \
  "$(accounts_json "$(acct "$M" ACTIVE CREATED)" "$(acct "$A" ACTIVE CREATED)")" "$M" "$A" "$O"
expect_problems TC07 "four accounts" ac2_eval \
  "$(accounts_json "$(acct "$M" ACTIVE CREATED)" "$(acct "$A" ACTIVE CREATED)" "$(acct "$O" ACTIVE INVITED)" "$(acct "$(fake_id 4)" ACTIVE CREATED)")" "$M" "$A" "$O"
expect_problems TC07 "three accounts, one SUSPENDED" ac2_eval \
  "$(accounts_json "$(acct "$M" ACTIVE CREATED)" "$(acct "$A" SUSPENDED CREATED)" "$(acct "$O" ACTIVE INVITED)")" "$M" "$A" "$O"
expect_problems TC07 "three accounts, one PENDING_CLOSURE" ac2_eval \
  "$(accounts_json "$(acct "$M" ACTIVE CREATED)" "$(acct "$A" ACTIVE CREATED)" "$(acct "$O" PENDING_CLOSURE INVITED)")" "$M" "$A" "$O"
expect_problems TC07 "three accounts, an unexpected one instead of ABC Bank" ac2_eval \
  "$(accounts_json "$(acct "$M" ACTIVE CREATED)" "$(acct "$(fake_id 5)" ACTIVE CREATED)" "$(acct "$O" ACTIVE INVITED)")" "$M" "$A" "$O"
expect_problems TC07 "Offers Platform created, not invited" ac2_eval \
  "$(accounts_json "$(acct "$M" ACTIVE CREATED)" "$(acct "$A" ACTIVE CREATED)" "$(acct "$O" ACTIVE CREATED)")" "$M" "$A" "$O"

# ------------------------------------------------------------ TC63 (AC14 logic)
GOOD_TAGS='[{"Key":"data-product","Value":"aws-foundations"},{"Key":"environment","Value":"shared"},{"Key":"owner","Value":"Lakshmi100"},{"Key":"cost-center","Value":"offers-platform-portfolio"}]'
expect_clean TC63 "four correct tags" tags_eval TC62 r "$GOOD_TAGS"
expect_clean TC63 "four correct tags plus an extra tag" tags_eval TC62 r \
  "$(printf '%s' "$GOOD_TAGS" | jq -c '. + [{"Key":"Name","Value":"x"}]')"
expect_problems TC63 "one tag missing" tags_eval TC62 r \
  "$(printf '%s' "$GOOD_TAGS" | jq -c 'map(select(.Key != "cost-center"))')"
expect_problems TC63 "wrong value environment=prod" tags_eval TC62 r \
  "$(printf '%s' "$GOOD_TAGS" | jq -c 'map(if .Key == "environment" then .Value = "prod" else . end)')"
expect_problems TC63 "key with different case Owner" tags_eval TC62 r \
  "$(printf '%s' "$GOOD_TAGS" | jq -c 'map(if .Key == "owner" then .Key = "Owner" else . end)')"
expect_problems TC63 "no tags at all" tags_eval TC62 r '[]'
expect_problems TC63 "tag call failed" tags_eval TC62 r ''

# ------------------------------------------------------------ AC lines through the real check functions
# awsp is replaced by a stub that answers from canned JSON, so check_ac1,
# check_ac2 and check_ac14 run unchanged and run_check prints the AC line.
WORK="$ST_TMP/work"
mkdir -p "$WORK"
ERRLOG=/dev/null
printf '{"management_account_id":{"value":"%s"},"abc_bank_account_id":{"value":"%s"},"offers_platform_account_id":{"value":"%s"}}' \
  "$M" "$A" "$O" >"$WORK/tfout.organization.json"
ACCT_MGMT=$M ACCT_ABC=$A ACCT_OP=$O
STUB_ORG=$(org_json ALL "$M")
STUB_ACCOUNTS=$GOOD3
STUB_HS=$(printf '{"Handshakes":[{"Action":"INVITE","State":"ACCEPTED","Parties":[{"Type":"ACCOUNT","Id":"%s"},{"Type":"ORGANIZATION","Id":"o-fake"}]}]}' "$O")
STUB_TAGS=$GOOD_TAGS
STUB_BAD_TAGS_ON=""

awsp() {
  local p=$1 acct=""
  shift
  case "$1 $2" in
    "organizations describe-organization") printf '%s' "$STUB_ORG" ;;
    "sts get-caller-identity")
      case $p in "$P_MGMT") acct=$M ;; "$P_ABC_ADMIN") acct=$A ;; "$P_OP_ADMIN") acct=$O ;; esac
      printf '{"Account":"%s","Arn":"stub"}' "$acct"
      ;;
    "organizations list-accounts") printf '%s' "$STUB_ACCOUNTS" ;;
    "organizations list-handshakes-for-organization") printf '%s' "$STUB_HS" ;;
    "organizations list-tags-for-resource" | "s3api get-bucket-tagging" | "sso-admin list-tags-for-resource" | \
      "iam list-policy-tags" | "iam list-role-tags")
      if [ -n "$STUB_BAD_TAGS_ON" ] && [ "$1 $2" = "$STUB_BAD_TAGS_ON" ]; then
        printf '%s' "$GOOD_TAGS" | jq -c 'map(if .Key == "owner" then .Key = "Owner" else . end)'
      else
        printf '%s' "$STUB_TAGS"
      fi
      ;;
    *) return 1 ;;
  esac
}

# expect_line CASE DESC WANT_STATUS ID FUNC
expect_line() {
  local case=$1 desc=$2 want=$3 id=$4 fn=$5 line
  ANY_FAIL=0
  line=$(run_check "$id" "$fn" "ok")
  case "$line" in
    "$want $id "*) ok "$case" "$desc -> $(printf '%s' "$line" | cut -c1-120)" ;;
    *) ko "$case" "$desc: got '$line'" ;;
  esac
}

expect_line TC04 "AC1 line with a good stub" PASS AC1 check_ac1
STUB_ORG=$(org_json CONSOLIDATED_BILLING "$M")
expect_line TC04 "AC1 line, FeatureSet CONSOLIDATED_BILLING" FAIL AC1 check_ac1
STUB_ORG=$(org_json ALL "$A")
expect_line TC04 "AC1 line, caller is not the management account" FAIL AC1 check_ac1
STUB_ORG=$(org_json ALL "$M")

expect_line TC07 "AC2 line with a good stub" PASS AC2 check_ac2
STUB_ACCOUNTS=$(accounts_json "$(acct "$M" ACTIVE CREATED)" "$(acct "$A" ACTIVE CREATED)")
expect_line TC07 "AC2 line, two accounts" FAIL AC2 check_ac2
STUB_ACCOUNTS=$(accounts_json "$(acct "$M" ACTIVE CREATED)" "$(acct "$A" ACTIVE CREATED)" "$(acct "$O" ACTIVE INVITED)" "$(acct "$(fake_id 4)" ACTIVE CREATED)")
expect_line TC07 "AC2 line, four accounts" FAIL AC2 check_ac2
STUB_ACCOUNTS=$(accounts_json "$(acct "$M" ACTIVE CREATED)" "$(acct "$A" SUSPENDED CREATED)" "$(acct "$O" ACTIVE INVITED)")
expect_line TC07 "AC2 line, one SUSPENDED" FAIL AC2 check_ac2
STUB_ACCOUNTS=$(accounts_json "$(acct "$M" ACTIVE CREATED)" "$(acct "$A" ACTIVE CREATED)" "$(acct "$O" PENDING_CLOSURE INVITED)")
expect_line TC07 "AC2 line, one PENDING_CLOSURE" FAIL AC2 check_ac2
STUB_ACCOUNTS=$GOOD3

SSO_INSTANCE_ARN=stub-instance
STATE_BUCKET=stub-bucket
BOUNDARY_ABC=stub-boundary-abc
BOUNDARY_OP=stub-boundary-op
printf 'Administrator ps-1\nABCBankEngineering ps-2\nOffersPlatformEngineering ps-3\n' >"$WORK/permission-sets.txt"
ROOTS="bootstrap organization"
printf 'aws_s3_bucket.state\naws_s3_bucket_versioning.state\ndata.aws_caller_identity.current\n' >"$WORK/state.bootstrap"
printf '%s\n' 'aws_organizations_organization.this' 'aws_organizations_account.management' 'aws_organizations_account.abc_bank' \
  'aws_organizations_account.offers_platform' 'aws_ssoadmin_permission_set.this["Administrator"]' \
  'aws_ssoadmin_permission_set.this["ABCBankEngineering"]' 'aws_ssoadmin_permission_set.this["OffersPlatformEngineering"]' \
  'aws_iam_policy.boundary_abc_bank' 'aws_iam_policy.boundary_offers_platform' 'aws_iam_role.offers_platform_oaar' \
  'aws_ssoadmin_account_assignment.admin["management"]' >"$WORK/state.organization"

expect_line TC63 "AC14 line with all tags correct" PASS AC14 check_ac14
for call in "s3api get-bucket-tagging" "organizations list-tags-for-resource" "sso-admin list-tags-for-resource" "iam list-policy-tags" "iam list-role-tags"; do
  STUB_BAD_TAGS_ON=$call
  expect_line TC63 "AC14 line, Owner key case on $call" FAIL AC14 check_ac14
done
STUB_BAD_TAGS_ON=""
STUB_TAGS=$(printf '%s' "$GOOD_TAGS" | jq -c 'map(select(.Key != "data-product"))')
expect_line TC63 "AC14 line, one tag missing everywhere" FAIL AC14 check_ac14
STUB_TAGS=$(printf '%s' "$GOOD_TAGS" | jq -c 'map(if .Key == "environment" then .Value = "prod" else . end)')
expect_line TC63 "AC14 line, environment=prod" FAIL AC14 check_ac14
STUB_TAGS=$GOOD_TAGS
printf 'aws_kms_alias.x\n' >>"$WORK/state.organization"
expect_line TC63 "AC14 line, unchecked resource type in state" FAIL AC14 check_ac14

# ------------------------------------------------------------ TC72 (whole script, stub commands)
STUB_BIN="$ST_TMP/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/aws" <<'EOF'
#!/usr/bin/env bash
# Stub aws: the profile named in FND3_STUB_MISSING does not exist; every other
# call "succeeds" with an empty JSON object.
for a in "$@"; do
  if [ "$a" = "$FND3_STUB_MISSING" ]; then
    echo "The config profile ($a) could not be found" >&2
    exit 255
  fi
done
if [ "${1:-}" = configure ] && [ "${2:-}" = list-profiles ]; then
  for p in fnd-management-admin fnd-abc-bank-admin fnd-offers-platform-admin fnd-abc-bank-engineering fnd-offers-platform-engineering; do
    [ "$p" = "$FND3_STUB_MISSING" ] || echo "$p"
  done
  exit 0
fi
if [ "${1:-}" = configure ]; then exit 1; fi
echo '{}'
EOF
cat >"$STUB_BIN/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform stub: $*" >&2
exit 1
EOF
chmod +x "$STUB_BIN/aws" "$STUB_BIN/terraform"

EXPECTED_IDS="AC1 AC2 AC3 AC4 AC5 AC6 AC7 AC7b AC8 AC9 AC10 AC11 AC12 AC13 AC14 AC15 AC16 REG-TC67 REG-TC68"

# run_stubbed CASE DESC BASELINE_DIR
run_stubbed() {
  local case=$1 desc=$2 base=$3 tmp="$ST_TMP/run.$RANDOM" out rc=0 ids bad
  mkdir -p "$tmp"
  out=$(PATH="$STUB_BIN:$PATH" FND3_STUB_MISSING=fnd-abc-bank-engineering FND3_TMPDIR="$tmp" \
    FND3_BASELINE_DIR="$base" bash "$SCRIPT" 2>/dev/null) || rc=$?
  ids=$(printf '%s\n' "$out" | awk '{ print $2 }' | tr '\n' ' ' | sed 's/ $//')
  bad=$(printf '%s\n' "$out" | grep -cvE '^(PASS|FAIL|MANUAL) (AC[0-9]+b?|REG-TC6[78]) ' || true)
  [ "$rc" = 1 ] && ok "$case" "$desc: exit 1" || ko "$case" "$desc: exit $rc, expected 1"
  [ "$ids" = "$EXPECTED_IDS" ] && ok "$case" "$desc: 17 AC lines in order, then REG-TC67, REG-TC68" ||
    ko "$case" "$desc: line IDs were '$ids'"
  [ "$bad" = 0 ] && ok "$case" "$desc: no other lines on stdout" || ko "$case" "$desc: $bad stray stdout line(s)"
  [ "$(printf '%s\n' "$out" | grep -cE '^(PASS|FAIL|MANUAL) AC')" = 17 ] && ok "$case" "$desc: exactly 17 AC lines" ||
    ko "$case" "$desc: AC line count wrong"
  printf '%s\n' "$out" | grep -qE '^FAIL AC4 .*fnd-abc-bank-engineering' && ok "$case" "$desc: missing profile marks AC4 FAIL" ||
    ko "$case" "$desc: AC4 does not name the missing profile"
  printf '%s\n' "$out" | grep -qE '^(PASS|FAIL) REG-TC67 ' && printf '%s\n' "$out" | grep -qE '^(PASS|FAIL) REG-TC68 ' &&
    ok "$case" "$desc: REG lines are PASS or FAIL" || ko "$case" "$desc: REG lines not PASS/FAIL"
  [ -z "$(ls -A "$tmp")" ] && ok "$case" "$desc: scratch directory removed (no clone, no lock holder left)" ||
    ko "$case" "$desc: left behind: $(ls -A "$tmp" | tr '\n' ' ')"
  RUN_OUT=$out
}

grep -qx 'set -euo pipefail' "$SCRIPT" && ok TC72 "script uses set -euo pipefail" || ko TC72 "set -euo pipefail missing"

FAKE_BASE="$ST_TMP/baseline"
mkdir -p "$FAKE_BASE"
printf '{"Users":[{"UserName":"u1"}]}' >"$FAKE_BASE/users.json"
printf '[{"AccessKeyMetadata":[{"UserName":"u1","AccessKeyId":"k1","Status":"Active"}]}]' >"$FAKE_BASE/access-keys.json"
printf '[{"Role":{"RoleName":"r1","Path":"/","AssumeRolePolicyDocument":{}},"AttachedPolicies":[],"PolicyNames":[],"RolePolicies":[]}]' >"$FAKE_BASE/roles.json"
RUN_OUT=""
run_stubbed TC72 "one profile missing" "$FAKE_BASE"

EMPTY_BASE="$ST_TMP/empty-baseline"
mkdir -p "$EMPTY_BASE"
run_stubbed TC72 "baseline directory empty" "$EMPTY_BASE"
printf '%s\n' "$RUN_OUT" | grep -qE '^FAIL REG-TC67 .*baseline missing' && printf '%s\n' "$RUN_OUT" | grep -qE '^FAIL REG-TC68 .*baseline missing' &&
  ok TC72 "empty baseline: REG-TC67 and REG-TC68 FAIL with baseline missing" ||
  ko TC72 "empty baseline: REG lines did not FAIL with baseline missing"

[ "$ST_FAIL" = 0 ] || exit 1
exit 0
