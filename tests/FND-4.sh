#!/usr/bin/env bash
# FND-4 acceptance checks: cost and audit guardrails for the organization.
#
# Runs against the real accounts and only reads state, with the exceptions the
# test plan names:
#   - AC7 creates one empty S3 bucket fnd4-audit-test-<random> in ABC Bank
#     (us-east-1, cost tags) and deletes it straight away; a trap deletes it on
#     any exit. It is created only when an organization trail exists and is
#     logging; otherwise AC7 fails without creating anything.
#   - TC30 makes read-only s3api list-buckets calls from the three admin
#     profiles, so read events exist to find in the trail bucket.
#   - TC44 calls a no-op cloudtrail update-trail from ABC Bank (it sets log
#     file validation, which must already be on; the call must be refused).
#     It is skipped, and the line fails, if validation is not on today.
#   - AC2 plans posture=working (never applied); the scratch plan file is
#     deleted. No test calls stop-logging or delete-trail.
#
# Output (stdout): exactly one line per acceptance criterion, AC1..AC14 in
# order, then REG-TC68..REG-TC72:
#     PASS|FAIL|MANUAL <ID> <text>
# A FAIL lists the failed sub-checks (test plan case IDs). Exit 1 if any line
# is FAIL. Diagnostics and PR evidence go to stderr. Raw AWS and Terraform
# errors go to a scratch log that is deleted on exit (FND4_DEBUG=1 prints it,
# redacted, to stderr first). Everything printed is passed through a filter
# that masks e-mail addresses and 12-digit numbers (account IDs).
#
# Inputs (environment):
#   FND_MANAGEMENT_ADMIN       default fnd-management-admin
#   FND_ABC_BANK_ADMIN         default fnd-abc-bank-admin
#   FND_OFFERS_PLATFORM_ADMIN  default fnd-offers-platform-admin
#   FND_ABC_BANK_ENGINEERING   default fnd-abc-bank-engineering (REG-TC69)
#   FND4_ALERT_EMAIL     the engineer's alert e-mail; default: alert_email in
#                        guardrails/terraform.tfvars. Compared, never printed.
#   FND4_BASELINE_DIR    default $HOME/.fnd-4-baseline (design 3.9 I1, I4)
#   FND4_CLONE_SOURCE    what to clone for the Terraform and repo checks
#                        (default: this repo, current branch; committed files)
#   FND4_TMPDIR          parent directory for the scratch directory
#
# Account IDs are never written here: they come from each profile's
# sts get-caller-identity.
#
# Baseline files (design 3.9 I1). Each may be raw CLI output, or a list or map
# of outputs keyed by call and region; the script searches the JSON:
#   op-trails.json                trail objects (with TrailARN and Name, from
#                                 describe-trails or get-trail). For each
#                                 trail, an object with its TrailARN holding
#                                 the get-event-selectors output (it has
#                                 TrailARN), the get-insight-selectors output
#                                 (TrailARN + InsightSelectors) and the
#                                 get-trail-status output, either at the top
#                                 of that object or one level down (for
#                                 example {"TrailARN": ..., "get-trail-status":
#                                 {...}}). get-trail-status has no TrailARN of
#                                 its own, so it must sit in such an object.
#   op-budgets.json               objects with BudgetName
#   op-anomaly-monitors.json      objects with MonitorArn
#   op-anomaly-subscriptions.json objects with SubscriptionArn
#   mgmt-anomaly-monitors.json, mgmt-anomaly-subscriptions.json  likewise
#   legacy-copy.json (I4, only if a trail was removed): a list of
#     {"trail_name","source_bucket","source_prefix","object_count",
#      "log_count","digest_count","copied_at"}. source_prefix is the key
#     prefix in the old bucket; each copied key K sits at
#     legacy/offers-platform-account-trail/K.

set -euo pipefail

export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off
export TF_IN_AUTOMATION=1
export TF_INPUT=0

FND4_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$FND4_SCRIPT_DIR/.." && pwd)

P_MGMT=${FND_MANAGEMENT_ADMIN:-fnd-management-admin}
P_ABC_ADMIN=${FND_ABC_BANK_ADMIN:-fnd-abc-bank-admin}
P_OP_ADMIN=${FND_OFFERS_PLATFORM_ADMIN:-fnd-offers-platform-admin}
P_ABC_ENG=${FND_ABC_BANK_ENGINEERING:-fnd-abc-bank-engineering}
ALL_PROFILES="$P_MGMT $P_ABC_ADMIN $P_OP_ADMIN $P_ABC_ENG"

BASELINE=${FND4_BASELINE_DIR:-$HOME/.fnd-4-baseline}

# Contract values (story, design 3.2 to 3.8). Not account-specific.
REGION=us-east-1
OTHER_REGIONS="us-west-2 eu-west-1"
DEFAULT_BUDGET_NAME=aws-foundations-monthly-cost
PS_ADMIN_NAME=Administrator
EXPECTED_PERMISSION_SETS="ABCBankEngineering Administrator OffersPlatformEngineering"
LEGACY_PREFIX=legacy/offers-platform-account-trail/
LEGACY_TAG_KEY=source
LEGACY_TAG_VALUE=offers-platform-account-trail
TEST_BUCKET_PREFIX=fnd4-audit-test-
EVENT_WINDOW=1800 # AC7 and TC30: 30 minutes; exactly 30:00 counts as within
POLL_INTERVAL=60
README_SECTION_RE='Offers Platform existing setup'
COST_TAG_KEYS="data-product environment owner cost-center"

AC_IDS="AC1 AC2 AC3 AC4 AC5 AC6 AC7 AC8 AC9 AC10 AC11 AC12 AC13 AC14"
REG_IDS="REG-TC68 REG-TC69 REG-TC70 REG-TC71 REG-TC72"

ERRLOG=/dev/null
WORK=""
CLONE=""
ANY_FAIL=0
ROOTS=""

# Discovered context (empty means "not found").
ACCT_MGMT="" ACCT_ABC="" ACCT_OP="" ORG_ID=""
ALERT_EMAIL="" POSTURE=""
SSO_INSTANCE_ARN=""
ROLE_ABC_ADMIN="" ROLE_OP_ADMIN=""
TRAIL_ARN="" TRAIL_BUCKET="" TRAIL_KEY_PREFIX=""
BUDGET_NAME=""

# AC7 / TC30 event phase state (main shell; read by cleanup and checks).
TEST_BUCKET="" TEST_BUCKET_CREATED=0 TEST_BUCKET_DELETED=0
EV_SKIP="" EV_START="" EV_LIST_AT="" EV_DELETE_AT="" EV_HEAD=""

# ---------------------------------------------------------------- helpers

# Masks e-mail addresses and 12-digit numbers in everything printed.
redact() {
  sed -E \
    -e 's/([A-Za-z0-9])[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/\1***@***/g' \
    -e 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<account-id>\2/g' \
    -e 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<account-id>\2/g'
}

log() { printf '%s\n' "$*" | redact >&2; }

# aws_call PROFILE REGION ARGS...: the only place the aws CLI is run.
aws_call() {
  local p=$1 r=$2
  shift 2
  aws --profile "$p" --region "$r" "$@"
}

awsp() {
  local p=$1
  shift
  aws_call "$p" "$REGION" "$@" 2>>"$ERRLOG"
}

awsr() {
  local p=$1 r=$2
  shift 2
  aws_call "$p" "$r" "$@" 2>>"$ERRLOG"
}

# aws_capture PROFILE REGION ARGS...: stdout to $WORK/cap.out, stderr to
# $WORK/cap.err (and the error log). Returns the CLI exit code.
aws_capture() {
  local p=$1 r=$2 rc=0
  shift 2
  aws_call "$p" "$r" "$@" >"$WORK/cap.out" 2>"$WORK/cap.err" || rc=$?
  cat "$WORK/cap.err" >>"$ERRLOG" 2>/dev/null || true
  return $rc
}

jqq() { jq "$@" 2>>"$ERRLOG"; }

JQ_LIB='
def arr: if type == "array" then . elif . == null then [] else [.] end;
def to_epoch:
  if type == "number" then (if . > 100000000000 then . / 1000 else . end | floor)
  elif type == "string" then
    ((capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})[T ](?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")) // null) as $m
    | if $m == null then null else
        ("\($m.d)T\($m.t)Z" | fromdateiso8601) as $e
        | (($m.z // "Z") | gsub(":"; "")) as $z
        | if $z == "Z" or $z == "" then $e
          else (($z[1:3] | tonumber) * 3600 + ($z[3:5] | tonumber) * 60) as $off
          | if $z[0:1] == "+" then $e - $off else $e + $off end
          end
      end
  else null end;
'

now_epoch() { date -u +%s; }
poll_sleep() { sleep "$1"; }
iso_of() { jq -nr --argjson e "$1" '$e | todate'; }
fmt_epoch() { jq -nr --argjson e "$1" --arg f "$2" '$e | strftime($f)'; }
to_epoch() {
  case "$1" in
    '' | *[!0-9]*) jq -nr --arg s "$1" "$JQ_LIB"'$s | to_epoch // empty' 2>>"$ERRLOG" || true ;;
    *) printf '%s\n' "$1" ;;
  esac
}
mmss() {
  local s=$1 sign=""
  if [ "$s" -lt 0 ]; then sign=-; s=$((-s)); fi
  printf '%s%d:%02d' "$sign" $((s / 60)) $((s % 60))
}
days_ago() { fmt_epoch $(($(now_epoch) - $1 * 86400)) %Y-%m-%d; }

# num_eq A B: numeric equality (100 == 100.0).
num_eq() { awk -v a="$1" -v b="$2" 'BEGIN { exit !((a "") != "" && (b "") != "" && a + 0 == b + 0) }'; }
num_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

expected_tag() {
  case "$1" in
    data-product) echo aws-foundations ;;
    environment) echo shared ;;
    owner) echo Lakshmi100 ;;
    cost-center) echo offers-platform-portfolio ;;
  esac
}

cost_tagset_json() {
  local k out="" sep=""
  for k in $COST_TAG_KEYS; do
    out="$out$sep{\"Key\":\"$k\",\"Value\":\"$(expected_tag "$k")\"}"
    sep=,
  done
  printf '{"TagSet":[%s]}' "$out"
}

posture_limit() {
  case "$1" in
    lean) echo 100 ;;
    working) echo 300 ;;
  esac
}

rand_suffix() { od -An -N5 -tx1 /dev/urandom | tr -d ' \n'; }

baseline_ok() { [ -s "$BASELINE/$1" ] && [ -r "$BASELINE/$1" ] && jq -e . "$BASELINE/$1" >/dev/null 2>&1; }

# baseline_objects FILE KEY: unique objects having KEY, one compact JSON per line.
baseline_objects() {
  jqq -c --arg k "$2" '[.. | objects | select(has($k) and (.[$k] | type) == "string")] | unique_by(.[$k]) | .[]' "$BASELINE/$1"
}

# arn_account ARN: the account field of an ARN (may be empty).
arn_account() { printf '%s' "$1" | awk -F: '{ print $5 }'; }

read_alert_email() {
  if [ -n "${FND4_ALERT_EMAIL:-}" ]; then
    printf '%s' "$FND4_ALERT_EMAIL"
    return 0
  fi
  local f="$REPO_DIR/guardrails/terraform.tfvars"
  [ -f "$f" ] || return 0
  sed -nE 's/^[[:space:]]*alert_email[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$f" | head -n 1
}

read_posture() {
  local f="$REPO_DIR/guardrails/terraform.tfvars" v=""
  [ -f "$f" ] && v=$(sed -nE 's/^[[:space:]]*posture[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$f" | head -n 1)
  printf '%s' "${v:-lean}"
}

# caller_json PROFILE: cached sts get-caller-identity.
caller_json() {
  local f="$WORK/caller.$1.json"
  if [ ! -s "$f" ]; then
    awsp "$1" sts get-caller-identity --output json >"$f" || { rm -f "$f"; return 1; }
  fi
  cat "$f"
}

caller_account() { caller_json "$1" 2>/dev/null | jqq -r '.Account // empty' || true; }

# find_sso_role PROFILE PERMISSION_SET_NAME: ARN of the AWSReservedSSO_<name>_ role.
find_sso_role() {
  local out
  out=$(awsp "$1" iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ --output json) || return 0
  printf '%s\n' "$out" | jqq -r --arg p "AWSReservedSSO_$2_" \
    '[.Roles[]? | select(.RoleName | startswith($p)) | .Arn] | if length == 1 then .[0] else empty end'
}

# tf_out ROOT NAME: Terraform output from the scratch clone (strings raw, others JSON).
tf_out() {
  local f="$WORK/tfout.$1.json"
  [ -s "$f" ] || return 0
  jqq -r --arg n "$2" '(.[$n].value) as $v | if $v == null then empty elif ($v | type) == "string" then $v else ($v | tojson) end' "$f" || true
}

has_root() { case " $ROOTS " in *" $1 "*) return 0 ;; esac; return 1; }

varfile_args() { [ -f "$REPO_DIR/$1/terraform.tfvars" ] && printf -- '-var-file=%s' "$REPO_DIR/$1/terraform.tfvars"; return 0; }

# tf_root ROOT ARGS...: terraform in the clone's root, as the management admin.
# Without a tfvars file, the alert e-mail is passed through the environment.
tf_root() {
  local name=$1
  shift
  if [ "$name" = guardrails ] && [ ! -f "$REPO_DIR/guardrails/terraform.tfvars" ] && [ -n "$ALERT_EMAIL" ]; then
    AWS_PROFILE=$P_MGMT TF_VAR_alert_email=$ALERT_EMAIL terraform -chdir="$CLONE/$name" "$@"
  else
    AWS_PROFILE=$P_MGMT terraform -chdir="$CLONE/$name" "$@"
  fi
}

# tf_plan_default_rc: exit code of the guardrails plan with no overrides (cached).
tf_plan_default_rc() {
  local f="$WORK/plan.default.rc" rc=0
  if [ ! -s "$f" ]; then
    if ! has_root guardrails; then
      echo missing >"$f"
    else
      tf_root guardrails plan -detailed-exitcode -input=false -no-color -lock-timeout=60s $(varfile_args guardrails) \
        >"$WORK/plan.default.log" 2>&1 || rc=$?
      echo $rc >"$f"
    fi
  fi
  cat "$f"
}

# sim_run / expect_sim: IAM policy simulator (same as tests/FND-3.sh).
sim_run() {
  local mode=$1 profile=$2 source=$3 resource=$4 context=$5
  shift 5
  local -a args
  if [ "$mode" = principal ]; then
    args=(iam simulate-principal-policy --policy-source-arn "$source")
  else
    args=(iam simulate-custom-policy --policy-input-list "$source")
  fi
  args+=(--action-names "$@" --resource-arns "$resource")
  if [ -n "$context" ]; then args+=(--context-entries "$context"); fi
  if [ -n "${SIM_RESOURCE_POLICY:-}" ]; then args+=(--resource-policy "$SIM_RESOURCE_POLICY"); fi
  if [ -n "${SIM_RESOURCE_OWNER:-}" ]; then args+=(--resource-owner "$SIM_RESOURCE_OWNER"); fi
  local out
  out=$(awsp "$profile" "${args[@]}" --output json) || return 1
  printf '%s\n' "$out" | jqq -r '.EvaluationResults[] | "\(.EvalActionName) \(.EvalDecision)"'
}

expect_sim() {
  local expect=$1 tag=$2
  shift 2
  local source=$3
  if [ -z "$source" ]; then
    echo "$tag: principal not found, cannot simulate"
    return 0
  fi
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

# ---------------------------------------------------------------- pure checks (self-tested)
# Each prints one problem line per failed check, nothing when all pass.

# AC1 TC01: describe-budgets output.
ac1_budgets_eval() {
  [ -n "${1:-}" ] || { echo "TC01 no budgets in the management account (0 cost budgets, expected exactly 1)"; return 0; }
  printf '%s' "${1:-}" | jqq -r '
    [.Budgets[]? | select(.BudgetType == "COST")] as $c
    | if ($c | length) != 1 then "TC01 \($c | length) cost budgets in the management account, expected exactly 1"
      else $c[0] as $b
      | (($b.BudgetLimit.Amount // "") | tostring) as $a
      | (if $b.TimeUnit != "MONTHLY" then "TC01 TimeUnit is \($b.TimeUnit // "missing"), expected MONTHLY" else empty end),
        (if ($a | test("^[0-9]+(\\.[0-9]+)?$") | not) or (($a | tonumber) != 100) then "TC01 limit is \($a) \($b.BudgetLimit.Unit // ""), expected 100 USD" else empty end),
          (if ($b.BudgetLimit.Unit // "") != "USD" then "TC01 limit unit is \($b.BudgetLimit.Unit // "missing"), expected USD" else empty end),
          (if ((($b.CostFilters // {}) | length) > 0) or ($b.FilterExpression != null) then "TC01 budget has cost filters, expected the whole organization" else empty end),
          (($b.CostTypes // {}) as $t
            | (if $t.UseBlended == true then "TC01 budget uses blended cost, expected unblended" else empty end),
              (if $t.UseAmortized == true then "TC01 budget uses amortized cost, expected unblended" else empty end),
              ($t | to_entries[] | select((.key | startswith("Include")) and .value == false) | "TC01 cost type \(.key) is false, expected the AWS default (true)"))
      end' || echo "TC01 describe-budgets output could not be parsed"
}

# AC1 TC02: describe-notifications-for-budget output.
ac1_notifications_eval() {
  [ -n "${1:-}" ] || { echo "TC02 notifications could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r '
    (.Notifications // []) as $n
    | (if ($n | length) != 3 then "TC02 \($n | length) notifications, expected 3" else empty end),
      ($n[] | select(.NotificationType != "ACTUAL") | "TC02 a \(.NotificationType // "?") notification at \(.Threshold), expected ACTUAL"),
      ($n[] | select(.ComparisonOperator != "GREATER_THAN") | "TC02 notification at \(.Threshold) uses \(.ComparisonOperator // "?"), expected GREATER_THAN"),
      ($n[] | select((.ThresholdType // "PERCENTAGE") != "PERCENTAGE") | "TC02 notification at \(.Threshold) is \(.ThresholdType), expected PERCENTAGE"),
      (([$n[].Threshold | tonumber] | sort) as $t
        | if $t != [50, 80, 100] then "TC02 thresholds are \($t | map(tostring) | join("/")), expected 50/80/100" else empty end)' ||
    echo "TC02 notifications could not be parsed"
}

# AC1 TC03: describe-subscribers-for-notification output. ARGS: JSON EMAIL LABEL.
ac1_subscribers_eval() {
  [ -n "${1:-}" ] || { echo "TC03 subscribers could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r --arg e "${2:-}" --arg l "$3" '
    (.Subscribers // []) as $s
    | if ($s | length) != 1 then "TC03 notification at \($l)%: \($s | length) subscribers, expected 1"
      else $s[0]
      | (if .SubscriptionType != "EMAIL" then "TC03 notification at \($l)%: subscriber type \(.SubscriptionType // "?"), expected EMAIL" else empty end),
        (if $e != "" and ((.Address // "") | ascii_downcase) != ($e | ascii_downcase) then "TC03 notification at \($l)%: subscriber is not the engineer e-mail" else empty end)
      end' || echo "TC03 subscribers could not be parsed"
}

# AC2 TC05/TC06: terraform show -json of the posture=working plan.
ac2_plan_eval() {
  [ -n "${1:-}" ] || { echo "TC05 plan JSON could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r '
    [.resource_changes[]? | select(.change.actions != ["no-op"])] as $c
    | if ($c | length) != 1 then
        "TC05 \($c | length) resources change, expected exactly 1 (the budget): \([$c[] | "\(.address) \(.change.actions | join("+"))"] | join(", "))"
      else $c[0] as $r
      | (if $r.type != "aws_budgets_budget" then "TC05 the change is to \($r.address), expected the budget" else empty end),
        (if $r.change.actions != ["update"] then "TC05 budget action is \($r.change.actions | join("+")), expected update in place" else empty end),
        (($r.change.before // {}) as $b | ($r.change.after // {}) as $a | ($r.change.after_unknown // {}) as $u
          | ([($b | keys[]), ($a | keys[])] | unique | map(select($b[.] != $a[.] or $u[.] == true))) as $ch
          | (if $ch != ["limit_amount"] then "TC05 changed attributes are [\($ch | join(", "))], expected only limit_amount" else empty end),
            (if (($b.limit_amount // "x") | tostring | tonumber? // -1) != 100 or (($a.limit_amount // "x") | tostring | tonumber? // -1) != 300
             then "TC05 limit changes \($b.limit_amount // "?") to \($a.limit_amount // "?"), expected 100 to 300" else empty end),
            (if $b.notification != $a.notification then "TC06 budget notifications or subscribers change" else empty end))
      end' || echo "TC05 plan JSON could not be parsed"
}

# AC2 TC08: plan with an unsupported posture value. ARGS: VALUE RC LOGFILE.
ac2_invalid_eval() {
  local shown="'$1'"
  [ -n "$1" ] || shown='"" (empty)'
  if [ "$2" = 1 ] && grep -q 'Invalid value for variable' "$3" 2>/dev/null; then return 0; fi
  echo "TC08 posture=$shown was not rejected by variable validation (plan exit $2)"
}

# AC3 TC10/TC11. ARGS: MTD_USD LIVE_LIMIT POSTURE PLAN_RC.
ac3_eval() {
  local mtd=$1 live=$2 posture=$3 rc=$4 want
  want=$(posture_limit "$posture")
  if [ -z "$want" ]; then
    echo "TC11 configured posture '$posture' is not lean or working"
  elif [ -z "$live" ]; then
    echo "TC11 live budget limit unknown"
  elif num_eq "$live" 0.01; then
    echo "TC11 live limit is 0.01: the AC3 test override was not reset"
  elif ! num_eq "$live" "$want"; then
    echo "TC11 live limit is $live, expected $want for posture $posture"
  fi
  [ "$rc" = 0 ] || echo "TC11 terraform plan in guardrails exited ${rc:-unknown}, expected 0 (no changes)"
  if [ -z "$mtd" ]; then
    echo "TC10 month-to-date unblended spend could not be read"
  elif ! num_gt "$mtd" 0; then
    echo "@MANUAL wait until month-to-date spend is above \$0.00, then run the AC3 owner step (TC09, TC10)"
  else
    echo "@MANUAL owner step: set budget_limit_override_usd = 0.01, apply, check the budget alert e-mail arrives within 24 hours, set it back to null and apply; plan then shows no changes. Month-to-date unblended spend is \$$(printf '%.2f' "$mtd") (TC09)"
  fi
}

# AC4 TC12: get-anomaly-monitors output.
ac4_monitors_eval() {
  [ -n "${1:-}" ] || { echo "TC12 monitors could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r '
    [.AnomalyMonitors[]? | select(.MonitorType == "DIMENSIONAL" and .MonitorDimension == "SERVICE")] as $s
    | if ($s | length) != 1 then "TC12 \($s | length) service monitors (DIMENSIONAL, SERVICE), expected exactly 1" else empty end' ||
    echo "TC12 monitors could not be parsed"
}

service_monitor_arn() {
  printf '%s' "${1:-}" | jqq -r '[.AnomalyMonitors[]? | select(.MonitorType == "DIMENSIONAL" and .MonitorDimension == "SERVICE") | .MonitorArn]
    | if length == 1 then .[0] else empty end' || true
}

# AC4 TC13/TC15: get-anomaly-subscriptions output. ARGS: JSON SERVICE_MONITOR_ARN EMAIL.
ac4_subscriptions_eval() {
  [ -n "${1:-}" ] || { echo "TC13 subscriptions could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r --arg m "$2" --arg e "${3:-}" '
    def dimok: (.Dimensions // null) as $d
      | $d != null and $d.Key == "ANOMALY_TOTAL_IMPACT_ABSOLUTE" and ($d.MatchOptions // []) == ["GREATER_THAN_OR_EQUAL"]
        and (($d.Values // []) | length) == 1 and (($d.Values[0] | tostring | tonumber?) // -1) == 10;
    [.AnomalySubscriptions[]? | select(any((.MonitorArnList // [])[]; . == $m))] as $s
    | if ($s | length) == 0 then "TC13 no anomaly subscription on the service monitor"
      elif ($s | length) > 1 then "TC15 \($s | length) subscriptions on the service monitor, expected exactly 1"
      else $s[0]
      | (if .Frequency != "DAILY" then "TC13 frequency is \(.Frequency // "?"), expected DAILY" else empty end),
        ((.Subscribers // []) as $sub
          | if ($sub | length) != 1 then "TC13 \($sub | length) subscribers, expected 1"
            else $sub[0]
            | (if .Type != "EMAIL" then "TC13 subscriber type is \(.Type // "?"), expected EMAIL" else empty end),
              (if $e != "" and ((.Address // "") | ascii_downcase) != ($e | ascii_downcase) then "TC13 subscriber is not the engineer e-mail" else empty end)
            end),
        ((.ThresholdExpression // null) as $te
          | (if $te != null then (($te | dimok) or ((($te.And // $te.Or // null) | if . == null then false else (length == 1 and (.[0] | dimok)) end)))
             else ((.Threshold // null) != null and (.Threshold | tonumber) == 10) end) as $ok
          | if $ok then empty else "TC13 threshold is not total impact >= $10 absolute" end)
      end' || echo "TC13 subscriptions could not be parsed"
}

# AC5 TC17/TC18: list-cost-allocation-tags output.
ac5_eval() {
  [ -n "${1:-}" ] || { echo "TC17 cost-allocation tags could not be read"; return 0; }
  local k
  for k in $COST_TAG_KEYS; do
    printf '%s' "${1:-}" | jqq -r --arg k "$k" '
      [.CostAllocationTags[]? | select(.TagKey == $k)]
      | if length == 0 then "TC17 tag \($k) is not listed: AWS has not seen it on a billed resource yet"
        else .[0]
        | (if .Type != "UserDefined" then "TC17 tag \($k) type is \(.Type // "?"), expected UserDefined" else empty end),
          (if .Status != "Active" then "TC17 tag \($k) is \(.Status // "?"), expected Active" else empty end)
        end' || echo "TC17 cost-allocation tags could not be parsed"
  done
}

# pick_org_trail DESCRIBE_JSON PREFERRED_ARN: the organization trail record.
pick_org_trail() {
  printf '%s' "${1:-}" | jqq -c --arg a "${2:-}" '
    [.trailList[]? | select(.IsOrganizationTrail == true)] as $o
    | (if $a != "" then [$o[] | select(.TrailARN == $a)] else [] end) as $p
    | if ($p | length) > 0 then $p[0] elif ($o | length) > 0 then $o[0] else empty end' || true
}

# AC6 TC19/TC23/TC24/TC25: describe-trails --include-shadow-trails (management).
# ARGS: JSON MGMT_ID MGMT_BUCKET_NAMES_JSON_ARRAY
ac6_trail_eval() {
  [ -n "${1:-}" ] || { echo "TC19 describe-trails output could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r --arg m "${2:-}" --argjson bk "${3:-null}" '
    [.trailList[]? | select(.IsOrganizationTrail == true)] as $o
    | if ($o | length) == 0 then "TC19 no organization trail"
      else
        (if ($o | length) > 1 then "TC24 \($o | length) organization trails, expected exactly 1" else empty end),
        ($o[0]
          | (if .IsMultiRegionTrail != true then "TC19 trail is not multi-region" else empty end),
            (if .LogFileValidationEnabled != true then "TC19 log file validation is off" else empty end),
            (if .IncludeGlobalServiceEvents != true then "TC19 global service events are not included" else empty end),
            (if .HomeRegion != "us-east-1" then "TC19 home region is \(.HomeRegion // "?"), expected us-east-1" else empty end),
            (if $m == "" or ((.TrailARN // "") | split(":")[4]) != $m then "TC19 trail ARN is not in the management account" else empty end),
            ((.S3BucketName // "") as $sb
              | if $bk == null then "TC19 management bucket list unavailable; trail bucket owner not checked"
                elif (any($bk[]; . == $sb) | not) then "TC19 trail bucket is not owned by the management account" else empty end),
            (if (.CloudWatchLogsLogGroupArn // "") != "" then "TC23 trail delivers to CloudWatch Logs" else empty end),
            (if (.SnsTopicARN // .SnsTopicName // "") != "" then "TC23 trail has an SNS topic" else empty end),
            (if (.KmsKeyId // "") != "" then "TC23 trail uses a KMS key" else empty end),
            (if .HasInsightSelectors == true then "TC23 trail has Insights selectors" else empty end))
      end' || echo "TC19 describe-trails output could not be parsed"
}

# AC6 TC20/TC25: get-event-selectors output.
ac6_selectors_eval() {
  [ -n "${1:-}" ] || { echo "TC20 event selectors could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r '
    def fs($f): [(.FieldSelectors // [])[] | select(.Field == $f)];
    (.EventSelectors // []) as $e | (.AdvancedEventSelectors // []) as $a
    | if ($e | length) > 0 then
        (if any($e[]; .IncludeManagementEvents == true and (.ReadWriteType // "All") == "All") | not
         then "TC20 no selector records read and write management events (ReadWriteType \([$e[].ReadWriteType // "?"] | join(",")))" else empty end),
        (if any($e[]; ((.ExcludeManagementEventSources // []) | length) > 0) then "TC20 management event sources are excluded" else empty end),
        (if any($e[]; ((.DataResources // []) | length) > 0) then "TC20 data event selectors present (out of scope)" else empty end)
      elif ($a | length) > 0 then
        (if any($a[]; (fs("eventCategory") | any(.[]; (.Equals // []) == ["Management"])) and (fs("readOnly") | length) == 0 and (fs("eventSource") | length) == 0) | not
         then "TC20 no advanced selector records all read and write management events" else empty end),
        (if any($a[]; fs("eventSource") | length > 0) then "TC20 management event sources are filtered or excluded" else empty end),
        (if any($a[]; fs("eventCategory") | any(.[]; ((.Equals // []) | map(select(. != "Management")) | length) > 0)) then "TC20 non-management event selectors present (out of scope)" else empty end)
      else "TC20 trail has no event selectors" end' || echo "TC20 event selectors could not be parsed"
}

# AC6 TC21/TC25: get-trail-status output. ARGS: JSON NOW_EPOCH
ac6_status_eval() {
  [ -n "${1:-}" ] || { echo "TC21 trail status could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r --argjson now "$2" "$JQ_LIB"'
    (if .IsLogging != true then "TC21 trail is not logging" else empty end),
    (if (.LatestDeliveryError // "") != "" then "TC21 LatestDeliveryError is set" else empty end),
    (if (.LatestDigestDeliveryError // "") != "" then "TC21 LatestDigestDeliveryError is set" else empty end),
    ((.LatestDeliveryTime // null | to_epoch) as $t
      | if $t == null then "TC21 no LatestDeliveryTime"
        elif ($now - $t) > 7200 then "TC21 last log delivery was more than 2 hours ago" else empty end)' ||
    echo "TC21 trail status could not be parsed"
}

# AC6 TC30. ARGS: SKIP LIST_AT FOUND_FILE MGMT_ID ABC_ID OP_ID
ac6_reads_eval() {
  if [ -n "$1" ]; then
    echo "TC30 not run: $1"
    return 0
  fi
  local label id seen
  for label in management abc_bank offers_platform; do
    case $label in management) id=$4 ;; abc_bank) id=$5 ;; *) id=$6 ;; esac
    seen=$(awk -F'\t' -v a="$id" '$1 == "ListBuckets" && $2 == a { print $4; exit }' "$3" 2>/dev/null)
    if [ -z "$seen" ]; then
      echo "TC30 no ListBuckets (read) event for the $label account within 30:00"
    elif [ $((seen - $2)) -gt "$EVENT_WINDOW" ]; then
      echo "TC30 ListBuckets event for the $label account arrived after $(mmss $((seen - $2))) (over 30:00)"
    fi
  done
}

# AC7 TC26-TC29. ARGS: SKIP CREATED DELETE_AT C_SEEN C_RECIP C_ARN D_SEEN D_RECIP D_ARN ABC_ID HEAD
ac7_eval() {
  local skip=$1 created=$2 dat=$3 cs=$4 cr=$5 ca=$6 ds=$7 dr=$8 da=$9 abc=${10} head=${11}
  if [ -n "$skip" ]; then
    echo "TC26 $skip"
    return 0
  fi
  if [ "$created" != 1 ]; then
    echo "TC26 test bucket was not created"
  else
    local c_in=0 d_in=0
    [ -n "$cs" ] && [ $((cs - dat)) -le "$EVENT_WINDOW" ] && c_in=1
    [ -n "$ds" ] && [ $((ds - dat)) -le "$EVENT_WINDOW" ] && d_in=1
    if [ -z "$cs" ] && [ -z "$ds" ]; then
      echo "TC29 no CreateBucket or DeleteBucket event in the trail bucket within 30:00 of the delete"
    else
      [ -n "$cs" ] || echo "TC29 only DeleteBucket seen; no CreateBucket event within 30:00"
      [ -n "$ds" ] || echo "TC29 only CreateBucket seen; no DeleteBucket event within 30:00"
      [ -z "$cs" ] || [ $c_in = 1 ] || echo "TC29 CreateBucket event arrived $(mmss $((cs - dat))) after the delete (over 30:00)"
      [ -z "$ds" ] || [ $d_in = 1 ] || echo "TC29 DeleteBucket event arrived $(mmss $((ds - dat))) after the delete (over 30:00)"
    fi
    local ev r a
    for ev in CreateBucket DeleteBucket; do
      if [ $ev = CreateBucket ]; then r=$cr a=$ca; [ -n "$cs" ] || continue; else r=$dr a=$da; [ -n "$ds" ] || continue; fi
      [ -n "$abc" ] && [ "$r" = "$abc" ] || echo "TC26 $ev event recipientAccountId is not the ABC Bank account"
      case "$a" in
        arn:aws:sts::"$abc":assumed-role/AWSReservedSSO_Administrator_*) ;;
        *) echo "TC27 $ev event was not made by the ABC Bank administrator Identity Center role" ;;
      esac
    done
  fi
  case "$head" in
    404) ;;
    exists) echo "TC28 test bucket still exists after the run" ;;
    "") [ "$created" != 1 ] || echo "TC28 head-bucket was not checked" ;;
    *) echo "TC28 head-bucket on the test bucket did not return 404 ($head)" ;;
  esac
}

# ac8_count TEXT digest|log FIELD(1 valid, 2 total): sums "V/T <kind> files valid".
ac8_count() {
  { printf '%s\n' "$1" | grep -oE "[0-9]+/[0-9]+ $2 files? valid" || true; } | awk -F'[/ ]' -v f="$3" '{ s += $f } END { print s + 0 }'
}

# AC8 TC31/TC33: validate-logs text. ARGS: OUTPUT RC LABEL REQUIRE_LOGS(yes|no)
ac8_validate_eval() {
  local out=$1 rc=$2 label=$3 req=$4 dv dt lv lt
  [ "$rc" = 0 ] || echo "TC31 $label: validate-logs exited $rc"
  if printf '%s\n' "$out" | grep -Eq 'INVALID|MISSING|[Nn]ot valid|could not be validated'; then
    echo "TC33 $label: invalid or missing files reported"
  fi
  dv=$(ac8_count "$out" digest 1)
  dt=$(ac8_count "$out" digest 2)
  lv=$(ac8_count "$out" log 1)
  lt=$(ac8_count "$out" log 2)
  [ "$dv" -gt 0 ] || echo "TC33 $label: no digest file validated"
  [ "$dv" = "$dt" ] || echo "TC33 $label: $dv of $dt digest files valid"
  [ "$lv" = "$lt" ] || echo "TC33 $label: $lv of $lt log files valid"
  [ "$req" != yes ] || [ "$lv" -gt 0 ] || echo "TC33 $label: no log file validated"
  return 0
}

# AC9 TC34-TC40, one function per bucket setting.
ac9_versioning_eval() {
  [ -n "${1:-}" ] || { echo "TC34 versioning could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r 'if .Status != "Enabled" then "TC34 versioning is \(.Status // "off"), expected Enabled" else empty end' ||
    echo "TC34 versioning could not be read"
}

ac9_pab_eval() {
  [ -n "${1:-}" ] || { echo "TC35 public access block could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r '(.PublicAccessBlockConfiguration // {}) as $p
    | ("BlockPublicAcls", "IgnorePublicAcls", "BlockPublicPolicy", "RestrictPublicBuckets")
    | select($p[.] != true) | "TC35 public access block \(.) is not true"' || echo "TC35 public access block could not be read"
}

# ARGS: POLICY_STATUS_JSON ACL_JSON POLICY_DOCUMENT_JSON
ac9_public_eval() {
  [ -n "${1:-}" ] || echo "TC35 policy status could not be read"
  [ -n "${2:-}" ] || echo "TC35 ACL could not be read"
  [ -n "${3:-}" ] || echo "TC35 bucket policy could not be read"
  printf '%s' "${1:-}" | jqq -r 'if .PolicyStatus.IsPublic != false then "TC35 bucket policy status is public (or unknown)" else empty end' ||
    echo "TC35 policy status could not be read"
  printf '%s' "${2:-}" | jqq -r '.Grants[]? | select((.Grantee.URI // "") | test("AllUsers|AuthenticatedUsers")) | "TC35 ACL grants \(.Permission) to \(.Grantee.URI | split("/") | last)"' ||
    echo "TC35 ACL could not be read"
  printf '%s' "${3:-}" | jqq -r "$JQ_LIB"'
    (if type == "string" then fromjson else . end) | (.Statement | arr)[]
    | select(.Effect == "Allow")
    | select(.Principal == "*" or any(((.Principal.AWS // null) | arr)[]; . == "*"))
    | select((.Condition // {} | tostring | test(":cloudtrail:")) | not)
    | "TC35 a bucket policy statement allows any principal without a CloudTrail condition"' ||
    echo "TC35 bucket policy could not be parsed"
}

ac9_encryption_eval() {
  [ -n "${1:-}" ] || { echo "TC36 encryption could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r '[.ServerSideEncryptionConfiguration.Rules[]?.ApplyServerSideEncryptionByDefault.SSEAlgorithm] as $a
    | if ($a | length) == 0 then "TC36 no default encryption"
      elif any($a[]; . != "AES256") then "TC36 default encryption is \($a | join(",")), expected AES256 (S3-managed)" else empty end' ||
    echo "TC36 encryption could not be read"
}

ac9_lifecycle_eval() {
  [ -n "${1:-}" ] || { echo "TC37 lifecycle configuration could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r '
    def whole: ((.Filter // null) as $f | ($f == null or $f == {} or $f == {"Prefix": ""})) and ((.Prefix // "") == "");
    [(.Rules // [])[] | select(.Status == "Enabled")] as $e
    | (if any($e[]; whole and .Expiration.Days == 90) | not then "TC37 no enabled whole-bucket rule expires current objects after 90 days" else empty end),
      (if any($e[]; whole and .NoncurrentVersionExpiration.NoncurrentDays == 30) | not then "TC37 no enabled whole-bucket rule expires earlier versions after 30 days" else empty end),
      (if any($e[]; whole and .Expiration.ExpiredObjectDeleteMarker == true) | not then "TC38 no enabled whole-bucket rule removes expired delete markers" else empty end),
      ($e[] | select(.Expiration.Days != null and .Expiration.Days != 90) | "TC37 rule \(.ID // "?") expires objects after \(.Expiration.Days) days, expected 90"),
      ($e[] | select(.NoncurrentVersionExpiration.NoncurrentDays != null and .NoncurrentVersionExpiration.NoncurrentDays != 30)
        | "TC37 rule \(.ID // "?") expires earlier versions after \(.NoncurrentVersionExpiration.NoncurrentDays) days, expected 30")' ||
    echo "TC37 lifecycle configuration could not be read"
}

ac9_location_eval() {
  [ -n "${1:-}" ] || { echo "TC40 bucket location could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r '(.LocationConstraint // "") as $l | if $l == "" or $l == "us-east-1" then empty else "TC40 bucket is in \($l), expected us-east-1" end' ||
    echo "TC40 bucket location could not be read"
}

# AC10 TC41: describe-trails --include-shadow-trails from a member. ARGS: JSON MGMT_ID TRAIL_ARN LABEL
ac10_trail_eval() {
  [ -n "${1:-}" ] || { echo "TC41 $4: describe-trails output could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r --arg m "${2:-}" --arg a "${3:-}" --arg l "$4" '
    [.trailList[]? | select(($a != "" and .TrailARN == $a) or ($a == "" and .IsOrganizationTrail == true))] as $t
    | if ($t | length) == 0 then "TC41 \($l): the organization trail is not visible"
      else $t[0]
      | (if .IsOrganizationTrail != true then "TC41 \($l): IsOrganizationTrail is not true" else empty end),
        (if .HomeRegion != "us-east-1" then "TC41 \($l): HomeRegion is \(.HomeRegion // "?"), expected us-east-1" else empty end),
        (if $m == "" or ((.TrailARN // "") | split(":")[4]) != $m then "TC41 \($l): trail ARN is not in the management account" else empty end)
      end' || echo "TC41 $4: describe-trails output could not be parsed"
}

# AC10 TC42/TC43. ARGS: RC ERR_TEXT BUDGETS_JSON ORG_BUDGET_NAME ORG_LIMIT ALLOWED_NAMES_JSON LABEL
ac10_budgets_eval() {
  local rc=$1 err=$2 j=$3 name=$4 limit=$5 allowed=${6:-[]} label=$7
  if [ "$rc" != 0 ]; then
    if printf '%s' "$err" | grep -q 'NotFoundException'; then return 0; fi
    echo "TC42 $label: describe-budgets failed (inconclusive, not NotFoundException)"
    return 0
  fi
  printf '%s' "$j" | jqq -r --arg n "$name" --arg lim "${limit:-}" --argjson ok "$allowed" --arg l "$label" '
    .Budgets[]? | .BudgetName as $bn | select(any($ok[]; . == $bn) | not)
    | if .BudgetName == $n then "TC42 \($l): a budget with the organization budget name exists"
      elif .BudgetType == "COST" and .TimeUnit == "MONTHLY" and (((.CostFilters // {}) | length) == 0) and .FilterExpression == null
           and $lim != "" and ((.BudgetLimit.Amount // "x") | tonumber? // -1) == ($lim | tonumber)
      then "TC42 \($l): a budget with the organization budget definition exists (\(.BudgetName))"
      else empty end' || echo "TC42 $label: budgets could not be parsed"
}

# AC11 TC47/TC51: classify a trail. ARGS: TRAIL_JSON SELECTORS_JSON INSIGHTS_JSON
# Prints "management-only" or "other".
ac11_trail_kind() {
  jq -nr --argjson t "${1:-null}" --argjson s "${2:-null}" --argjson i "${3:-null}" '
    def fs($f): [(.FieldSelectors // [])[] | select(.Field == $f)];
    if $t == null or $s == null then "unknown"
    elif (($t.CloudWatchLogsLogGroupArn // "") != "") or (($t.SnsTopicARN // $t.SnsTopicName // "") != "") then "other"
    elif any(($s.EventSelectors // [])[]; ((.DataResources // []) | length) > 0) then "other"
    elif any(($s.AdvancedEventSelectors // [])[]; fs("eventCategory") | any(.[]; ((.Equals // []) | map(select(. != "Management")) | length) > 0)) then "other"
    elif (($i // {}).InsightSelectors // []) | length > 0 then "other"
    else "management-only" end' 2>>"$ERRLOG" || echo unknown
}

# AC11 TC54 reader checks. Notification configuration JSON.
ac11_notification_eval() {
  [ -n "${1:-}" ] || { echo "TC54 notification configuration could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r '
    (if ((.TopicConfigurations // []) + (.QueueConfigurations // []) + (.LambdaFunctionConfigurations // []) | length) > 0
     then "TC54 old bucket has S3 event notifications" else empty end),
    (if has("EventBridgeConfiguration") then "TC54 old bucket sends events to EventBridge" else empty end)' ||
    echo "TC54 notification configuration could not be parsed"
}

# ARGS: POLICY_DOCUMENT_JSON OP_ID
ac11_policy_readers_eval() {
  [ -n "${1:-}" ] || { echo "TC54 old bucket policy could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r --arg op "$2" "$JQ_LIB"'
    (if type == "string" then fromjson else . end) | (.Statement | arr)[]
    | select(.Effect == "Allow")
    | (if .Principal == "*" then ["*"] else (((.Principal.AWS // null) | arr) | map(tostring)) end) as $aws
    | ((.Principal.Service // null) | arr) as $svc
    | (if .Principal == "*" or any($aws[]; . == "*" or (test("^[0-9]{12}$") and . != $op) or (test("^arn:") and (split(":")[4] != $op)))
       then "TC54 old bucket policy lets another account or anyone access it" else empty end),
      (if any($svc[]; . != "cloudtrail.amazonaws.com") then "TC54 old bucket policy lets a service other than CloudTrail access it" else empty end)' ||
    echo "TC54 old bucket policy could not be parsed"
}

ac11_acl_eval() {
  [ -n "${1:-}" ] || { echo "TC54 old bucket ACL could not be read"; return 0; }
  printf '%s' "${1:-}" | jqq -r '(.Owner.ID // "") as $o
    | .Grants[]? | select((.Grantee.Type // "") != "CanonicalUser" or (.Grantee.ID // "") != $o)
    | "TC54 old bucket ACL grants \(.Permission // "?") to someone other than the owner"' ||
    echo "TC54 old bucket ACL could not be parsed"
}

# ARGS: LOCATIONS_TEXT (one per line) BUCKET
ac11_tables_eval() {
  local n
  n=$(printf '%s\n' "$1" | awk -v b="$2" '{ l = tolower($0) } index(l, "s3://" tolower(b) "/") == 1 || l == "s3://" tolower(b) { c++ } END { print c + 0 }')
  [ "$n" = 0 ] || echo "TC54 $n Glue or Athena table(s) point at the old bucket"
}

# AC11 TC55/TC56/TC58. ARGS: SRC_KEYS_FILE DST_KEYS_FILE (legacy prefix removed)
#   RECORDED_OBJECTS RECORDED_LOGS RECORDED_DIGESTS (may be empty)
ac11_copy_eval() {
  local src=$1 dst=$2 ns nd miss extra sd dd sl dl
  LC_ALL=C sort -u "$src" | sed '/^$/d' >"$src.s"
  LC_ALL=C sort -u "$dst" | sed '/^$/d' >"$dst.s"
  ns=$(wc -l <"$src.s" | tr -d ' ')
  nd=$(wc -l <"$dst.s" | tr -d ' ')
  [ "$ns" = "$nd" ] || echo "TC56 old prefix has $ns objects, the copy has $nd"
  miss=$(LC_ALL=C comm -23 "$src.s" "$dst.s" | wc -l | tr -d ' ')
  extra=$(LC_ALL=C comm -13 "$src.s" "$dst.s" | wc -l | tr -d ' ')
  [ "$miss" = 0 ] || echo "TC56 $miss source key(s) have no copy at ${LEGACY_PREFIX}<key>"
  [ "$extra" = 0 ] || echo "TC56 $extra copied key(s) have no matching source key"
  sd=$(grep -c '/CloudTrail-Digest/' "$src.s" || true)
  dd=$(grep -c '/CloudTrail-Digest/' "$dst.s" || true)
  sl=$(grep -c '/CloudTrail/' "$src.s" || true)
  dl=$(grep -c '/CloudTrail/' "$dst.s" || true)
  [ "$sd" = "$dd" ] || echo "TC56 digest files: $sd in the old prefix, $dd in the copy"
  [ "$sl" = "$dl" ] || echo "TC56 log files: $sl in the old prefix, $dl in the copy"
  [ "$dd" -gt 0 ] || echo "TC56 no CloudTrail-Digest files in the copy"
  [ "$dl" -gt 0 ] || echo "TC56 no log files in the copy"
  [ -z "${3:-}" ] || [ "$ns" -ge "$3" ] || echo "TC55 old prefix has $ns objects, fewer than the $3 recorded at the copy"
  [ -z "${4:-}" ] || [ "$dl" = "$4" ] || echo "TC56 copy has $dl log files, legacy-copy.json recorded $4"
  [ -z "${5:-}" ] || [ "$dd" = "$5" ] || echo "TC56 copy has $dd digest files, legacy-copy.json recorded $5"
  rm -f "$src.s" "$dst.s"
}

# AC11 TC57/TC58: get-object-tagging output. Prints "ok", "missing" or "wrong".
legacy_tag_state() {
  printf '%s' "${1:-}" | jqq -r --arg k "$LEGACY_TAG_KEY" --arg v "$LEGACY_TAG_VALUE" '
    [.TagSet[]? | select(.Key == $k)] | if length == 0 then "missing" elif .[0].Value == $v then "ok" else "wrong" end' || echo missing
}

# AC11 TC59. ARGS: RECORD_PRESENT(yes|no) LEGACY_OBJECT_COUNT
ac11_no_record_eval() {
  [ "$1" = no ] || return 0
  if [ -z "$2" ]; then
    echo "TC59 could not list ${LEGACY_PREFIX} in the trail bucket"
  elif [ "$2" != 0 ]; then
    echo "TC59 objects under ${LEGACY_PREFIX} but legacy-copy.json records no removed trail"
  fi
}

# readme_section FILE: the "Offers Platform existing setup" section.
readme_section() {
  awk -v re="$README_SECTION_RE" '
    /^#+[[:space:]]/ {
      lvl = match($0, /[^#]/) - 1
      if (in_s && lvl <= slvl) exit
      if (!in_s && $0 ~ re) { in_s = 1; slvl = lvl }
    }
    in_s { print }' "$1" 2>/dev/null
}

# AC11 TC48/TC49/TC51/TC52. ARGS: SECTION_FILE NAMES_FILE (lines "kind<TAB>name<TAB>status")
# status: kept, removed or present (budgets, monitors).
ac11_readme_eval() {
  local sec=$1 names=$2 kind name status line
  if [ ! -s "$sec" ]; then
    echo "TC48 README.md has no '$README_SECTION_RE' section"
    return 0
  fi
  for kind in trail budget monitor; do
    if ! awk -F'\t' -v k="$kind" '$1 == k { f = 1 } END { exit !f }' "$names"; then
      grep -i "$kind" "$sec" | grep -qi 'none found' || echo "TC48 README does not say 'none found' for ${kind}s"
    fi
  done
  while IFS="$(printf '\t')" read -r kind name status; do
    [ -n "$name" ] || continue
    line=$(grep -F -- "$name" "$sec" | head -n 1 || true)
    if [ -z "$line" ]; then
      echo "TC49 README does not list $kind '$name'"
      continue
    fi
    printf '%s' "$line" | grep -Eqi 'removed|deleted|kept|keep|left alone|left in place|unchanged' ||
      echo "TC48 README lists $kind '$name' without what was done"
    case "$status" in
      kept)
        printf '%s' "$line" | grep -qi 'kept\|keep' || echo "TC51 README does not list trail '$name' as kept"
        printf '%s' "$line" | grep -Eq '\$[0-9]' || echo "TC52 README does not state the monthly cost of kept trail '$name'"
        ;;
      removed) printf '%s' "$line" | grep -Eqi 'removed|deleted' || echo "TC48 README does not list trail '$name' as removed" ;;
    esac
  done <"$names"
  # Table rows that name nothing from the baseline (README lists something absent from the baseline).
  awk -F'|' '
    { rows[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        r = rows[i]
        if (r !~ /^[[:space:]]*\|/) continue
        if (r ~ /^[[:space:]]*\|[[:space:]:|-]+$/) continue
        if ((i + 1) in rows && rows[i + 1] ~ /^[[:space:]]*\|[[:space:]:|-]+$/) continue
        print r
      }
    }' "$sec" | while IFS= read -r line; do
    printf '%s' "$line" | grep -qi 'none found' && continue
    local hit=0 cell
    while IFS= read -r cell; do
      cell=$(printf '%s' "$cell" | sed -E 's/`//g; s/^[[:space:]]+//; s/[[:space:]]+$//')
      [ -n "$cell" ] || continue
      if awk -F'\t' -v n="$cell" '$2 == n { f = 1 } END { exit !f }' "$names"; then hit=1; break; fi
    done <<EOF
$(printf '%s\n' "$line" | tr '|' '\n')
EOF
    [ $hit = 1 ] || echo "TC49 README table row names nothing from the baseline: $(printf '%s' "$line" | cut -c1-60)"
  done
  return 0
}

# AC11 TC60: the removal procedure in README. ARGS: SECTION_FILE
ac11_procedure_eval() {
  local sec=$1 c m1 m2 m3 m4
  [ -s "$sec" ] || { echo "TC60 README has no '$README_SECTION_RE' section"; return 0; }
  for c in get-bucket-notification-configuration get-bucket-replication list-access-points get-bucket-policy get-bucket-acl 'glue get-tables' \
    "$LEGACY_PREFIX" fnd-offers-platform-admin fnd-management-admin 'aws cloudtrail delete-trail'; do
    grep -qF -- "$c" "$sec" || echo "TC60 README procedure does not contain '$c'"
  done
  m1=$(grep -nF 'get-bucket-notification-configuration' "$sec" | head -n 1 | cut -d: -f1)
  m2=$(grep -nE 'source=offers-platform-account-trail|Key=source,Value=offers-platform-account-trail' "$sec" | head -n 1 | cut -d: -f1)
  [ -n "$m2" ] || echo "TC60 README copy step does not tag objects source=offers-platform-account-trail"
  m3=""
  [ -z "$m2" ] || m3=$(awk -v s="$m2" 'NR > s && tolower($0) ~ /list-objects-v2|count/ { print NR; exit }' "$sec")
  [ -n "$m2" ] && [ -z "$m3" ] && echo "TC60 README has no count check after the copy"
  m4=$(grep -nF 'aws cloudtrail delete-trail' "$sec" | head -n 1 | cut -d: -f1)
  if [ -n "$m1" ] && [ -n "$m2" ] && [ -n "$m3" ] && [ -n "$m4" ]; then
    [ "$m1" -lt "$m2" ] && [ "$m2" -lt "$m3" ] && [ "$m3" -lt "$m4" ] ||
      echo "TC60 README steps are not in the order: reader checks, copy, count check, delete-trail"
  fi
  grep -Eqi 'old bucket.*(kept|stays|keep|left)|(keep|kept).*old bucket' "$sec" || echo "TC60 README does not say the old bucket is kept"
  return 0
}

# AC11 TC53: 12-digit numbers and e-mail addresses. Reads text on stdin, prints a count.
# The example.com/.net/.org exception applies per match, not per line: the
# "@example.<tld>" part of each placeholder address is removed first (so
# x@example.com.au is not a placeholder), then every line that still holds a
# 12-digit number or an e-mail address is counted. A real ID or address on the
# same line as a placeholder is still counted.
count_sensitive() {
  sed -E 's/@example\.(com|net|org)(\.?)([^A-Za-z0-9.-]|$)/ \2\3/g' |
    { grep -E '(^|[^0-9])[0-9]{12}([^0-9]|$)|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' || true; } | wc -l | tr -d ' '
}

# AC11 TC53: lines added since BASE in non-test, non-docs files that hold a
# 12-digit number or an e-mail address. tests/ and docs/ (deliberate
# placeholders and fixtures) and lock files are not scanned; README.md is.
# ARGS: REPO BASE. Prints a count.
tc53_diff_count() {
  git -C "$1" diff -U0 "$2" HEAD -- . ':(exclude)*.terraform.lock.hcl' ':(exclude)tests/' ':(exclude)docs/' 2>>"$ERRLOG" |
    { grep -E '^\+' || true; } | { grep -vE '^\+\+\+ ' || true; } | count_sensitive
}

# AC11/AC14 TC61. ARGS: STATE_SHOW_JSON MGMT_ID TF_DIR
tc61_eval() {
  local j=$1 m=$2 dir=$3 n
  if [ -z "$j" ] || ! printf '%s' "$j" | jq -e . >/dev/null 2>&1; then
    echo "TC61 guardrails state could not be read"
  else
    n=$(printf '%s' "$j" | jqq -r --arg m "$m" '[.. | objects | select(has("arn")) | .arn | strings | select(test("^arn:")) | split(":")[4] | select(. != "" and . != $m)] | length')
    [ "${n:-1}" = 0 ] || echo "TC61 ${n:-?} resource ARN(s) in guardrails state are outside the management account"
    n=$(printf '%s' "$j" | jqq -r '[.. | objects | select(.type? == "aws_cloudtrail" and .mode? == "managed") | select(.values.is_organization_trail != true)] | length')
    [ "${n:-1}" = 0 ] || echo "TC61 guardrails state holds a trail that is not the organization trail"
  fi
  if ls "$dir"/*.tf >/dev/null 2>&1 && grep -qE '^[[:space:]]*alias[[:space:]]*=' "$dir"/*.tf; then
    echo "TC61 guardrails configures a provider alias (member-account provider)"
  fi
  return 0
}

# tags_eval TAG LABEL TAGS_JSON_ARRAY ([{"Key":..,"Value":..}]); exact keys and values.
tags_eval() {
  local tag=$1 label=$2 j=$3 k v e
  if [ -z "$j" ] || ! printf '%s' "$j" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "$tag $label: tags could not be read"
    return 0
  fi
  for k in $COST_TAG_KEYS; do
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

# REG-TC72: variable and output blocks without a description. ARGS: FILE...
tf_desc_eval() {
  awk '
    function report() { if (blk != "" && !desc) print "REG-TC72 " blk " in " FILENAME " has no description"; blk = ""; desc = 0 }
    FNR == 1 { if (blk != "") report(); depth = 0 }
    blk == "" && /^(variable|output)[[:space:]]+"[^"]+"[[:space:]]*\{/ {
      match($0, /"[^"]+"/); blk = $1 " " substr($0, RSTART + 1, RLENGTH - 2); desc = 0; depth = 0
    }
    blk != "" {
      if (depth == 1 && $0 ~ /^[[:space:]]*description[[:space:]]*=/) desc = 1
      line = $0; o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line); depth += o - c
      if (depth == 1 && $0 ~ /^[[:space:]]*description[[:space:]]*=/) desc = 1
      if (depth <= 0) report()
    }' "$@" 2>/dev/null
}

# ---------------------------------------------------------------- discovery

discover() {
  local p
  for p in $ALL_PROFILES; do caller_json "$p" >/dev/null || log "profile $p: sts get-caller-identity failed"; done
  ACCT_MGMT=$(caller_account "$P_MGMT")
  ACCT_ABC=$(caller_account "$P_ABC_ADMIN")
  ACCT_OP=$(caller_account "$P_OP_ADMIN")
  ALERT_EMAIL=$(read_alert_email)
  POSTURE=$(read_posture)
  [ -n "$ALERT_EMAIL" ] || log "alert e-mail unknown: set FND4_ALERT_EMAIL or alert_email in guardrails/terraform.tfvars"
  [ -d "$BASELINE" ] || log "baseline directory not found (FND4_BASELINE_DIR)"

  ORG_ID=$(awsp "$P_MGMT" organizations describe-organization --query Organization.Id --output text) || ORG_ID=""
  [ "$ORG_ID" != None ] || ORG_ID=""

  local inst
  if inst=$(awsp "$P_MGMT" sso-admin list-instances --output json); then
    SSO_INSTANCE_ARN=$(printf '%s' "$inst" | jqq -r 'if (.Instances | length) == 1 then .Instances[0].InstanceArn else empty end') || SSO_INSTANCE_ARN=""
  fi
  ROLE_ABC_ADMIN=$(find_sso_role "$P_ABC_ADMIN" "$PS_ADMIN_NAME")
  ROLE_OP_ADMIN=$(find_sso_role "$P_OP_ADMIN" "$PS_ADMIN_NAME")

  setup_clone

  awsp "$P_MGMT" s3api list-buckets --query 'Buckets[].Name' --output json >"$WORK/mgmt-buckets.json" || : >"$WORK/mgmt-buckets.json"
  BUDGET_NAME=$(tf_out guardrails budget_name)
  [ -n "$BUDGET_NAME" ] || BUDGET_NAME=$DEFAULT_BUDGET_NAME
  discover_trail
  return 0
}

discover_trail() {
  local t pick
  : >"$WORK/trail-status.json"
  t=$(awsp "$P_MGMT" cloudtrail describe-trails --include-shadow-trails --output json) || { log "describe-trails failed (management)"; t=""; }
  printf '%s' "$t" >"$WORK/trails.mgmt.json"
  pick=$(pick_org_trail "$t" "$(tf_out guardrails trail_arn)")
  [ -n "$pick" ] || { log "no organization trail found in the management account"; return 0; }
  TRAIL_ARN=$(printf '%s' "$pick" | jqq -r '.TrailARN // empty')
  TRAIL_BUCKET=$(printf '%s' "$pick" | jqq -r '.S3BucketName // empty')
  TRAIL_KEY_PREFIX=$(printf '%s' "$pick" | jqq -r '(.S3KeyPrefix // "") | if . == "" then "" else . + "/" end')
  [ -z "$TRAIL_ARN" ] || awsp "$P_MGMT" cloudtrail get-trail-status --name "$TRAIL_ARN" --output json >"$WORK/trail-status.json" || : >"$WORK/trail-status.json"
}

# Fresh clone of the committed branch, then init, state list and outputs per root.
setup_clone() {
  local branch src root name
  src=${FND4_CLONE_SOURCE:-$REPO_DIR}
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
    tf_root "$name" init -input=false -no-color >>"$ERRLOG" 2>&1 || log "terraform init failed in $name"
    tf_root "$name" state list >"$WORK/state.$name" 2>>"$ERRLOG" || : >"$WORK/state.$name"
    tf_root "$name" output -json >"$WORK/tfout.$name.json" 2>>"$ERRLOG" || : >"$WORK/tfout.$name.json"
  done
  has_root guardrails || log "guardrails root not found in the clone"
  return 0
}

# ---------------------------------------------------------------- AC7 / TC30 event phase
# Runs once in the main shell before the result lines. Creates the AC7 test
# bucket only when an organization trail exists and is logging.

events_phase() {
  : >"$WORK/ev.found"
  : >"$WORK/ev.notes.ac6"
  : >"$WORK/ev.notes.ac7"
  : >"$WORK/ev.seen-keys"
  if [ -z "$TRAIL_ARN" ] || [ -z "$TRAIL_BUCKET" ]; then
    EV_SKIP="no organization trail found, so the test bucket was not created"
  elif [ "$(jqq -r '.IsLogging // false' "$WORK/trail-status.json" 2>/dev/null || true)" != true ]; then
    EV_SKIP="the organization trail is not logging, so the test bucket was not created"
  elif [ -z "$ORG_ID" ] || [ -z "$ACCT_MGMT" ] || [ -z "$ACCT_ABC" ] || [ -z "$ACCT_OP" ]; then
    EV_SKIP="organization or account IDs unknown, so the test bucket was not created"
  fi
  [ -z "$EV_SKIP" ] || { log "AC7/TC30: $EV_SKIP"; return 0; }

  EV_START=$(now_epoch)
  local p
  for p in "$P_MGMT" "$P_ABC_ADMIN" "$P_OP_ADMIN"; do
    awsp "$p" s3api list-buckets --query 'length(Buckets)' --output text >/dev/null ||
      echo "TC30 list-buckets failed for profile $p" >>"$WORK/ev.notes.ac6"
  done
  EV_LIST_AT=$(now_epoch)

  TEST_BUCKET="$TEST_BUCKET_PREFIX$(rand_suffix)"
  log "AC7: creating and deleting test bucket $TEST_BUCKET in ABC Bank ($REGION)"
  if awsp "$P_ABC_ADMIN" s3api create-bucket --bucket "$TEST_BUCKET" --output json >/dev/null; then
    TEST_BUCKET_CREATED=1
    awsp "$P_ABC_ADMIN" s3api put-bucket-tagging --bucket "$TEST_BUCKET" --tagging "$(cost_tagset_json)" >/dev/null ||
      echo "TC26 the cost tags could not be put on the test bucket" >>"$WORK/ev.notes.ac7"
    if awsp "$P_ABC_ADMIN" s3api delete-bucket --bucket "$TEST_BUCKET" >/dev/null; then
      TEST_BUCKET_DELETED=1
    else
      echo "TC28 delete-bucket failed straight after create (retried on exit)" >>"$WORK/ev.notes.ac7"
    fi
    EV_DELETE_AT=$(now_epoch)
  else
    echo "TC26 create-bucket failed in ABC Bank" >>"$WORK/ev.notes.ac7"
  fi
  poll_events
  EV_HEAD=$(head_bucket_state)
  return 0
}

events_complete() {
  local a
  for a in "$ACCT_MGMT" "$ACCT_ABC" "$ACCT_OP"; do
    awk -F'\t' -v a="$a" '$1 == "ListBuckets" && $2 == a { f = 1 } END { exit !f }' "$WORK/ev.found" || return 1
  done
  [ "$TEST_BUCKET_CREATED" = 1 ] || return 0
  grep -q '^CreateBucket' "$WORK/ev.found" && grep -q '^DeleteBucket' "$WORK/ev.found"
}

poll_events() {
  local deadline now a
  deadline=$((${EV_DELETE_AT:-$EV_LIST_AT} + EVENT_WINDOW))
  [ $((EV_LIST_AT + EVENT_WINDOW)) -le "$deadline" ] || deadline=$((EV_LIST_AT + EVENT_WINDOW))
  while :; do
    now=$(now_epoch)
    for a in "$ACCT_MGMT" "$ACCT_ABC" "$ACCT_OP"; do scan_account_logs "$a" "$now"; done
    events_complete && break
    [ "$now" -le "$deadline" ] || break
    log "AC7/TC30: waiting for events ($(mmss $((now - EV_START))) elapsed)"
    poll_sleep "$POLL_INTERVAL"
  done
  return 0
}

# scan_account_logs ACCOUNT NOW: reads new log files for ACCOUNT in us-east-1
# and records matching events as "event<TAB>recipient<TAB>arn<TAB>seen_epoch",
# where seen_epoch is the log file's LastModified.
scan_account_logs() {
  local acct=$1 now=$2 since start_iso d prefix keys key lm seen
  since=$((EV_START - 300))
  start_iso=$(fmt_epoch $((EV_START - 60)) '%Y-%m-%dT%H:%M:%SZ')
  for d in $(printf '%s\n%s\n' "$(fmt_epoch "$EV_START" %Y/%m/%d)" "$(fmt_epoch "$now" %Y/%m/%d)" | sort -u); do
    prefix="${TRAIL_KEY_PREFIX}AWSLogs/$ORG_ID/$acct/CloudTrail/$REGION/$d/"
    keys=$(awsp "$P_MGMT" s3api list-objects-v2 --bucket "$TRAIL_BUCKET" --prefix "$prefix" \
      --query 'Contents[].[Key,LastModified]' --output json |
      jqq -r --argjson since "$since" "$JQ_LIB"'.[]? | select((.[1] | to_epoch // 0) >= $since) | @tsv') || continue
    while IFS="$(printf '\t')" read -r key lm; do
      [ -n "$key" ] && [ "$key" != None ] || continue
      grep -qxF -- "$key" "$WORK/ev.seen-keys" && continue
      printf '%s\n' "$key" >>"$WORK/ev.seen-keys"
      seen=$(to_epoch "$lm")
      [ -n "$seen" ] || seen=$now
      awsp "$P_MGMT" s3 cp "s3://$TRAIL_BUCKET/$key" "$WORK/obj.json.gz" --only-show-errors >/dev/null || continue
      gzip -dc "$WORK/obj.json.gz" 2>>"$ERRLOG" | jqq -r --arg b "$TEST_BUCKET" --arg s "$start_iso" --arg seen "$seen" '
        .Records[]?
        | select(((.eventName == "CreateBucket" or .eventName == "DeleteBucket") and $b != "" and .requestParameters.bucketName == $b)
                 or (.eventName == "ListBuckets" and (.eventTime // "") >= $s))
        | [.eventName, (.recipientAccountId // ""), (.userIdentity.arn // ""), $seen] | @tsv' >>"$WORK/ev.found" || true
      rm -f "$WORK/obj.json.gz"
    done <<EOF
$keys
EOF
  done
}

# head_bucket_state: 404, exists, or an error description.
head_bucket_state() {
  [ -n "$TEST_BUCKET" ] && [ "$TEST_BUCKET_CREATED" = 1 ] || { echo ""; return 0; }
  if aws_capture "$P_ABC_ADMIN" "$REGION" s3api head-bucket --bucket "$TEST_BUCKET"; then
    echo exists
  elif grep -Eq '404|Not Found|NoSuchBucket' "$WORK/cap.err"; then
    echo 404
  elif grep -Eq '403|Forbidden' "$WORK/cap.err"; then
    echo "403: the name exists in another account"
  else
    echo "head-bucket error"
  fi
}

# first_event EVENT: "seen<TAB>recipient<TAB>arn" of the earliest record.
first_event() {
  awk -F'\t' -v e="$1" '$1 == e { print $4 "\t" $2 "\t" $3 }' "$WORK/ev.found" 2>/dev/null | sort -n | head -n 1
}

# ---------------------------------------------------------------- AC checks
# Each prints problem lines (or "@MANUAL <text>") on stdout.

mgmt_budgets() {
  local f="$WORK/budgets.mgmt.json"
  if [ ! -s "$f" ]; then
    [ -n "$ACCT_MGMT" ] || return 1
    awsp "$P_MGMT" budgets describe-budgets --account-id "$ACCT_MGMT" --output json >"$f" || { rm -f "$f"; return 1; }
  fi
  cat "$f"
}

# org_budget_json BUDGETS_JSON: the organization budget (by name, else the single COST budget).
org_budget_json() {
  printf '%s' "$1" | jqq -c --arg n "$BUDGET_NAME" '
    ([.Budgets[]? | select(.BudgetName == $n)] | .[0]) // ([.Budgets[]? | select(.BudgetType == "COST")] | if length == 1 then .[0] else empty end) // empty' || true
}

live_limit() {
  local b
  b=$(mgmt_budgets) || return 0
  org_budget_json "$b" | jqq -r '.BudgetLimit.Amount // empty' || true
}

check_ac1() {
  local b ob name n s th notif
  [ -n "$ACCT_MGMT" ] || { echo "TC01 management account ID unknown (profile $P_MGMT)"; return 0; }
  b=$(mgmt_budgets) || { echo "TC01 describe-budgets failed (management profile)"; return 0; }
  ac1_budgets_eval "$b"
  ob=$(org_budget_json "$b")
  name=$(printf '%s' "$ob" | jqq -r '.BudgetName // empty')
  [ -n "$name" ] || return 0
  n=$(awsp "$P_MGMT" budgets describe-notifications-for-budget --account-id "$ACCT_MGMT" --budget-name "$name" --output json) ||
    { echo "TC02 describe-notifications-for-budget failed"; return 0; }
  ac1_notifications_eval "$n"
  [ -n "$ALERT_EMAIL" ] || echo "TC03 alert e-mail unknown (set FND4_ALERT_EMAIL or alert_email in guardrails/terraform.tfvars)"
  while IFS= read -r notif; do
    [ -n "$notif" ] || continue
    th=$(printf '%s' "$notif" | jqq -r '.Threshold')
    s=$(awsp "$P_MGMT" budgets describe-subscribers-for-notification --account-id "$ACCT_MGMT" --budget-name "$name" \
      --notification "$notif" --output json) || { echo "TC03 describe-subscribers-for-notification failed ($th%)"; continue; }
    ac1_subscribers_eval "$s" "$ALERT_EMAIL" "$th"
  done <<EOF
$(printf '%s' "$n" | jqq -c '.Notifications[]? | del(.NotificationState)')
EOF
}

check_ac2() {
  has_root guardrails || { echo "TC05 guardrails root missing, nothing to plan"; return 0; }
  local rc plan="$WORK/plan.working.tfplan" json v log live
  rc=0
  tf_root guardrails plan -detailed-exitcode -input=false -no-color -lock-timeout=60s $(varfile_args guardrails) \
    -var posture=working -out "$plan" >"$WORK/plan.working.log" 2>&1 || rc=$?
  if [ $rc = 2 ]; then
    json=$(tf_root guardrails show -json -no-color "$plan" 2>>"$ERRLOG") || json=""
    ac2_plan_eval "$json"
  else
    echo "TC05 plan with posture=working exited $rc, expected 2 (changes)"
  fi
  rm -f "$plan"
  [ ! -e "$plan" ] || echo "TC05 scratch plan file was not deleted"

  rc=$(tf_plan_default_rc)
  [ "$rc" = 0 ] || echo "TC07 plan with no posture set exited $rc, expected 0"
  rc=0
  tf_root guardrails plan -detailed-exitcode -input=false -no-color -lock-timeout=60s $(varfile_args guardrails) \
    -var posture=lean >"$WORK/plan.lean.log" 2>&1 || rc=$?
  [ $rc = 0 ] || echo "TC07 plan with posture=lean exited $rc, expected 0"

  for v in Heavy "" Working; do
    log="$WORK/plan.invalid.log"
    rc=0
    tf_root guardrails plan -input=false -no-color -lock-timeout=60s $(varfile_args guardrails) \
      -var "posture=$v" >"$log" 2>&1 || rc=$?
    ac2_invalid_eval "$v" "$rc" "$log"
  done

  live=$(live_limit)
  if [ -z "$live" ]; then
    echo "TC07 live budget limit unknown"
  elif ! num_eq "$live" 100; then
    echo "TC07 live budget limit is $live, expected 100"
  fi
}

check_ac3() {
  local start end mtd
  start=$(fmt_epoch "$(now_epoch)" %Y-%m-01)
  end=$(fmt_epoch $(($(now_epoch) + 86400)) %Y-%m-%d)
  mtd=$(awsp "$P_MGMT" ce get-cost-and-usage --time-period "Start=$start,End=$end" --granularity MONTHLY \
    --metrics UnblendedCost --output json | jqq -r '[.ResultsByTime[]?.Total.UnblendedCost.Amount | tonumber] | if length == 0 then empty else add end') || mtd=""
  ac3_eval "$mtd" "$(live_limit)" "$POSTURE" "$(tf_plan_default_rc)"
}

check_ac4() {
  local mon subs arn
  mon=$(awsp "$P_MGMT" ce get-anomaly-monitors --output json) || { echo "TC12 get-anomaly-monitors failed"; mon='{}'; }
  ac4_monitors_eval "$mon"
  printf '%s' "$mon" | jqq -r '.AnomalyMonitors[]? | select((.MonitorType == "DIMENSIONAL" and .MonitorDimension == "SERVICE") | not)
    | "  other monitor (left alone, list in the PR): \(.MonitorName) \(.MonitorType) \(.MonitorDimension // "")"' | while IFS= read -r l; do log "$l"; done
  arn=$(service_monitor_arn "$mon")
  subs=$(awsp "$P_MGMT" ce get-anomaly-subscriptions --output json) || { echo "TC13 get-anomaly-subscriptions failed"; subs='{}'; }
  [ -n "$ALERT_EMAIL" ] || echo "TC13 alert e-mail unknown (set FND4_ALERT_EMAIL or alert_email in guardrails/terraform.tfvars)"
  if [ -n "$arn" ]; then
    ac4_subscriptions_eval "$subs" "$arn" "$ALERT_EMAIL"
  else
    echo "TC13 no single service monitor, so its subscription cannot be checked"
  fi
  printf '%s' "$subs" | jqq -r --arg m "$arn" '.AnomalySubscriptions[]? | select(any((.MonitorArnList // [])[]; . == $m) | not)
    | "  other subscription (left alone, list in the PR): \(.SubscriptionName)"' | while IFS= read -r l; do log "$l"; done

  # TC14: imported, not replaced; non-service baseline monitors unchanged.
  local norm_m='{MonitorArn, MonitorName, MonitorType, MonitorDimension, MonitorSpecification}'
  if ! baseline_ok mgmt-anomaly-monitors.json; then
    echo "TC14 baseline missing or unreadable (mgmt-anomaly-monitors.json)"
  else
    local bsvc state_arn o oa live
    bsvc=$(jqq -r '[.. | objects | select(has("MonitorArn") and .MonitorType == "DIMENSIONAL" and .MonitorDimension == "SERVICE") | .MonitorArn] | unique | .[]' \
      "$BASELINE/mgmt-anomaly-monitors.json")
    state_arn=$(tf_out guardrails anomaly_monitor_arn)
    grep -q '^aws_ce_anomaly_monitor\.' "$WORK/state.guardrails" 2>/dev/null || echo "TC14 no anomaly monitor in guardrails Terraform state"
    if [ -n "$arn" ]; then
      [ -n "$state_arn" ] && [ "$state_arn" = "$arn" ] || echo "TC14 the service monitor is not the one Terraform manages"
      if [ -n "$bsvc" ] && ! printf '%s\n' "$bsvc" | grep -qxF -- "$arn"; then
        echo "TC14 the baseline service monitor was replaced, not imported"
      fi
    fi
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      oa=$(printf '%s' "$o" | jqq -r '.MonitorArn')
      printf '%s\n' "$bsvc" | grep -qxF -- "$oa" && continue
      live=$(printf '%s' "$mon" | jqq -S -c --arg a "$oa" ".AnomalyMonitors[]? | select(.MonitorArn == \$a) | $norm_m")
      if [ -z "$live" ]; then
        echo "TC14 baseline monitor $(printf '%s' "$o" | jqq -r '.MonitorName') no longer exists"
      elif [ "$live" != "$(printf '%s' "$o" | jqq -S -c "$norm_m")" ]; then
        echo "TC14 baseline monitor $(printf '%s' "$o" | jqq -r '.MonitorName') changed"
      fi
    done <<EOF
$(baseline_objects mgmt-anomaly-monitors.json MonitorArn)
EOF
  fi

  # TC15: baseline subscriptions not on the service monitor still exist, unchanged.
  local norm_s='{SubscriptionArn, SubscriptionName, MonitorArnList: ((.MonitorArnList // []) | sort), Frequency, Subscribers: ((.Subscribers // []) | map({Address, Type}) | sort_by(.Address)), Threshold, ThresholdExpression}'
  if ! baseline_ok mgmt-anomaly-subscriptions.json; then
    echo "TC15 baseline missing or unreadable (mgmt-anomaly-subscriptions.json)"
  else
    local s sa sm on_svc b
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      sa=$(printf '%s' "$s" | jqq -r '.SubscriptionArn')
      on_svc=0
      for sm in $(printf '%s' "$s" | jqq -r '(.MonitorArnList // [])[]'); do
        { [ -n "$arn" ] && [ "$sm" = "$arn" ]; } && on_svc=1
        if baseline_ok mgmt-anomaly-monitors.json; then
          printf '%s\n' "${bsvc:-}" | grep -qxF -- "$sm" && on_svc=1
        fi
      done
      [ $on_svc = 0 ] || continue
      b=$(printf '%s' "$subs" | jqq -S -c --arg a "$sa" ".AnomalySubscriptions[]? | select(.SubscriptionArn == \$a) | $norm_s")
      if [ -z "$b" ]; then
        echo "TC15 baseline subscription $(printf '%s' "$s" | jqq -r '.SubscriptionName') no longer exists"
      elif [ "$b" != "$(printf '%s' "$s" | jqq -S -c "$norm_s")" ]; then
        echo "TC15 baseline subscription $(printf '%s' "$s" | jqq -r '.SubscriptionName') changed"
      fi
    done <<EOF
$(baseline_objects mgmt-anomaly-subscriptions.json SubscriptionArn)
EOF
  fi
}

check_ac5() {
  local j
  # shellcheck disable=SC2086
  j=$(awsp "$P_MGMT" ce list-cost-allocation-tags --tag-keys $COST_TAG_KEYS --output json) || { echo "TC17 list-cost-allocation-tags failed"; return 0; }
  ac5_eval "$j"
}

check_ac6() {
  local t sel r d
  t=$(cat "$WORK/trails.mgmt.json" 2>/dev/null || true)
  [ -n "$t" ] || { echo "TC19 describe-trails failed (management profile)"; t='{}'; }
  ac6_trail_eval "$t" "$ACCT_MGMT" "$(cat "$WORK/mgmt-buckets.json" 2>/dev/null || true)"
  if [ -z "$TRAIL_ARN" ]; then
    echo "TC20 no organization trail, selectors and status not checked"
  else
    sel=$(awsp "$P_MGMT" cloudtrail get-event-selectors --trail-name "$TRAIL_ARN" --output json) || sel=""
    [ -n "$sel" ] || echo "TC20 get-event-selectors failed"
    [ -z "$sel" ] || ac6_selectors_eval "$sel"
    if [ -s "$WORK/trail-status.json" ]; then
      ac6_status_eval "$(cat "$WORK/trail-status.json")" "$(now_epoch)"
    else
      echo "TC21 get-trail-status failed"
    fi
    for r in $OTHER_REGIONS; do
      d=$(awsr "$P_MGMT" "$r" cloudtrail describe-trails --include-shadow-trails --output json) || { echo "TC22 describe-trails failed in $r"; continue; }
      printf '%s' "$d" | jqq -e --arg a "$TRAIL_ARN" 'any(.trailList[]?; .TrailARN == $a and .HomeRegion == "us-east-1")' >/dev/null ||
        echo "TC22 organization trail not listed in $r with home region us-east-1"
      [ "$(awsr "$P_MGMT" "$r" cloudtrail get-trail-status --name "$TRAIL_ARN" --query IsLogging --output text || true)" = True ] ||
        echo "TC22 organization trail is not logging as seen from $r"
    done
  fi
  cat "$WORK/ev.notes.ac6" 2>/dev/null || true
  ac6_reads_eval "$EV_SKIP" "${EV_LIST_AT:-0}" "$WORK/ev.found" "$ACCT_MGMT" "$ACCT_ABC" "$ACCT_OP"
}

check_ac7() {
  local c d cs cr ca ds dr da
  cat "$WORK/ev.notes.ac7" 2>/dev/null || true
  c=$(first_event CreateBucket)
  d=$(first_event DeleteBucket)
  IFS="$(printf '\t')" read -r cs cr ca <<EOF
$c
EOF
  IFS="$(printf '\t')" read -r ds dr da <<EOF
$d
EOF
  ac7_eval "$EV_SKIP" "$TEST_BUCKET_CREATED" "${EV_DELETE_AT:-0}" "$cs" "$cr" "$ca" "$ds" "$dr" "$da" "$ACCT_ABC" "$EV_HEAD"
}

check_ac8() {
  [ -n "$TRAIL_ARN" ] || { echo "TC31 no organization trail"; return 0; }
  local start now hs s e out rc label acct req
  start=$(jqq -r "$JQ_LIB"'.StartLoggingTime // null | to_epoch // empty' "$WORK/trail-status.json" 2>/dev/null || true)
  [ -n "$start" ] || { echo "TC31 StartLoggingTime unknown"; return 0; }
  now=$(now_epoch)
  if [ $((now - start)) -lt 7200 ]; then
    echo "@MANUAL the trail started logging less than 2 hours ago: rerun after $(iso_of $((start + 7200))) (TC32)"
    return 0
  fi
  hs=$(((now / 3600) * 3600 - 3600))
  s=$(iso_of "$hs")
  e=$(iso_of $((hs + 3599)))
  for label in management abc_bank offers_platform; do
    case $label in management) acct=$ACCT_MGMT req=yes ;; abc_bank) acct=$ACCT_ABC req=no ;; *) acct=$ACCT_OP req=no ;; esac
    if [ -z "$acct" ]; then
      echo "TC31 $label account ID unknown"
      continue
    fi
    rc=0
    out=$(awsp "$P_MGMT" cloudtrail validate-logs --trail-arn "$TRAIL_ARN" --start-time "$s" --end-time "$e" --account-id "$acct" 2>&1) || rc=$?
    printf '%s\n' "$out" >>"$ERRLOG"
    ac8_validate_eval "$out" "$rc" "$label" "$req"
  done
}

check_ac9() {
  [ -n "$TRAIL_BUCKET" ] || { echo "TC34 trail bucket unknown (no organization trail)"; return 0; }
  local b=$TRAIL_BUCKET pol tfb
  tfb=$(tf_out guardrails trail_bucket_name)
  [ -n "$tfb" ] && [ "$tfb" = "$b" ] || echo "TC40 trail bucket differs from the Terraform output (or output missing)"
  ac9_versioning_eval "$(awsp "$P_MGMT" s3api get-bucket-versioning --bucket "$b" --output json || true)"
  ac9_pab_eval "$(awsp "$P_MGMT" s3api get-public-access-block --bucket "$b" --output json || true)"
  pol=$(awsp "$P_MGMT" s3api get-bucket-policy --bucket "$b" --query Policy --output text || true)
  [ -n "$pol" ] || { echo "TC35 bucket policy could not be read"; pol='{}'; }
  ac9_public_eval "$(awsp "$P_MGMT" s3api get-bucket-policy-status --bucket "$b" --output json || true)" \
    "$(awsp "$P_MGMT" s3api get-bucket-acl --bucket "$b" --output json || true)" "$pol"
  ac9_encryption_eval "$(awsp "$P_MGMT" s3api get-bucket-encryption --bucket "$b" --output json || true)"
  ac9_lifecycle_eval "$(awsp "$P_MGMT" s3api get-bucket-lifecycle-configuration --bucket "$b" --output json || true)"
  ac9_location_eval "$(awsp "$P_MGMT" s3api get-bucket-location --bucket "$b" --output json || true)"
  jqq -e --arg b "$b" 'any(.[]?; . == $b)' "$WORK/mgmt-buckets.json" >/dev/null 2>&1 || echo "TC40 trail bucket is not owned by the management account"
}

check_ac10() {
  local label p acct d rc err j allowed limit
  limit=$(live_limit)
  for label in abc_bank offers_platform; do
    case $label in abc_bank) p=$P_ABC_ADMIN acct=$ACCT_ABC ;; *) p=$P_OP_ADMIN acct=$ACCT_OP ;; esac
    d=$(awsp "$p" cloudtrail describe-trails --include-shadow-trails --output json) || { echo "TC41 $label: describe-trails failed"; d='{}'; }
    ac10_trail_eval "$d" "$ACCT_MGMT" "$TRAIL_ARN" "$label"
    [ -n "$acct" ] || { echo "TC42 $label account ID unknown"; continue; }
    rc=0
    aws_capture "$p" "$REGION" budgets describe-budgets --account-id "$acct" --output json || rc=$?
    j=$(cat "$WORK/cap.out")
    err=$(cat "$WORK/cap.err")
    allowed='[]'
    if [ $label = offers_platform ] && baseline_ok op-budgets.json; then
      allowed=$(jqq -c '[.. | objects | select(has("BudgetName")) | .BudgetName] | unique' "$BASELINE/op-budgets.json") || allowed='[]'
    fi
    ac10_budgets_eval "$rc" "$err" "$j" "$BUDGET_NAME" "$limit" "$allowed" "$label"
  done

  # TC44: no-op update-trail from ABC Bank must be refused; trail unchanged and logging.
  if [ -z "$TRAIL_ARN" ]; then
    echo "TC44 no organization trail, member change check not run"
  else
    local before after val
    before=$(awsp "$P_MGMT" cloudtrail get-trail --name "$TRAIL_ARN" --output json | jqq -S -c '.Trail') || before=""
    val=$(printf '%s' "$before" | jqq -r '.LogFileValidationEnabled // false' || true)
    if [ -z "$before" ]; then
      echo "TC44 get-trail failed, member change check not run"
    elif [ "$val" != true ]; then
      echo "TC44 log file validation is off today, so update-trail would not be a no-op; not run"
    else
      if aws_capture "$P_ABC_ADMIN" "$REGION" cloudtrail update-trail --name "$TRAIL_ARN" --enable-log-file-validation --output json; then
        echo "TC44 ABC Bank administrator could call update-trail on the organization trail"
      fi
      after=$(awsp "$P_MGMT" cloudtrail get-trail --name "$TRAIL_ARN" --output json | jqq -S -c '.Trail') || after=""
      [ "$after" = "$before" ] || echo "TC44 organization trail changed after the member call"
      [ "$(awsp "$P_MGMT" cloudtrail get-trail-status --name "$TRAIL_ARN" --query IsLogging --output text || true)" = True ] ||
        echo "TC44 organization trail is not logging after the member call"
    fi
  fi

  # TC45: simulator and real read calls against the trail bucket.
  if [ -z "$TRAIL_BUCKET" ] || [ -z "$ACCT_MGMT" ]; then
    echo "TC45 trail bucket or management account unknown"
  else
    local pol ctx role prof
    pol=$(awsp "$P_MGMT" s3api get-bucket-policy --bucket "$TRAIL_BUCKET" --query Policy --output text) || pol=""
    [ -n "$pol" ] || echo "TC45 trail bucket policy could not be read"
    ctx='[{"ContextKeyName":"aws:SecureTransport","ContextKeyValues":["true"],"ContextKeyType":"boolean"}]'
    for label in abc_bank offers_platform; do
      case $label in abc_bank) role=$ROLE_ABC_ADMIN prof=$P_ABC_ADMIN ;; *) role=$ROLE_OP_ADMIN prof=$P_OP_ADMIN ;; esac
      [ -n "$pol" ] || continue
      SIM_RESOURCE_POLICY=$pol SIM_RESOURCE_OWNER="arn:aws:iam::$ACCT_MGMT:root" \
        expect_sim denied "TC45 $label bucket" principal "$prof" "$role" "arn:aws:s3:::$TRAIL_BUCKET" "$ctx" \
        s3:PutBucketPolicy s3:PutLifecycleConfiguration s3:PutBucketVersioning
      SIM_RESOURCE_POLICY=$pol SIM_RESOURCE_OWNER="arn:aws:iam::$ACCT_MGMT:root" \
        expect_sim denied "TC45 $label objects" principal "$prof" "$role" "arn:aws:s3:::$TRAIL_BUCKET/AWSLogs/fnd4-sim" "$ctx" \
        s3:DeleteObject s3:DeleteObjectVersion s3:PutObject s3:GetObject
    done
    if aws_capture "$P_ABC_ADMIN" "$REGION" s3api list-objects-v2 --bucket "$TRAIL_BUCKET" --max-keys 1 --output json; then
      echo "TC45 ABC Bank administrator can list the trail bucket"
    elif ! grep -q 'AccessDenied' "$WORK/cap.err"; then
      echo "TC45 list-objects-v2 from ABC Bank failed without AccessDenied (inconclusive)"
    fi
    if aws_capture "$P_ABC_ADMIN" "$REGION" s3api get-bucket-lifecycle-configuration --bucket "$TRAIL_BUCKET" --output json; then
      echo "TC45 ABC Bank administrator can read the trail bucket lifecycle"
    elif ! grep -q 'AccessDenied' "$WORK/cap.err"; then
      echo "TC45 get-bucket-lifecycle-configuration from ABC Bank failed without AccessDenied (inconclusive)"
    fi
  fi

  # TC46: only the Administrator permission set is assigned in the management account.
  if [ -z "$SSO_INSTANCE_ARN" ] || [ -z "$ACCT_MGMT" ]; then
    echo "TC46 Identity Center instance or management account unknown"
  else
    local ps name n admin_n=0
    for ps in $(awsp "$P_MGMT" sso-admin list-permission-sets --instance-arn "$SSO_INSTANCE_ARN" --query 'PermissionSets[]' --output text || true); do
      [ "$ps" != None ] || continue
      name=$(awsp "$P_MGMT" sso-admin describe-permission-set --instance-arn "$SSO_INSTANCE_ARN" --permission-set-arn "$ps" \
        --query PermissionSet.Name --output text) || name=""
      n=$(awsp "$P_MGMT" sso-admin list-account-assignments --instance-arn "$SSO_INSTANCE_ARN" --account-id "$ACCT_MGMT" \
        --permission-set-arn "$ps" --query 'length(AccountAssignments)' --output text) || { echo "TC46 list-account-assignments failed (${name:-?})"; continue; }
      if [ "$name" = "$PS_ADMIN_NAME" ]; then
        admin_n=$n
      elif [ "${n:-0}" != 0 ]; then
        echo "TC46 permission set ${name:-?} is assigned in the management account"
      fi
    done
    [ "${admin_n:-0}" != 0 ] || echo "TC46 Administrator is not assigned in the management account"
  fi
}

# Baseline Offers Platform trails as JSON lines:
# {"arn","name","region","trail":{..},"selectors":{..}|null,"insights":{..}|null,"status":{..}|null}
baseline_op_trails() {
  jqq -c '
    [.. | objects | select(has("TrailARN"))] as $o
    | ([$o[] | select(has("S3BucketName") or has("Name")) | .TrailARN] | unique) as $arns
    | $arns[] as $a
    | [$o[] | select(.TrailARN == $a)] as $mine
    | ([$mine[] | select(has("S3BucketName"))] | .[0]) as $t
    | {
        arn: $a,
        name: ($t.Name // ($a | split("/") | last)),
        region: ($t.HomeRegion // ($a | split(":")[3])),
        trail: $t,
        selectors: ([$mine[] | (., (.[]? | objects)) | select(has("EventSelectors") or has("AdvancedEventSelectors"))] | .[0]),
        insights: ([$mine[] | (., (.[]? | objects)) | select(has("InsightSelectors"))] | .[0]),
        status: ([$mine[] | (., (.[]? | objects)) | select(has("IsLogging"))] | .[0])
      }' "$BASELINE/op-trails.json"
}

TRAIL_NORM='{Name, S3BucketName, S3KeyPrefix, IsMultiRegionTrail, IncludeGlobalServiceEvents, LogFileValidationEnabled, CloudWatchLogsLogGroupArn, CloudWatchLogsRoleArn, SnsTopicARN, KmsKeyId, HomeRegion, IsOrganizationTrail}'

check_ac11() {
  [ -n "$ACCT_OP" ] || { echo "TC47 Offers Platform account ID unknown (profile $P_OP_ADMIN)"; return 0; }
  local op=$ACCT_OP regions r tl t arn sel ins kind
  : >"$WORK/op-live-trails.jsonl"

  # TC47: no management-only trail of its own in any enabled region.
  regions=$(awsp "$P_OP_ADMIN" ec2 describe-regions --query 'Regions[].RegionName' --output text) || regions=""
  [ -n "$regions" ] || echo "TC47 describe-regions failed in Offers Platform"
  for r in $regions; do
    tl=$(awsr "$P_OP_ADMIN" "$r" cloudtrail describe-trails --no-include-shadow-trails --output json) || { echo "TC47 describe-trails failed in $r"; continue; }
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      arn=$(printf '%s' "$t" | jqq -r '.TrailARN')
      [ "$(arn_account "$arn")" = "$op" ] || continue
      sel=$(awsr "$P_OP_ADMIN" "$r" cloudtrail get-event-selectors --trail-name "$arn" --output json) || sel=""
      if aws_capture "$P_OP_ADMIN" "$r" cloudtrail get-insight-selectors --trail-name "$arn" --output json; then
        ins=$(cat "$WORK/cap.out")
      elif grep -q 'InsightNotEnabled' "$WORK/cap.err"; then
        ins='{}'
      else
        ins=""
      fi
      kind=$(ac11_trail_kind "$t" "${sel:-null}" "${ins:-null}")
      [ -n "$sel" ] && [ -n "$ins" ] || kind=unknown
      printf '%s' "$t" | jqq -c --arg k "$kind" '. + {fnd4_kind: $k}' >>"$WORK/op-live-trails.jsonl"
      case $kind in
        management-only) echo "TC47 Offers Platform trail $(printf '%s' "$t" | jqq -r '.Name') ($r) records only management events and has no other destination" ;;
        unknown) echo "TC47 Offers Platform trail $(printf '%s' "$t" | jqq -r '.Name') ($r): selectors could not be read" ;;
      esac
    done <<EOF
$(printf '%s' "$tl" | jqq -c '.trailList[]?')
EOF
  done

  # Baseline (TC49 to TC51).
  local missing="" f
  for f in op-trails.json op-budgets.json op-anomaly-monitors.json op-anomaly-subscriptions.json; do
    baseline_ok "$f" || missing="$missing $f"
  done
  [ -z "$missing" ] || echo "TC49 baseline missing or unreadable:$missing"

  local rec=no recf="$BASELINE/legacy-copy.json" removed=""
  if [ -e "$recf" ]; then
    if jq -e 'type == "array" and length > 0 and all(.[]; (.trail_name | type) == "string" and (.source_bucket | type) == "string" and (.source_prefix | type) == "string" and (.object_count | type) == "number" and (.log_count | type) == "number" and (.digest_count | type) == "number")' "$recf" >/dev/null 2>&1; then
      rec=yes
      removed=$(jqq -r '.[].trail_name' "$recf")
    else
      echo "TC56 legacy-copy.json is not a list of {trail_name, source_bucket, source_prefix, object_count, log_count, digest_count}"
    fi
  fi

  local names="$WORK/op-names.tsv" bt name live status_b status_l bkind
  : >"$names"
  if baseline_ok op-trails.json; then
    while IFS= read -r bt; do
      [ -n "$bt" ] || continue
      name=$(printf '%s' "$bt" | jqq -r '.name')
      arn=$(printf '%s' "$bt" | jqq -r '.arn')
      [ "$(arn_account "$arn")" = "$op" ] || continue
      bkind=$(ac11_trail_kind "$(printf '%s' "$bt" | jqq -c '.trail')" "$(printf '%s' "$bt" | jqq -c '.selectors')" "$(printf '%s' "$bt" | jqq -c '.insights // {}')")
      live=$(jqq -c --arg a "$arn" 'select(.TrailARN == $a)' "$WORK/op-live-trails.jsonl" | head -n 1)
      if printf '%s\n' "$removed" | grep -qxF -- "$name"; then
        printf 'trail\t%s\tremoved\n' "$name" >>"$names"
        [ "$bkind" = management-only ] || echo "TC51 trail $name was removed but records more than management events or has another destination"
        continue
      fi
      printf 'trail\t%s\tkept\n' "$name" >>"$names"
      if [ -z "$live" ]; then
        if [ "$bkind" = management-only ]; then
          echo "TC59 baseline trail $name is gone but legacy-copy.json does not record it"
        else
          echo "TC51 trail $name (kept under requirement 7) no longer exists"
        fi
        continue
      fi
      [ "$(printf '%s' "$live" | jqq -S -c "$TRAIL_NORM")" = "$(printf '%s' "$bt" | jqq -S -c ".trail | $TRAIL_NORM")" ] ||
        echo "TC51 trail $name changed since the baseline"
      status_b=$(printf '%s' "$bt" | jqq -r '.status.IsLogging | if . == null then empty else tostring end')
      status_l=$(awsr "$P_OP_ADMIN" "$(printf '%s' "$bt" | jqq -r '.region')" cloudtrail get-trail-status --name "$arn" --query IsLogging --output text | tr 'A-Z' 'a-z' || true)
      [ -z "$status_b" ] || [ "$status_l" = "$status_b" ] || echo "TC51 trail $name logging state changed since the baseline"
    done <<EOF
$(baseline_op_trails)
EOF
  fi
  if baseline_ok op-budgets.json; then
    jqq -r '[.. | objects | select(has("BudgetName")) | .BudgetName] | unique | .[] | "budget\t\(.)\tpresent"' "$BASELINE/op-budgets.json" >>"$names"
  fi
  if baseline_ok op-anomaly-monitors.json; then
    jqq -r '[.. | objects | select(has("MonitorArn")) | .MonitorName] | unique | .[] | "monitor\t\(.)\tpresent"' "$BASELINE/op-anomaly-monitors.json" >>"$names"
  fi

  # TC48/TC49/TC51/TC52/TC60: README section.
  local sec="$WORK/readme-section.md" kept_n
  if [ -n "$CLONE" ] && [ -f "$CLONE/README.md" ]; then
    readme_section "$CLONE/README.md" >"$sec" || : >"$sec"
  else
    : >"$sec"
    echo "TC48 README.md not found in the clone"
  fi
  if [ -z "$missing" ]; then
    ac11_readme_eval "$sec" "$names"
  elif [ ! -s "$sec" ]; then
    echo "TC48 README.md has no '$README_SECTION_RE' section"
  fi
  ac11_procedure_eval "$sec"

  # TC50: budgets, monitors and subscriptions in Offers Platform unchanged.
  local norm_b='del(.CalculatedSpend, .LastUpdatedTime, .HealthStatus) | (if .AutoAdjustData then .AutoAdjustData |= del(.LastAutoAdjustTime) else . end) | (if .BudgetLimit.Amount then .BudgetLimit.Amount |= tonumber else . end)'
  local norm_m='{MonitorArn, MonitorName, MonitorType, MonitorDimension, MonitorSpecification}'
  local norm_s='{SubscriptionArn, SubscriptionName, MonitorArnList: ((.MonitorArnList // []) | sort), Frequency, Subscribers: ((.Subscribers // []) | map({Address, Type}) | sort_by(.Address)), Threshold, ThresholdExpression}'
  local lb lm ls o k
  if baseline_ok op-budgets.json; then
    lb='{}'
    if aws_capture "$P_OP_ADMIN" "$REGION" budgets describe-budgets --account-id "$op" --output json; then
      lb=$(cat "$WORK/cap.out")
    elif ! grep -q NotFoundException "$WORK/cap.err"; then
      echo "TC50 describe-budgets failed in Offers Platform"
    fi
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      k=$(printf '%s' "$o" | jqq -r '.BudgetName')
      live=$(printf '%s' "$lb" | jqq -S -c --arg n "$k" ".Budgets[]? | select(.BudgetName == \$n) | $norm_b")
      if [ -z "$live" ]; then echo "TC50 Offers Platform budget $k no longer exists"
      elif [ "$live" != "$(printf '%s' "$o" | jqq -S -c "$norm_b")" ]; then echo "TC50 Offers Platform budget $k changed"; fi
    done <<EOF
$(baseline_objects op-budgets.json BudgetName)
EOF
  fi
  if baseline_ok op-anomaly-monitors.json; then
    lm=$(awsp "$P_OP_ADMIN" ce get-anomaly-monitors --output json) || { echo "TC50 get-anomaly-monitors failed in Offers Platform"; lm='{}'; }
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      k=$(printf '%s' "$o" | jqq -r '.MonitorArn')
      live=$(printf '%s' "$lm" | jqq -S -c --arg a "$k" ".AnomalyMonitors[]? | select(.MonitorArn == \$a) | $norm_m")
      name=$(printf '%s' "$o" | jqq -r '.MonitorName')
      if [ -z "$live" ]; then echo "TC50 Offers Platform monitor $name no longer exists"
      elif [ "$live" != "$(printf '%s' "$o" | jqq -S -c "$norm_m")" ]; then echo "TC50 Offers Platform monitor $name changed"; fi
    done <<EOF
$(baseline_objects op-anomaly-monitors.json MonitorArn)
EOF
  fi
  if baseline_ok op-anomaly-subscriptions.json; then
    ls=$(awsp "$P_OP_ADMIN" ce get-anomaly-subscriptions --output json) || { echo "TC50 get-anomaly-subscriptions failed in Offers Platform"; ls='{}'; }
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      k=$(printf '%s' "$o" | jqq -r '.SubscriptionArn')
      live=$(printf '%s' "$ls" | jqq -S -c --arg a "$k" ".AnomalySubscriptions[]? | select(.SubscriptionArn == \$a) | $norm_s")
      name=$(printf '%s' "$o" | jqq -r '.SubscriptionName')
      if [ -z "$live" ]; then echo "TC50 Offers Platform subscription $name no longer exists"
      elif [ "$live" != "$(printf '%s' "$o" | jqq -S -c "$norm_s")" ]; then echo "TC50 Offers Platform subscription $name changed"; fi
    done <<EOF
$(baseline_objects op-anomaly-subscriptions.json SubscriptionArn)
EOF
  fi

  # TC53: no account IDs or e-mail addresses in README or the committed diff.
  if [ -n "$CLONE" ]; then
    local base n
    n=0
    [ ! -f "$CLONE/README.md" ] || n=$(count_sensitive <"$CLONE/README.md")
    [ "$n" = 0 ] || echo "TC53 README.md has $n line(s) with a 12-digit number or an e-mail address"
    base=$(git -C "$CLONE" merge-base HEAD origin/main 2>>"$ERRLOG") || base=""
    if [ -z "$base" ]; then
      echo "TC53 main branch not found, committed diff not scanned"
    else
      n=$(tc53_diff_count "$CLONE" "$base")
      [ "$n" = 0 ] || echo "TC53 committed diff adds $n line(s) with a 12-digit number or an e-mail address"
    fi
  fi

  # TC54 to TC59: the legacy copy.
  check_legacy_copy "$rec"

  # TC61.
  tc61_cached

  kept_n=$(awk -F'\t' '$1 == "trail" && $3 == "kept"' "$names" | wc -l | tr -d ' ')
  [ "$kept_n" = 0 ] || echo "@MANUAL $kept_n Offers Platform trail(s) kept under requirement 7: check their monthly cost is in the AC13 figure in the PR (TC52)"
}

# list_keys PROFILE REGION BUCKET PREFIX: every key under PREFIX (paginated by the CLI).
list_keys() {
  awsr "$1" "$2" s3api list-objects-v2 --bucket "$3" --prefix "$4" --query 'Contents[].Key' --output json | jqq -r '.[]?'
}

check_legacy_copy() {
  local rec=$1
  [ -n "$TRAIL_BUCKET" ] || { echo "TC56 trail bucket unknown, legacy copy not checked"; return 0; }
  local dst="$WORK/legacy.dst" n
  if ! list_keys "$P_MGMT" "$REGION" "$TRAIL_BUCKET" "$LEGACY_PREFIX" >"$dst.raw"; then
    echo "TC56 could not list $LEGACY_PREFIX in the trail bucket"
    [ "$rec" = yes ] || ac11_no_record_eval no ""
    return 0
  fi
  if [ "$rec" = no ]; then
    log "AC11: no trail removed (no legacy-copy.json): copy checks not applicable (TC59)"
    ac11_no_record_eval no "$(sed '/^$/d' "$dst.raw" | wc -l | tr -d ' ')"
    return 0
  fi
  sed "s#^$LEGACY_PREFIX##" "$dst.raw" >"$dst"
  local src="$WORK/legacy.src" e b p oc lc dc reg tot_o=0 tot_l=0 tot_d=0 opid=$ACCT_OP
  : >"$src"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    b=$(printf '%s' "$e" | jqq -r '.source_bucket')
    p=$(printf '%s' "$e" | jqq -r '.source_prefix')
    oc=$(printf '%s' "$e" | jqq -r '.object_count')
    lc=$(printf '%s' "$e" | jqq -r '.log_count')
    dc=$(printf '%s' "$e" | jqq -r '.digest_count')
    tot_o=$((tot_o + oc)) tot_l=$((tot_l + lc)) tot_d=$((tot_d + dc))
    # TC55: the old bucket still exists.
    awsp "$P_OP_ADMIN" s3api head-bucket --bucket "$b" >/dev/null || { echo "TC55 an old trail bucket no longer exists (or cannot be read)"; continue; }
    reg=$(awsp "$P_OP_ADMIN" s3api get-bucket-location --bucket "$b" --query LocationConstraint --output text || true)
    case "$reg" in "" | None | null) reg=us-east-1 ;; esac
    # TC54: nothing reads the old bucket.
    ac11_notification_eval "$(awsr "$P_OP_ADMIN" "$reg" s3api get-bucket-notification-configuration --bucket "$b" --output json || echo '{"x":1}')"
    if aws_capture "$P_OP_ADMIN" "$reg" s3api get-bucket-replication --bucket "$b" --output json; then
      echo "TC54 old bucket has a replication rule"
    elif ! grep -q ReplicationConfigurationNotFoundError "$WORK/cap.err"; then
      echo "TC54 get-bucket-replication failed (inconclusive)"
    fi
    n=$(awsr "$P_OP_ADMIN" "$reg" s3control list-access-points --account-id "$opid" --bucket "$b" --query 'length(AccessPointList)' --output text) || n=""
    [ "$n" = 0 ] || echo "TC54 old bucket has ${n:-unknown} access point(s)"
    if aws_capture "$P_OP_ADMIN" "$reg" s3api get-bucket-policy --bucket "$b" --query Policy --output text; then
      ac11_policy_readers_eval "$(cat "$WORK/cap.out")" "$opid"
    elif ! grep -q NoSuchBucketPolicy "$WORK/cap.err"; then
      echo "TC54 get-bucket-policy failed on the old bucket (inconclusive)"
    fi
    ac11_acl_eval "$(awsr "$P_OP_ADMIN" "$reg" s3api get-bucket-acl --bucket "$b" --output json || true)"
    local locs="" rg db cat
    for rg in $(printf '%s\n%s\n' "$REGION" "$reg" | sort -u); do
      for db in $(awsr "$P_OP_ADMIN" "$rg" glue get-databases --query 'DatabaseList[].Name' --output text || echo "__error__"); do
        [ "$db" != __error__ ] || { echo "TC54 glue get-databases failed in $rg (inconclusive)"; continue; }
        locs="$locs
$(awsr "$P_OP_ADMIN" "$rg" glue get-tables --database-name "$db" --query 'TableList[].StorageDescriptor.Location' --output text | tr '\t' '\n' || true)"
      done
      for cat in $(awsr "$P_OP_ADMIN" "$rg" athena list-data-catalogs --query 'DataCatalogsSummary[].CatalogName' --output text || true); do
        [ "$cat" != AwsDataCatalog ] && [ "$cat" != None ] || continue
        for db in $(awsr "$P_OP_ADMIN" "$rg" athena list-databases --catalog-name "$cat" --query 'DatabaseList[].Name' --output text || true); do
          locs="$locs
$(awsr "$P_OP_ADMIN" "$rg" athena list-table-metadata --catalog-name "$cat" --database-name "$db" --query 'TableMetadataList[].Parameters.location' --output text | tr '\t' '\n' || true)"
        done
      done
    done
    ac11_tables_eval "$locs" "$b"
    # TC56: source keys.
    list_keys "$P_OP_ADMIN" "$reg" "$b" "$p" >>"$src" || echo "TC56 could not list the old trail prefix"
  done <<EOF
$(jqq -c '.[]' "$BASELINE/legacy-copy.json")
EOF
  ac11_copy_eval "$src" "$dst" "$tot_o" "$tot_l" "$tot_d"
  # TC57: every copied object carries the tag.
  local key st bad=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    st=$(legacy_tag_state "$(awsp "$P_MGMT" s3api get-object-tagging --bucket "$TRAIL_BUCKET" --key "$key" --output json || true)")
    [ "$st" = ok ] || bad=$((bad + 1))
  done <"$dst.raw"
  [ $bad = 0 ] || echo "TC57 $bad copied object(s) without the tag $LEGACY_TAG_KEY=$LEGACY_TAG_VALUE"
}

tc61_cached() {
  local f="$WORK/tc61.out"
  if [ ! -e "$f" ]; then
    if ! has_root guardrails; then
      echo "TC61 guardrails root missing" >"$f"
    else
      tc61_eval "$(tf_root guardrails show -json -no-color 2>>"$ERRLOG" || true)" "$ACCT_MGMT" "$CLONE/guardrails" >"$f"
    fi
  fi
  cat "$f"
}

check_ac12() {
  local st j bud_arn mon_arn
  st="$WORK/state.guardrails"
  for t in aws_cloudtrail aws_s3_bucket aws_budgets_budget aws_ce_anomaly_monitor; do
    grep -q "^$t\." "$st" 2>/dev/null || echo "TC62 no $t in guardrails Terraform state"
  done
  if [ -z "$TRAIL_ARN" ]; then
    echo "TC62 trail: no organization trail"
  else
    [ "$(tf_out guardrails trail_arn)" = "$TRAIL_ARN" ] || echo "TC62 trail: the organization trail is not the one Terraform manages"
    j=$(awsp "$P_MGMT" cloudtrail list-tags --resource-id-list "$TRAIL_ARN" --output json | jqq -c '.ResourceTagList[0].TagsList // []') || j=""
    tags_eval TC62 trail "$j"
  fi
  if [ -z "$TRAIL_BUCKET" ]; then
    echo "TC62 bucket: trail bucket unknown"
  else
    j=$(awsp "$P_MGMT" s3api get-bucket-tagging --bucket "$TRAIL_BUCKET" --output json | jqq -c '.TagSet') || j=""
    tags_eval TC62 bucket "$j"
  fi
  if [ -z "$ACCT_MGMT" ]; then
    echo "TC62 budget: management account ID unknown"
  else
    bud_arn="arn:aws:budgets::$ACCT_MGMT:budget/$BUDGET_NAME"
    j=$(awsp "$P_MGMT" budgets list-tags-for-resource --resource-arn "$bud_arn" --output json | jqq -c '.ResourceTags // []') || j=""
    tags_eval TC62 budget "$j"
  fi
  mon_arn=$(service_monitor_arn "$(awsp "$P_MGMT" ce get-anomaly-monitors --output json || true)")
  if [ -z "$mon_arn" ]; then
    echo "TC62 monitor: no single service monitor"
  else
    [ "$(tf_out guardrails anomaly_monitor_arn)" = "$mon_arn" ] || echo "TC62 monitor: the service monitor is not the one Terraform manages"
    j=$(awsp "$P_MGMT" ce list-tags-for-resource --resource-arn "$mon_arn" --output json | jqq -c '.ResourceTags // []') || j=""
    tags_eval TC62 monitor "$j"
  fi
}

check_ac13() {
  local t
  t=$(cat "$WORK/trails.mgmt.json" 2>/dev/null || true)
  if [ -z "$t" ]; then
    echo "TC24 describe-trails failed (management profile)"
  else
    ac6_trail_eval "$t" "$ACCT_MGMT" "$(cat "$WORK/mgmt-buckets.json" 2>/dev/null || true)" | grep -E '^TC2[34] ' || true
    printf '%s' "$t" | jqq -e '[.trailList[]? | select(.IsOrganizationTrail == true)] | length > 0' >/dev/null || echo "TC24 no organization trail"
  fi
  if [ -n "$TRAIL_BUCKET" ]; then
    log "EVIDENCE AC13 trail bucket: $(awsp "$P_MGMT" s3 ls "s3://$TRAIL_BUCKET" --recursive --summarize | tail -n 2 | tr '\n' ' ' || echo 'size unavailable')"
    log "EVIDENCE AC13 legacy prefix: $(awsp "$P_MGMT" s3 ls "s3://$TRAIL_BUCKET/$LEGACY_PREFIX" --recursive --summarize | tail -n 2 | tr '\n' ' ' || echo 'size unavailable')"
  fi
  echo "@MANUAL check the PR states the expected monthly cost under \$2.00 (exactly \$2.00 is not accepted), covering about 120 days of versioned S3 storage, PUT requests, the budget, anomaly detection, any kept Offers Platform trail and the legacy copies (TC64, TC65)"
}

check_ac14() {
  local rc
  rc=$(tf_plan_default_rc)
  case "$rc" in
    0) ;;
    missing) echo "TC66 guardrails root missing" ;;
    2) echo "TC66 guardrails plan shows changes" ;;
    *) echo "TC66 guardrails plan failed (exit $rc)" ;;
  esac
  if [ -z "$CLONE" ]; then
    echo "TC67 fresh clone failed"
    return 0
  fi
  if has_root guardrails; then
    rc=0
    tf_root guardrails validate -no-color >>"$ERRLOG" 2>&1 || rc=$?
    [ $rc -eq 0 ] || echo "TC67 terraform validate failed in guardrails"
  fi
  rc=0
  terraform -chdir="$CLONE" fmt -check -recursive >>"$ERRLOG" 2>&1 || rc=$?
  [ $rc -eq 0 ] || echo "TC67 terraform fmt -check -recursive failed"
  grep -qE '^ROOTS[[:space:]]*:?=.*(^|[[:space:]])guardrails([[:space:]]|$)' "$CLONE/Makefile" 2>/dev/null ||
    echo "TC67 Makefile ROOTS does not include guardrails"
  local mk="$WORK/clone-make"
  if git clone --quiet "$CLONE" "$mk" >>"$ERRLOG" 2>&1; then
    rc=0
    make -C "$mk" test >>"$ERRLOG" 2>&1 || rc=$?
    [ $rc -eq 0 ] || echo "TC67 make test failed"
    rc=0
    make -C "$mk" lint >>"$ERRLOG" 2>&1 || rc=$?
    [ $rc -eq 0 ] || echo "TC67 make lint failed"
    rm -rf "$mk"
  else
    echo "TC67 second clone for make failed"
  fi
  tc61_cached
}

# ---------------------------------------------------------------- regressions

check_reg68() {
  local name rc keys="" k
  [ -n "$CLONE" ] || { echo "fresh clone failed"; return 0; }
  for name in bootstrap organization; do
    has_root "$name" || { echo "$name root missing"; continue; }
    rc=0
    tf_root "$name" plan -detailed-exitcode -input=false -no-color -lock-timeout=60s $(varfile_args "$name") \
      >"$WORK/plan.$name.log" 2>&1 || rc=$?
    case $rc in
      0) ;;
      2) echo "$name: plan shows changes" ;;
      *) echo "$name: plan failed (exit $rc)" ;;
    esac
  done
  for name in bootstrap organization guardrails; do
    k=$(jqq -r '.backend.config.key // empty' "$CLONE/$name/.terraform/terraform.tfstate" 2>/dev/null || true)
    [ -n "$k" ] || { echo "$name: backend state key unknown"; continue; }
    keys="$keys $k"
    [ "$name" != guardrails ] || [ "$k" = guardrails/terraform.tfstate ] || echo "guardrails state key is not guardrails/terraform.tfstate"
  done
  [ "$(printf '%s\n' $keys | sort | uniq -d | wc -l | tr -d ' ')" = 0 ] || echo "two roots share a state key"
}

check_reg69() {
  awsp "$P_MGMT" organizations list-aws-service-access-for-organization --output json |
    jqq -e 'any(.EnabledServicePrincipals[]?; .ServicePrincipal == "cloudtrail.amazonaws.com")' >/dev/null ||
    echo "cloudtrail.amazonaws.com does not have trusted access (or the call failed)"
  awsp "$P_ABC_ENG" ce get-cost-and-usage --time-period "Start=$(days_ago 7),End=$(days_ago 0)" \
    --granularity DAILY --metrics UnblendedCost --output json | jqq -e '.ResultsByTime | type == "array"' >/dev/null ||
    echo "ABC Bank engineering profile cannot read its costs (ce get-cost-and-usage failed)"
}

check_reg70() {
  local v rootid label id
  v=$(awsp "$P_MGMT" organizations list-policies --filter SERVICE_CONTROL_POLICY --query 'Policies[].Name' --output text) || v="__error__"
  case "$v" in
    __error__) echo "list-policies failed" ;;
    FullAWSAccess | "" | None) ;;
    *) echo "service control policies other than FullAWSAccess exist" ;;
  esac
  rootid=$(awsp "$P_MGMT" organizations list-roots --query 'Roots[0].Id' --output text) || rootid=""
  [ -n "$rootid" ] && [ "$rootid" != None ] || echo "organization root not found"
  for label in root management abc_bank offers_platform; do
    case $label in root) id=$rootid ;; management) id=$ACCT_MGMT ;; abc_bank) id=$ACCT_ABC ;; *) id=$ACCT_OP ;; esac
    [ -n "$id" ] && [ "$id" != None ] || { echo "$label ID unknown, SCPs not checked"; continue; }
    v=$(awsp "$P_MGMT" organizations list-policies-for-target --target-id "$id" --filter SERVICE_CONTROL_POLICY --query 'Policies[].Name' --output text) || v="__error__"
    case "$v" in
      __error__) echo "list-policies-for-target failed ($label)" ;;
      FullAWSAccess | "" | None) ;;
      *) echo "$label has an SCP other than FullAWSAccess" ;;
    esac
  done
  [ -n "$SSO_INSTANCE_ARN" ] || { echo "Identity Center instance not found"; return 0; }
  local ps name names="" admin=""
  for ps in $(awsp "$P_MGMT" sso-admin list-permission-sets --instance-arn "$SSO_INSTANCE_ARN" --query 'PermissionSets[]' --output text || true); do
    [ "$ps" != None ] || continue
    name=$(awsp "$P_MGMT" sso-admin describe-permission-set --instance-arn "$SSO_INSTANCE_ARN" --permission-set-arn "$ps" --query PermissionSet.Name --output text) || name="?"
    names="$names $name"
    [ "$name" != "$PS_ADMIN_NAME" ] || admin=$ps
  done
  [ "$(printf '%s\n' $names | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" = "$EXPECTED_PERMISSION_SETS" ] ||
    echo "permission sets are [${names# }], expected [$EXPECTED_PERMISSION_SETS]"
  [ -n "$admin" ] || return 0
  local n
  for label in management abc_bank offers_platform; do
    case $label in management) id=$ACCT_MGMT ;; abc_bank) id=$ACCT_ABC ;; *) id=$ACCT_OP ;; esac
    [ -n "$id" ] || { echo "$label account ID unknown"; continue; }
    n=$(awsp "$P_MGMT" sso-admin list-account-assignments --instance-arn "$SSO_INSTANCE_ARN" --account-id "$id" \
      --permission-set-arn "$admin" --query 'length(AccountAssignments)' --output text) || n=""
    [ -n "$n" ] && [ "$n" != 0 ] || echo "Administrator assignment missing in $label"
  done
}

check_reg71() {
  local p label users u k
  for label in management abc_bank; do
    case $label in management) p=$P_MGMT ;; *) p=$P_ABC_ADMIN ;; esac
    users=$(awsp "$p" iam list-users --query 'Users[].UserName' --output text) || { echo "$label: list-users failed"; continue; }
    case "$users" in "" | None) ;; *) echo "$label has IAM user(s)" ;; esac
    for u in $users; do
      [ "$u" != None ] || continue
      k=$(awsp "$p" iam list-access-keys --user-name "$u" --query 'length(AccessKeyMetadata)' --output text) || k="?"
      [ "$k" = 0 ] || echo "$label: an IAM user has access keys"
    done
  done
}

check_reg72() {
  [ -n "$CLONE" ] || { echo "fresh clone failed"; return 0; }
  local v g="$CLONE/guardrails"
  v=$(git -C "$CLONE" ls-files | grep -E '\.tfvars$' | grep -vE '(^|/)example\.tfvars$' || true)
  [ -z "$v" ] || echo "tracked .tfvars other than example.tfvars: $v"
  v=$(git -C "$CLONE" ls-files | grep -E '\.tfstate(\.|$)|(^|/)credentials$|\.pem$|(^|/)\.env$' || true)
  [ -z "$v" ] || echo "tracked state or credential files: $v"
  v=$(git -C "$CLONE" grep -lE 'AKIA[0-9A-Z]{16}|aws_secret_access_key' -- . ':!tests/' 2>/dev/null || true)
  [ -z "$v" ] || echo "key-like strings in: $v"
  if ! has_root guardrails; then
    echo "guardrails root missing"
    return 0
  fi
  git -C "$CLONE" ls-files --error-unmatch guardrails/example.tfvars >/dev/null 2>&1 || echo "guardrails/example.tfvars is not tracked"
  grep -qE '^[[:space:]]*alert_email[[:space:]]*=[[:space:]]*"[^"]*@example\.(com|net|org)"' "$g/example.tfvars" 2>/dev/null ||
    echo "guardrails/example.tfvars has no placeholder alert_email"
  v=$(grep -lE '(^|[^0-9])[0-9]{12}([^0-9]|$)' "$g"/*.tf 2>/dev/null | grep -v '/variables\.tf$' || true)
  [ -z "$v" ] || echo "12-digit number in guardrails .tf outside variables.tf"
  v=$(grep -lE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$g"/*.tf 2>/dev/null | grep -v '/variables\.tf$' || true)
  [ -z "$v" ] || echo "e-mail address in guardrails .tf outside variables.tf"
  v=$(grep -hE -A2 'source *= *"hashicorp/aws"' "$g"/*.tf 2>/dev/null | grep -E '^[[:space:]]*version[[:space:]]*=' || true)
  printf '%s' "$v" | grep -qE '"[[:space:]]*(~>|>=)' || echo "aws provider is not pinned to a version range in guardrails"
  v=$(grep -hE '^[[:space:]]*region[[:space:]]*=' "$g"/*.tf 2>/dev/null || true)
  [ -n "$v" ] || echo "no region set in guardrails"
  printf '%s\n' "$v" | grep -vqE '"us-east-1"' && [ -n "$v" ] && echo "a region other than us-east-1 in guardrails"
  tf_desc_eval "$g"/*.tf | sed "s#$CLONE/##; s#^REG-TC72 ##"
  return 0
}

# ---------------------------------------------------------------- driver

emit() {
  printf '%s %s %s\n' "$1" "$2" "$3" | redact
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
  if [ -n "$TEST_BUCKET" ] && [ "$TEST_BUCKET_DELETED" != 1 ]; then
    if awsp "$P_ABC_ADMIN" s3api delete-bucket --bucket "$TEST_BUCKET" >/dev/null 2>&1; then
      log "AC7: test bucket deleted on exit"
    elif [ "$TEST_BUCKET_CREATED" = 1 ]; then
      log "WARNING: AC7 test bucket $TEST_BUCKET may still exist in ABC Bank; delete it by hand"
    fi
    TEST_BUCKET_DELETED=1
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    if [ "${FND4_DEBUG:-0}" = 1 ] && [ -f "$WORK/errors.log" ]; then redact <"$WORK/errors.log" >&2 || true; fi
    rm -rf "$WORK"
  fi
}

main() {
  local missing="" tool id
  for tool in aws jq git terraform make gzip; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    for id in $AC_IDS $REG_IDS; do emit FAIL "$id" "required tool(s) missing:$missing"; done
    exit 1
  fi

  WORK=$(mktemp -d "${FND4_TMPDIR:-${TMPDIR:-/tmp}}/fnd4.XXXXXX")
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  ERRLOG="$WORK/errors.log"
  : >"$ERRLOG"

  discover || true
  events_phase || true

  run_check AC1 check_ac1 "one monthly \$100 unblended cost budget; ACTUAL alerts at 50/80/100% to the engineer's address"
  run_check AC2 check_ac2 "posture=working plans only the limit 100 -> 300 in place; default and lean plan no changes; invalid values rejected"
  run_check AC3 check_ac3 ""
  run_check AC4 check_ac4 "one service monitor (imported or new, in state); one daily e-mail subscription at >= \$10; others unchanged"
  run_check AC5 check_ac5 "data-product, environment, owner and cost-center are Active cost-allocation tags"
  run_check AC6 check_ac6 "one organization trail: all regions, validation on, read and write management events, logging; reads recorded in all three accounts"
  run_check AC7 check_ac7 "ABC Bank CreateBucket and DeleteBucket by the administrator role in the trail bucket within 30:00; test bucket gone"
  run_check AC8 check_ac8 "validate-logs for the previous hour: all digest and log files valid in all three accounts"
  run_check AC9 check_ac9 "trail bucket: versioned, private, SSE-S3, 90-day and 30-day lifecycle, delete markers cleaned, us-east-1, management-owned"
  run_check AC10 check_ac10 "members see the management-owned trail, hold no organization budget, and cannot change the trail or bucket"
  run_check AC11 check_ac11 "Offers Platform findings in README; no management-only trail left; legacy copy complete and tagged (or not applicable)"
  run_check AC12 check_ac12 "trail, bucket, budget and monitor carry the four cost tags"
  run_check AC13 check_ac13 ""
  run_check AC14 check_ac14 "guardrails plan shows no changes; fmt, validate, make test and make lint pass"
  run_check REG-TC68 check_reg68 "bootstrap and organization plans show no changes; guardrails has its own state key"
  run_check REG-TC69 check_reg69 "CloudTrail trusted access kept; ABC Bank engineering still sees its costs"
  run_check REG-TC70 check_reg70 "no new SCP; permission sets and Administrator assignments unchanged"
  run_check REG-TC71 check_reg71 "no IAM users or access keys in management and ABC Bank"
  run_check REG-TC72 check_reg72 "repo hygiene: no tfvars, state or IDs tracked; provider pinned; us-east-1; variables and outputs documented"

  log "MANUAL TC73: run tests/FND-3.sh after FND-4 is applied; no line that was PASS in the FND-3 PR evidence may now be FAIL"

  [ "$ANY_FAIL" = 0 ] || exit 1
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
