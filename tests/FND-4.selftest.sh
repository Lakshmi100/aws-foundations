#!/usr/bin/env bash
# FND-4 self-test: checks the logic of tests/FND-4.sh with stubbed responses.
# Needs no AWS credentials and makes no AWS calls. The check functions are
# sourced and fed canned JSON from tests/fixtures/FND-4/ (the test plan's
# "stubbed response" cases TC04, TC08, TC10, TC16, TC18, TC25, TC29, TC32,
# TC33, TC39, TC58, TC59, TC63); the single aws entry point (aws_call) is
# replaced by a stub, and the AC7 poll runs on a fake clock. Then the whole
# script is run with stub `aws` and `terraform` commands first on PATH (TC74).
#
# Fixtures hold placeholders (__MGMT__, __ABC__, __OP__, __ORG__, __EMAIL__)
# that are replaced at run time with fake values, so no account ID or e-mail
# address is committed.
#
# Prints one PASS or FAIL line per self-test case; exits 1 if any FAIL.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/FND-4.sh"
FIX="$HERE/fixtures/FND-4"

ST_FAIL=0
ST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fnd4-selftest.XXXXXX")
trap 'rm -rf "$ST_TMP"' EXIT

# Isolate from the owner's real baseline and e-mail.
ST_BASELINE="$ST_TMP/no-baseline"
mkdir -p "$ST_BASELINE"
export FND4_BASELINE_DIR="$ST_BASELINE"
unset FND4_ALERT_EMAIL

# shellcheck source=FND-4.sh
. "$SCRIPT"
set +e # sourced check functions run as in run_check (errexit off inside)
set -uo pipefail

ok() { printf 'PASS %s %s\n' "$1" "$2"; }
ko() {
  printf 'FAIL %s %s\n' "$1" "$2"
  ST_FAIL=1
}

# Fake values, built at run time (no literals in the repo).
fake_id() { printf '%012d' "$1"; }
M=$(fake_id 1)
A=$(fake_id 2)
O=$(fake_id 3)
ORGF=o-fixture1234
FAKE_EMAIL="eng.selftest$(printf '\100')fnd4-selftest.invalid"

fixture() {
  sed -e "s/__MGMT__/$M/g" -e "s/__ABC__/$A/g" -e "s/__OP__/$O/g" -e "s/__ORG__/$ORGF/g" -e "s/__EMAIL__/$FAKE_EMAIL/g" "$FIX/$1"
}
fixture_dir() {
  local src=$1 dst=$2 f
  mkdir -p "$dst"
  for f in "$FIX/$src"/*; do fixture "$src/$(basename "$f")" >"$dst/$(basename "$f")"; done
}
jx() { jq -c "$@"; }

# expect_problems CASE DESC FUNC ARGS...: FUNC must print at least one problem line.
expect_problems() {
  local case=$1 desc=$2 out
  shift 2
  out=$("$@" 2>/dev/null | grep -v '^@MANUAL ' || true)
  if [ -n "$out" ]; then ok "$case" "$desc -> $(printf '%s' "$out" | head -n 1 | cut -c1-110)"; else ko "$case" "$desc: no problem reported"; fi
}

# expect_clean CASE DESC FUNC ARGS...: FUNC must print no problem line (control case).
expect_clean() {
  local case=$1 desc=$2 out
  shift 2
  out=$("$@" 2>/dev/null | grep -v '^@MANUAL ' || true)
  if [ -z "$out" ]; then ok "$case" "$desc (control)"; else ko "$case" "$desc: unexpected problem: $out"; fi
}

# expect_line CASE DESC WANT_STATUS ID FUNC [GREP]: the result line from run_check.
expect_line() {
  local case=$1 desc=$2 want=$3 id=$4 fn=$5 pat=${6:-} line
  ANY_FAIL=0
  line=$(run_check "$id" "$fn" "ok" 2>/dev/null)
  case "$line" in
    "$want $id "*)
      if [ -n "$pat" ] && ! printf '%s' "$line" | grep -q -- "$pat"; then
        ko "$case" "$desc: line lacks '$pat': $line"
      else
        ok "$case" "$desc -> $(printf '%s' "$line" | cut -c1-120)"
      fi
      ;;
    *) ko "$case" "$desc: got '$line'" ;;
  esac
}

# ------------------------------------------------------------ stub aws entry point
ST_CALLS="$ST_TMP/calls.log"
: >"$ST_CALLS"
profile_key() {
  case "$1" in
    "$P_MGMT") echo MGMT ;;
    "$P_ABC_ADMIN") echo ABC ;;
    "$P_OP_ADMIN") echo OP ;;
    "$P_ABC_ENG") echo ABCENG ;;
    *) echo X ;;
  esac
}

# Answers from variables STUB_<service>_<operation>[__<MGMT|ABC|OP|ABCENG>]
# ("-" becomes "_"). A value starting with ERR: is an error on stderr.
STUB_EV=0
aws_call() {
  local p=$1 r=$2 pk key v
  shift 2
  printf '%s %s %s\n' "$(profile_key "$p")" "$r" "$*" >>"$ST_CALLS"
  if [ "$STUB_EV" = 1 ]; then
    ev_stub "$p" "$@"
    return $?
  fi
  pk=$(profile_key "$p")
  key=$(printf '%s_%s' "$1" "$2" | tr -- '-' '_')
  eval "v=\${STUB_${key}__${pk}-__unset__}"
  [ "$v" != __unset__ ] || eval "v=\${STUB_${key}-__unset__}"
  case "$v" in
    __unset__)
      echo "stub: no response for $1 $2" >&2
      return 254
      ;;
    ERR:*)
      printf '%s\n' "${v#ERR:}" >&2
      return 254
      ;;
    *) printf '%s\n' "$v" ;;
  esac
}

FAKE_NOW=""
now_epoch() { echo "${FAKE_NOW:-$(date -u +%s)}"; }
poll_sleep() { FAKE_NOW=$((FAKE_NOW + $1)); }

WORK="$ST_TMP/work"
mkdir -p "$WORK"
ERRLOG=/dev/null
ACCT_MGMT=$M ACCT_ABC=$A ACCT_OP=$O ORG_ID=$ORGF
ALERT_EMAIL=$FAKE_EMAIL
POSTURE=lean
BUDGET_NAME=$DEFAULT_BUDGET_NAME

# ------------------------------------------------------------ TC04 (AC1 boundaries)
B=$(fixture budgets-mgmt.json)
N=$(fixture budget-notifications.json)
S=$(fixture budget-subscribers.json)
expect_clean TC04 "one COST budget, 100.0 USD, monthly, unblended" ac1_budgets_eval "$B"
expect_problems TC04 "limit 100.01" ac1_budgets_eval "$(printf '%s' "$B" | jx '.Budgets[0].BudgetLimit.Amount = "100.01"')"
expect_problems TC04 "limit 99.99" ac1_budgets_eval "$(printf '%s' "$B" | jx '.Budgets[0].BudgetLimit.Amount = "99.99"')"
expect_problems TC04 "two cost budgets" ac1_budgets_eval "$(printf '%s' "$B" | jx '.Budgets += [.Budgets[0] | .BudgetName = "second"]')"
expect_problems TC04 "zero budgets" ac1_budgets_eval '{"Budgets":[]}'
expect_problems TC04 "no Budgets key (account has none)" ac1_budgets_eval '{}'
expect_problems TC04 "quarterly, not monthly" ac1_budgets_eval "$(printf '%s' "$B" | jx '.Budgets[0].TimeUnit = "QUARTERLY"')"
expect_problems TC04 "cost filter on one account" ac1_budgets_eval "$(printf '%s' "$B" | jx '.Budgets[0].CostFilters = {"LinkedAccount":["x"]}')"
expect_problems TC04 "blended cost" ac1_budgets_eval "$(printf '%s' "$B" | jx '.Budgets[0].CostTypes.UseBlended = true')"
expect_problems TC04 "amortized cost" ac1_budgets_eval "$(printf '%s' "$B" | jx '.Budgets[0].CostTypes.UseAmortized = true')"
expect_problems TC04 "credits excluded (not the AWS default)" ac1_budgets_eval "$(printf '%s' "$B" | jx '.Budgets[0].CostTypes.IncludeCredit = false')"
expect_clean TC04 "three ACTUAL GREATER_THAN PERCENTAGE notifications 50/80/100" ac1_notifications_eval "$N"
expect_problems TC04 "thresholds 50/80 only" ac1_notifications_eval "$(printf '%s' "$N" | jx '.Notifications |= .[0:2]')"
expect_problems TC04 "thresholds 50/80/100/100 (duplicate)" ac1_notifications_eval "$(printf '%s' "$N" | jx '.Notifications += [.Notifications[2]]')"
expect_problems TC04 "100% FORECASTED instead of ACTUAL" ac1_notifications_eval "$(printf '%s' "$N" | jx '.Notifications[2].NotificationType = "FORECASTED"')"
expect_problems TC04 "ThresholdType ABSOLUTE_VALUE 100" ac1_notifications_eval "$(printf '%s' "$N" | jx '.Notifications[2].ThresholdType = "ABSOLUTE_VALUE"')"
expect_problems TC04 "thresholds 50/80/90" ac1_notifications_eval "$(printf '%s' "$N" | jx '.Notifications[2].Threshold = 90')"
expect_clean TC04 "one EMAIL subscriber, the engineer" ac1_subscribers_eval "$S" "$FAKE_EMAIL" 50
expect_problems TC04 "subscriber with a different address" ac1_subscribers_eval "$(printf '%s' "$S" | jx '.Subscribers[0].Address = "other@example.com"')" "$FAKE_EMAIL" 50
expect_problems TC04 "subscriber of type SNS" ac1_subscribers_eval "$(printf '%s' "$S" | jx '.Subscribers[0].SubscriptionType = "SNS"')" "$FAKE_EMAIL" 50
expect_problems TC04 "two subscribers" ac1_subscribers_eval "$(printf '%s' "$S" | jx '.Subscribers += [.Subscribers[0]]')" "$FAKE_EMAIL" 50

# AC1 line through check_ac1 and the stubbed aws entry point.
STUB_budgets_describe_budgets=$B
STUB_budgets_describe_notifications_for_budget=$N
STUB_budgets_describe_subscribers_for_notification=$S
rm -f "$WORK/budgets.mgmt.json"
expect_line TC04 "AC1 line with the good stub" PASS AC1 check_ac1
STUB_budgets_describe_budgets=$(printf '%s' "$B" | jx '.Budgets[0].BudgetLimit.Amount = "99.99"')
rm -f "$WORK/budgets.mgmt.json"
expect_line TC04 "AC1 line, limit 99.99" FAIL AC1 check_ac1 TC01
STUB_budgets_describe_budgets=$B
rm -f "$WORK/budgets.mgmt.json"
STUB_budgets_describe_notifications_for_budget=$(printf '%s' "$N" | jx '.Notifications[2].NotificationType = "FORECASTED"')
expect_line TC04 "AC1 line, FORECASTED notification" FAIL AC1 check_ac1 TC02
STUB_budgets_describe_notifications_for_budget=$N
STUB_budgets_describe_subscribers_for_notification=$(printf '%s' "$S" | jx '.Subscribers[0].SubscriptionType = "SNS"')
expect_line TC04 "AC1 line, SNS subscriber" FAIL AC1 check_ac1 TC03
STUB_budgets_describe_subscribers_for_notification=$S
ALERT_EMAIL=""
expect_line TC04 "AC1 line, engineer e-mail unknown" FAIL AC1 check_ac1 TC03
ALERT_EMAIL=$FAKE_EMAIL
rm -f "$WORK/budgets.mgmt.json"
LINE=$(run_check AC1 check_ac1 ok 2>&1)
printf '%s' "$LINE" | grep -qF "$FAKE_EMAIL" && ko TC04 "AC1 line printed the engineer e-mail" || ok TC04 "AC1 line never prints the engineer e-mail"

# ------------------------------------------------------------ TC05, TC06, TC08 (AC2 plan logic)
P=$(fixture plan-working.json)
expect_clean TC05 "only the budget, update in place, limit_amount 100 -> 300" ac2_plan_eval "$P"
expect_problems TC05 "budget replaced (delete+create)" ac2_plan_eval "$(printf '%s' "$P" | jx '.resource_changes[0].change.actions = ["delete","create"]')"
expect_problems TC05 "a second resource also changes" ac2_plan_eval "$(printf '%s' "$P" | jx '.resource_changes[1].change.actions = ["update"]')"
expect_problems TC05 "a resource is created" ac2_plan_eval "$(printf '%s' "$P" | jx '.resource_changes += [{"address":"aws_sns_topic.x","type":"aws_sns_topic","change":{"actions":["create"],"before":null,"after":{}}}]')"
expect_problems TC05 "limit changes to 250, not 300" ac2_plan_eval "$(printf '%s' "$P" | jx '.resource_changes[0].change.after.limit_amount = "250.00"')"
expect_problems TC05 "time unit also changes" ac2_plan_eval "$(printf '%s' "$P" | jx '.resource_changes[0].change.after.time_unit = "QUARTERLY"')"
expect_problems TC05 "no changes at all" ac2_plan_eval "$(printf '%s' "$P" | jx '.resource_changes[0].change.actions = ["no-op"]')"
expect_problems TC06 "a notification threshold changes" ac2_plan_eval "$(printf '%s' "$P" | jx '.resource_changes[0].change.after.notification[0].threshold = 60')"
expect_problems TC06 "a subscriber changes" ac2_plan_eval "$(printf '%s' "$P" | jx '.resource_changes[0].change.after.notification[2].subscriber_email_addresses = ["x@example.com"]')"
printf 'Error: Invalid value for variable\n\n  on variables.tf line 9:\n' >"$ST_TMP/val.log"
printf 'Error: Value for undeclared variable\n' >"$ST_TMP/undeclared.log"
for v in Heavy "" Working; do
  expect_clean TC08 "posture='$v' rejected by validation (exit 1)" ac2_invalid_eval "$v" 1 "$ST_TMP/val.log"
  expect_problems TC08 "posture='$v' accepted (exit 0)" ac2_invalid_eval "$v" 0 "$ST_TMP/val.log"
  expect_problems TC08 "posture='$v' plans changes (exit 2, other limit)" ac2_invalid_eval "$v" 2 "$ST_TMP/val.log"
done
expect_problems TC08 "failure is not a validation error (undeclared variable)" ac2_invalid_eval Heavy 1 "$ST_TMP/undeclared.log"

# ------------------------------------------------------------ TC10, TC11 (AC3)
ac3_case() { ac3_eval "$AC3_MTD" "$AC3_LIVE" "$AC3_POSTURE" "$AC3_RC"; }
AC3_MTD=0 AC3_LIVE=100.0 AC3_POSTURE=lean AC3_RC=0
expect_line TC10 "month-to-date \$0.00 is MANUAL wait, never PASS" MANUAL AC3 ac3_case "wait until month-to-date spend is above"
AC3_MTD=0.0000001
expect_line TC10 "tiny positive spend is MANUAL with the figure" MANUAL AC3 ac3_case 'spend is \$0.00'
AC3_MTD=3.1234
expect_line TC09 "spend above \$0.00: MANUAL owner step with the figure" MANUAL AC3 ac3_case 'spend is \$3.12'
AC3_LIVE=0.01
expect_line TC11 "live limit 0.01 (override not reset)" FAIL AC3 ac3_case TC11
AC3_LIVE=300 AC3_POSTURE=working
expect_line TC11 "posture working, live 300" MANUAL AC3 ac3_case
AC3_POSTURE=lean
expect_line TC11 "posture lean, live 300" FAIL AC3 ac3_case TC11
AC3_LIVE=100 AC3_RC=2
expect_line TC11 "plan shows changes after the reset" FAIL AC3 ac3_case TC11
AC3_RC=0 AC3_MTD=""
expect_line TC10 "month-to-date spend unreadable" FAIL AC3 ac3_case TC10
AC3_MTD=1 AC3_POSTURE=Heavy
expect_line TC11 "configured posture invalid" FAIL AC3 ac3_case TC11

# ------------------------------------------------------------ TC12-TC16 (AC4)
MON=$(fixture anomaly-monitors.json)
SUB=$(fixture anomaly-subscriptions.json)
SVC="arn:aws:ce::$M:anomalymonitor/svc-1"
expect_clean TC12 "one SERVICE monitor plus a CUSTOM one" ac4_monitors_eval "$MON"
expect_problems TC12 "second SERVICE monitor" ac4_monitors_eval "$(printf '%s' "$MON" | jx '.AnomalyMonitors += [.AnomalyMonitors[0] | .MonitorArn += "-2"]')"
expect_problems TC16 "MonitorDimension missing" ac4_monitors_eval "$(printf '%s' "$MON" | jx 'del(.AnomalyMonitors[0].MonitorDimension)')"
expect_problems TC16 "only a CUSTOM monitor" ac4_monitors_eval "$(printf '%s' "$MON" | jx '.AnomalyMonitors |= [.[1]]')"
expect_clean TC13 "daily, one EMAIL subscriber, >= \$10 absolute" ac4_subscriptions_eval "$SUB" "$SVC" "$FAKE_EMAIL"
expect_clean TC13 "legacy Threshold 10 without ThresholdExpression" ac4_subscriptions_eval \
  "$(printf '%s' "$SUB" | jx 'del(.AnomalySubscriptions[0].ThresholdExpression) | .AnomalySubscriptions[0].Threshold = 10.0')" "$SVC" "$FAKE_EMAIL"
for f in WEEKLY IMMEDIATE; do
  expect_problems TC16 "frequency $f" ac4_subscriptions_eval "$(printf '%s' "$SUB" | jx --arg f "$f" '.AnomalySubscriptions[0].Frequency = $f')" "$SVC" "$FAKE_EMAIL"
done
for t in 9.99 100; do
  expect_problems TC16 "threshold $t" ac4_subscriptions_eval "$(printf '%s' "$SUB" | jx --arg t "$t" '.AnomalySubscriptions[0].ThresholdExpression.Dimensions.Values = [$t]')" "$SVC" "$FAKE_EMAIL"
done
expect_problems TC16 "10 percent (ANOMALY_TOTAL_IMPACT_PERCENTAGE)" ac4_subscriptions_eval \
  "$(printf '%s' "$SUB" | jx '.AnomalySubscriptions[0].ThresholdExpression.Dimensions.Key = "ANOMALY_TOTAL_IMPACT_PERCENTAGE"')" "$SVC" "$FAKE_EMAIL"
expect_problems TC16 "GREATER_THAN 10 instead of >=" ac4_subscriptions_eval \
  "$(printf '%s' "$SUB" | jx '.AnomalySubscriptions[0].ThresholdExpression.Dimensions.MatchOptions = ["GREATER_THAN"]')" "$SVC" "$FAKE_EMAIL"
expect_problems TC16 "subscriber SNS" ac4_subscriptions_eval "$(printf '%s' "$SUB" | jx '.AnomalySubscriptions[0].Subscribers[0].Type = "SNS"')" "$SVC" "$FAKE_EMAIL"
expect_problems TC13 "subscriber is another address" ac4_subscriptions_eval "$(printf '%s' "$SUB" | jx '.AnomalySubscriptions[0].Subscribers[0].Address = "x@example.com"')" "$SVC" "$FAKE_EMAIL"
expect_problems TC15 "second subscription on the service monitor" ac4_subscriptions_eval \
  "$(printf '%s' "$SUB" | jx '.AnomalySubscriptions += [.AnomalySubscriptions[0] | .SubscriptionArn += "-2"]')" "$SVC" "$FAKE_EMAIL"
expect_problems TC13 "no subscription on the service monitor" ac4_subscriptions_eval "$(printf '%s' "$SUB" | jx '.AnomalySubscriptions |= [.[1]]')" "$SVC" "$FAKE_EMAIL"

# AC4 line with the baseline (TC14, TC15): the baseline service monitor was imported.
BASE_FIX="$ST_TMP/baseline-fixture"
fixture_dir baseline "$BASE_FIX"
BASELINE=$BASE_FIX
printf '{"anomaly_monitor_arn":{"value":"%s"},"trail_arn":{"value":"arn:aws:cloudtrail:us-east-1:%s:trail/aws-foundations-organization-trail"},"trail_bucket_name":{"value":"aws-foundations-cloudtrail-fixture"},"budget_name":{"value":"aws-foundations-monthly-cost"}}' \
  "$SVC" "$M" >"$WORK/tfout.guardrails.json"
printf '%s\n' aws_budgets_budget.organization aws_ce_anomaly_monitor.services aws_ce_anomaly_subscription.daily aws_cloudtrail.organization \
  aws_s3_bucket.trail >"$WORK/state.guardrails"
STUB_ce_get_anomaly_monitors=$MON
STUB_ce_get_anomaly_subscriptions=$SUB
expect_line TC14 "AC4 line: imported monitor, other monitor and subscription unchanged" PASS AC4 check_ac4
STUB_ce_get_anomaly_monitors=$(printf '%s' "$MON" | jx '.AnomalyMonitors[0].MonitorArn += "-new"')
STUB_ce_get_anomaly_subscriptions=$(printf '%s' "$SUB" | jx '.AnomalySubscriptions[0].MonitorArnList = [.AnomalySubscriptions[0].MonitorArnList[0] + "-new"]')
expect_line TC14 "AC4 line: baseline service monitor replaced, not imported" FAIL AC4 check_ac4 TC14
STUB_ce_get_anomaly_monitors=$(printf '%s' "$MON" | jx '.AnomalyMonitors |= [.[0]]')
STUB_ce_get_anomaly_subscriptions=$SUB
expect_line TC14 "AC4 line: a non-service baseline monitor was deleted" FAIL AC4 check_ac4 "TC14 baseline monitor some-custom-monitor"
STUB_ce_get_anomaly_monitors=$MON
STUB_ce_get_anomaly_subscriptions=$(printf '%s' "$SUB" | jx '.AnomalySubscriptions[1].Frequency = "DAILY"')
expect_line TC15 "AC4 line: a subscription not on the service monitor changed" FAIL AC4 check_ac4 "TC15 baseline subscription custom-weekly changed"
STUB_ce_get_anomaly_subscriptions=$SUB
BASELINE=$ST_BASELINE
expect_line TC14 "AC4 line: baseline missing" FAIL AC4 check_ac4 "baseline missing"
BASELINE=$BASE_FIX

# ------------------------------------------------------------ TC18 (AC5)
T=$(fixture cost-allocation-tags.json)
expect_clean TC17 "four tags UserDefined and Active" ac5_eval "$T"
expect_problems TC18 "one key Inactive" ac5_eval "$(printf '%s' "$T" | jx '.CostAllocationTags[1].Status = "Inactive"')"
expect_problems TC18 "a key missing from the list" ac5_eval "$(printf '%s' "$T" | jx '.CostAllocationTags |= map(select(.TagKey != "cost-center"))')"
expect_problems TC18 "Owner active but owner not" ac5_eval \
  "$(printf '%s' "$T" | jx '.CostAllocationTags |= (map(if .TagKey == "owner" then .Status = "Inactive" else . end) + [{"TagKey":"Owner","Type":"UserDefined","Status":"Active"}])')"
STUB_ce_list_cost_allocation_tags=$(printf '%s' "$T" | jx '.CostAllocationTags |= map(select(.TagKey != "cost-center"))')
expect_line TC18 "AC5 line names the missing key and says it has not been seen" FAIL AC5 check_ac5 "cost-center is not listed: AWS has not seen it on a billed resource yet"
STUB_ce_list_cost_allocation_tags=$(printf '%s' "$T" | jx '.CostAllocationTags[2].Status = "Inactive"')
expect_line TC18 "AC5 line names the Inactive key" FAIL AC5 check_ac5 "tag owner is Inactive"
STUB_ce_list_cost_allocation_tags=$T
expect_line TC17 "AC5 line with the good stub" PASS AC5 check_ac5

# ------------------------------------------------------------ TC19-TC25 (AC6)
TR=$(fixture trails-mgmt.json)
BK=$(printf '["aws-foundations-cloudtrail-fixture","other"]')
SEL=$(fixture event-selectors.json)
TS=$(fixture trail-status.json)
TS_NOW=$(to_epoch 2026-11-22T19:50:00Z)
expect_clean TC19 "organization trail as designed" ac6_trail_eval "$TR" "$M" "$BK"
expect_problems TC25 "IsMultiRegionTrail false" ac6_trail_eval "$(printf '%s' "$TR" | jx '.trailList[0].IsMultiRegionTrail = false')" "$M" "$BK"
expect_problems TC25 "log file validation off" ac6_trail_eval "$(printf '%s' "$TR" | jx '.trailList[0].LogFileValidationEnabled = false')" "$M" "$BK"
expect_problems TC25 "IsOrganizationTrail false" ac6_trail_eval "$(printf '%s' "$TR" | jx '.trailList[0].IsOrganizationTrail = false')" "$M" "$BK"
expect_problems TC19 "trail ARN in another account" ac6_trail_eval "$TR" "$A" "$BK"
expect_problems TC19 "trail bucket not owned by management" ac6_trail_eval "$TR" "$M" '["other"]'
expect_problems TC19 "home region us-west-2" ac6_trail_eval "$(printf '%s' "$TR" | jx '.trailList[0].HomeRegion = "us-west-2"')" "$M" "$BK"
expect_problems TC23 "CloudWatch Logs destination" ac6_trail_eval "$(printf '%s' "$TR" | jx '.trailList[0].CloudWatchLogsLogGroupArn = "arn:x"')" "$M" "$BK"
expect_problems TC23 "KMS key" ac6_trail_eval "$(printf '%s' "$TR" | jx '.trailList[0].KmsKeyId = "arn:k"')" "$M" "$BK"
expect_problems TC23 "SNS topic" ac6_trail_eval "$(printf '%s' "$TR" | jx '.trailList[0].SnsTopicARN = "arn:s"')" "$M" "$BK"
expect_problems TC23 "Insights selectors" ac6_trail_eval "$(printf '%s' "$TR" | jx '.trailList[0].HasInsightSelectors = true')" "$M" "$BK"
expect_problems TC24 "second organization trail" ac6_trail_eval "$(printf '%s' "$TR" | jx '.trailList += [.trailList[0] | .Name = "second" | .TrailARN += "2"]')" "$M" "$BK"
expect_clean TC20 "management events, ReadWriteType All" ac6_selectors_eval "$SEL"
for rw in WriteOnly ReadOnly; do
  expect_problems TC25 "ReadWriteType $rw" ac6_selectors_eval "$(printf '%s' "$SEL" | jx --arg r "$rw" '.EventSelectors[0].ReadWriteType = $r')"
done
expect_problems TC20 "management events excluded" ac6_selectors_eval "$(printf '%s' "$SEL" | jx '.EventSelectors[0].IncludeManagementEvents = false')"
expect_problems TC20 "excluded event source (KMS)" ac6_selectors_eval "$(printf '%s' "$SEL" | jx '.EventSelectors[0].ExcludeManagementEventSources = ["kms.amazonaws.com"]')"
expect_problems TC20 "data event selector" ac6_selectors_eval "$(printf '%s' "$SEL" | jx '.EventSelectors[0].DataResources = [{"Type":"AWS::S3::Object","Values":["arn:aws:s3"]}]')"
expect_clean TC20 "advanced selector: Management only, no readOnly" ac6_selectors_eval \
  '{"AdvancedEventSelectors":[{"Name":"m","FieldSelectors":[{"Field":"eventCategory","Equals":["Management"]}]}]}'
expect_problems TC20 "advanced selector with readOnly = true" ac6_selectors_eval \
  '{"AdvancedEventSelectors":[{"Name":"m","FieldSelectors":[{"Field":"eventCategory","Equals":["Management"]},{"Field":"readOnly","Equals":["true"]}]}]}'
expect_problems TC20 "advanced selector excluding an event source" ac6_selectors_eval \
  '{"AdvancedEventSelectors":[{"Name":"m","FieldSelectors":[{"Field":"eventCategory","Equals":["Management"]},{"Field":"eventSource","NotEquals":["kms.amazonaws.com"]}]}]}'
expect_problems TC20 "no selectors" ac6_selectors_eval '{}'
expect_clean TC21 "logging, delivered 10 minutes ago" ac6_status_eval "$TS" "$TS_NOW"
expect_problems TC25 "IsLogging false" ac6_status_eval "$(printf '%s' "$TS" | jx '.IsLogging = false')" "$TS_NOW"
expect_problems TC21 "delivery error" ac6_status_eval "$(printf '%s' "$TS" | jx '.LatestDeliveryError = "AccessDenied"')" "$TS_NOW"
expect_problems TC21 "digest delivery error" ac6_status_eval "$(printf '%s' "$TS" | jx '.LatestDigestDeliveryError = "x"')" "$TS_NOW"
expect_problems TC21 "last delivery 2 hours and 1 second ago" ac6_status_eval "$TS" $(($(to_epoch 2026-11-22T19:40:00Z) + 7201))
expect_clean TC21 "last delivery exactly 2 hours ago" ac6_status_eval "$TS" $(($(to_epoch 2026-11-22T19:40:00Z) + 7200))
expect_problems TC21 "no delivery yet" ac6_status_eval '{"IsLogging":true}' "$TS_NOW"

# TC30 read events, then the AC6 line with every stub good.
printf 'ListBuckets\t%s\tarn:a\t%s\nListBuckets\t%s\tarn:a\t%s\nListBuckets\t%s\tarn:a\t%s\n' "$M" 1800 "$A" 1000 "$O" 10 >"$WORK/ev.found"
expect_clean TC30 "ListBuckets seen for all three accounts within 30:00" ac6_reads_eval "" 0 "$WORK/ev.found" "$M" "$A" "$O"
expect_problems TC30 "management ListBuckets at 30:01" ac6_reads_eval "" -1 "$WORK/ev.found" "$M" "$A" "$O"
expect_problems TC30 "no read event for Offers Platform" ac6_reads_eval "" 0 "$WORK/ev.found" "$M" "$A" "$(fake_id 9)"
expect_problems TC30 "event phase skipped" ac6_reads_eval "no organization trail found" 0 "$WORK/ev.found" "$M" "$A" "$O"
FAKE_NOW=$TS_NOW
TRAIL_ARN="arn:aws:cloudtrail:us-east-1:$M:trail/aws-foundations-organization-trail"
TRAIL_BUCKET=aws-foundations-cloudtrail-fixture
printf '%s' "$TR" >"$WORK/trails.mgmt.json"
printf '%s' "$BK" >"$WORK/mgmt-buckets.json"
printf '%s' "$TS" >"$WORK/trail-status.json"
: >"$WORK/ev.notes.ac6"
EV_SKIP="" EV_LIST_AT=0
STUB_cloudtrail_get_event_selectors=$SEL
STUB_cloudtrail_describe_trails=$TR
STUB_cloudtrail_get_trail_status=True
expect_line TC22 "AC6 line: trail, selectors, status, other regions and reads all good" PASS AC6 check_ac6
STUB_cloudtrail_get_trail_status=False
expect_line TC22 "AC6 line: not logging as seen from another region" FAIL AC6 check_ac6 TC22
STUB_cloudtrail_get_trail_status=True
STUB_cloudtrail_describe_trails='{"trailList":[]}'
expect_line TC22 "AC6 line: trail not listed in another region" FAIL AC6 check_ac6 TC22
STUB_cloudtrail_describe_trails=$TR
FAKE_NOW=""

# ------------------------------------------------------------ TC26-TC29 (AC7)
T0=1795000000
SSO_ARN="arn:aws:sts::$A:assumed-role/AWSReservedSSO_Administrator_0123abcd/engineer"
expect_clean TC29 "both events seen exactly 30:00 after the delete" ac7_eval "" 1 $T0 $((T0 + 1800)) "$A" "$SSO_ARN" $((T0 + 1800)) "$A" "$SSO_ARN" "$A" 404
expect_problems TC29 "DeleteBucket first seen at 30:01" ac7_eval "" 1 $T0 $((T0 + 60)) "$A" "$SSO_ARN" $((T0 + 1801)) "$A" "$SSO_ARN" "$A" 404
LINE=$(ac7_eval "" 1 $T0 $((T0 + 60)) "$A" "$SSO_ARN" $((T0 + 1801)) "$A" "$SSO_ARN" "$A" 404)
printf '%s' "$LINE" | grep -q '30:01' && ok TC29 "late event reports the elapsed time (30:01)" || ko TC29 "late event message lacks the elapsed time: $LINE"
expect_problems TC29 "only CreateBucket seen" ac7_eval "" 1 $T0 $((T0 + 60)) "$A" "$SSO_ARN" "" "" "" "$A" 404
expect_problems TC29 "only DeleteBucket seen" ac7_eval "" 1 $T0 "" "" "" $((T0 + 60)) "$A" "$SSO_ARN" "$A" 404
expect_problems TC29 "neither event seen" ac7_eval "" 1 $T0 "" "" "" "" "" "" "$A" 404
expect_problems TC26 "events from another account" ac7_eval "" 1 $T0 $((T0 + 60)) "$M" "$SSO_ARN" $((T0 + 60)) "$M" "$SSO_ARN" "$A" 404
expect_problems TC27 "made by a non-Identity Center role" ac7_eval "" 1 $T0 $((T0 + 60)) "$A" "arn:aws:sts::$A:assumed-role/OrganizationAccountAccessRole/x" $((T0 + 60)) "$A" "$SSO_ARN" "$A" 404
expect_problems TC27 "made by the engineering permission set" ac7_eval "" 1 $T0 $((T0 + 60)) "$A" "arn:aws:sts::$A:assumed-role/AWSReservedSSO_ABCBankEngineering_1/x" $((T0 + 60)) "$A" "$SSO_ARN" "$A" 404
expect_problems TC28 "test bucket still exists" ac7_eval "" 1 $T0 $((T0 + 60)) "$A" "$SSO_ARN" $((T0 + 60)) "$A" "$SSO_ARN" "$A" exists
expect_problems TC28 "head-bucket 403" ac7_eval "" 1 $T0 $((T0 + 60)) "$A" "$SSO_ARN" $((T0 + 60)) "$A" "$SSO_ARN" "$A" "403: the name exists in another account"

# The event phase on a fake clock, with the AC7 stub answering create, delete,
# list and download calls. STUB_LM_OFFSET is when the log files land, in
# seconds after the delete.
ev_stub() {
  local p=$1 a prefix acct lm key dst
  shift
  case "$1 $2" in
    "s3api list-buckets") echo 3 ;;
    "s3api create-bucket")
      [ "${STUB_CREATE_FAIL:-0}" = 0 ] || { echo "An error occurred (AccessDenied)" >&2; return 254; }
      echo '{"Location":"/x"}'
      ;;
    "s3api put-bucket-tagging") ;;
    "s3api delete-bucket")
      [ "${STUB_DELETE_FAIL:-0}" = 0 ] || { echo "An error occurred (AccessDenied)" >&2; return 254; }
      STUB_BUCKET_GONE=1
      ;;
    "s3api head-bucket")
      [ "${STUB_BUCKET_GONE:-0}" = 1 ] || return 0
      echo "An error occurred (404) when calling the HeadBucket operation: Not Found" >&2
      return 254
      ;;
    "s3api list-objects-v2")
      prefix=""
      while [ $# -gt 0 ]; do
        [ "$1" != --prefix ] || prefix=$2
        shift
      done
      acct=$(printf '%s' "$prefix" | awk -F/ '{ print $3 }')
      lm=$((${EV_DELETE_AT:-$EV_LIST_AT} + STUB_LM_OFFSET))
      if [ "$FAKE_NOW" -ge "$lm" ]; then
        printf '[["%s%s_CloudTrail_us-east-1_x.json.gz","%s"]]\n' "$prefix" "$acct" "$(fmt_epoch "$lm" '%Y-%m-%dT%H:%M:%S+00:00')"
      else
        echo '[]'
      fi
      ;;
    "s3 cp")
      key=${3#s3://*/}
      dst=$4
      acct=$(printf '%s' "$key" | awk -F/ '{ print $3 }')
      a="arn:aws:sts::$acct:assumed-role/AWSReservedSSO_Administrator_0123abcd/engineer"
      {
        printf '{"Records":[{"eventName":"ListBuckets","eventTime":"%s","recipientAccountId":"%s","userIdentity":{"arn":"%s"}}' "$(iso_of "$EV_START")" "$acct" "$a"
        if [ "$acct" = "$A" ]; then
          printf ',{"eventName":"CreateBucket","eventTime":"%s","recipientAccountId":"%s","userIdentity":{"arn":"%s"},"requestParameters":{"bucketName":"%s"}}' \
            "$(iso_of "$EV_START")" "$acct" "${STUB_CREATOR_ARN:-$a}" "$TEST_BUCKET"
          [ "${STUB_ONLY_CREATE:-0}" = 1 ] ||
            printf ',{"eventName":"DeleteBucket","eventTime":"%s","recipientAccountId":"%s","userIdentity":{"arn":"%s"},"requestParameters":{"bucketName":"%s"}}' \
              "$(iso_of "$EV_START")" "$acct" "$a" "$TEST_BUCKET"
        fi
        printf ']}'
      } | gzip -c >"$dst"
      ;;
    *)
      echo "ev stub: unexpected call $1 $2" >&2
      return 254
      ;;
  esac
}

# ev_run DESC OFFSET [VAR=VALUE...]: one event phase, then the AC7 line.
ev_run() {
  local v
  WORK="$ST_TMP/ev.$RANDOM"
  mkdir -p "$WORK"
  fixture trail-status.json >"$WORK/trail-status.json"
  TRAIL_ARN="arn:aws:cloudtrail:us-east-1:$M:trail/aws-foundations-organization-trail"
  TRAIL_BUCKET=aws-foundations-cloudtrail-fixture TRAIL_KEY_PREFIX="" ORG_ID=$ORGF
  TEST_BUCKET="" TEST_BUCKET_CREATED=0 TEST_BUCKET_DELETED=0
  EV_SKIP="" EV_START="" EV_LIST_AT="" EV_DELETE_AT="" EV_HEAD=""
  STUB_BUCKET_GONE=0 STUB_CREATE_FAIL=0 STUB_DELETE_FAIL=0 STUB_ONLY_CREATE=0 STUB_CREATOR_ARN=""
  STUB_LM_OFFSET=$1
  shift
  for v in "$@"; do eval "$v"; done
  FAKE_NOW=$T0
  : >"$ST_CALLS"
  STUB_EV=1
  events_phase 2>/dev/null
  STUB_EV=0
}

ev_run 1800
expect_line TC26 "event phase: create and delete seen 30:00 after the delete" PASS AC7 check_ac7
expect_clean TC30 "event phase: ListBuckets seen for all three accounts" ac6_reads_eval "$EV_SKIP" "$EV_LIST_AT" "$WORK/ev.found" "$M" "$A" "$O"
grep -q "^ABC us-east-1 s3api create-bucket --bucket $TEST_BUCKET_PREFIX[0-9a-f]\{10\}" "$ST_CALLS" &&
  ok TC26 "test bucket is named ${TEST_BUCKET_PREFIX}<random>, created by the ABC Bank admin in us-east-1" ||
  ko TC26 "unexpected create-bucket call: $(grep create-bucket "$ST_CALLS" || echo none)"
grep -q 'put-bucket-tagging.*"Key":"data-product","Value":"aws-foundations".*"Key":"cost-center","Value":"offers-platform-portfolio"' "$ST_CALLS" &&
  ok TC26 "test bucket is tagged with the four cost tags" || ko TC26 "test bucket tagging call missing or wrong"
[ "$TEST_BUCKET_DELETED" = 1 ] && [ "$EV_HEAD" = 404 ] && ok TC28 "test bucket deleted and head-bucket returns 404" || ko TC28 "deleted=$TEST_BUCKET_DELETED head=$EV_HEAD"

ev_run 1801
expect_line TC29 "event phase: log files land at 30:01" FAIL AC7 check_ac7 "30:01"
ev_run 60 STUB_ONLY_CREATE=1
expect_line TC29 "event phase: only CreateBucket in the logs" FAIL AC7 check_ac7 "only CreateBucket"
ev_run 60 "STUB_CREATOR_ARN=arn:aws:sts::$A:assumed-role/OrganizationAccountAccessRole/x"
expect_line TC27 "event phase: CreateBucket made by another role" FAIL AC7 check_ac7 TC27

ev_run 60 STUB_DELETE_FAIL=1
expect_line TC28 "event phase: delete-bucket failed, bucket still there" FAIL AC7 check_ac7 TC28
STUB_DELETE_FAIL=0
STUB_EV=1
cleanup 2>/dev/null
STUB_EV=0
[ "$(grep -c "s3api delete-bucket --bucket $TEST_BUCKET" "$ST_CALLS")" = 2 ] && ok TC28 "trap cleanup deletes the test bucket on exit" ||
  ko TC28 "cleanup did not retry delete-bucket"
[ ! -d "$WORK" ] && ok TC74 "cleanup removes the scratch directory" || ko TC74 "scratch directory left behind"

ev_run 60 STUB_CREATE_FAIL=1
expect_line TC26 "event phase: create-bucket refused" FAIL AC7 check_ac7 "create-bucket failed"

ev_run 60 'TRAIL_ARN=""' 'TRAIL_BUCKET=""'
expect_line TC26 "no organization trail: AC7 fails fast" FAIL AC7 check_ac7 "not created"
grep -q create-bucket "$ST_CALLS" && ko TC26 "no organization trail, yet create-bucket was called" || ok TC26 "no organization trail: no bucket created, no AWS call made"
ev_run 60 'printf "{\"IsLogging\":false}" >"$WORK/trail-status.json"'
expect_line TC26 "organization trail not logging: AC7 fails fast" FAIL AC7 check_ac7 "not logging"
grep -q create-bucket "$ST_CALLS" && ko TC26 "trail not logging, yet create-bucket was called" || ok TC26 "trail not logging: no bucket created"
WORK="$ST_TMP/work"
FAKE_NOW=""

# ------------------------------------------------------------ TC31-TC33 (AC8)
for f in valid digest-only zero invalid missing; do
  eval "VL_$(printf '%s' "$f" | tr '-' '_')=\$(fixture validate-logs-$f.txt)"
done
expect_clean TC31 "1/1 digest and 17/17 log files valid" ac8_validate_eval "$VL_valid" 0 management yes
expect_problems TC33 "0/0 digest files valid" ac8_validate_eval "$VL_zero" 0 management yes
expect_problems TC33 "1 digest file INVALID" ac8_validate_eval "$VL_invalid" 0 management yes
expect_problems TC33 "a log file reported missing" ac8_validate_eval "$VL_missing" 0 management yes
expect_problems TC33 "no log file validated (management)" ac8_validate_eval "$VL_digest_only" 0 management yes
expect_clean TC31 "member hour with a digest and no log files" ac8_validate_eval "$VL_digest_only" 0 abc_bank no
expect_problems TC31 "validate-logs exit 1" ac8_validate_eval "$VL_valid" 1 management yes
printf '%s' "$TS" | jx --arg s "$(iso_of $((T0 - 3600)))" '.StartLoggingTime = $s' >"$WORK/trail-status.json"
FAKE_NOW=$T0
TRAIL_ARN="arn:aws:cloudtrail:us-east-1:$M:trail/aws-foundations-organization-trail"
expect_line TC32 "logging started 1 hour ago: MANUAL rerun after" MANUAL AC8 check_ac8 "rerun after $(iso_of $((T0 + 3600)))"
printf '%s' "$TS" | jx --arg s "$(iso_of $((T0 - 7199)))" '.StartLoggingTime = $s' >"$WORK/trail-status.json"
expect_line TC32 "logging started 1:59:59 ago: still MANUAL" MANUAL AC8 check_ac8 "rerun after"
printf '%s' "$TS" | jx --arg s "$(iso_of $((T0 - 10800)))" '.StartLoggingTime = $s' >"$WORK/trail-status.json"
STUB_cloudtrail_validate_logs=$VL_valid
expect_line TC31 "logging 3 hours: validate-logs valid in all three accounts" PASS AC8 check_ac8
grep -q "validate-logs .*--account-id $A" "$ST_CALLS" && grep -q "validate-logs .*--account-id $O" "$ST_CALLS" &&
  ok TC31 "validate-logs runs with --account-id for both members" || ko TC31 "member validate-logs calls missing"
# Revision 3: an organization trail needs --account-id for the management account too.
grep -q "validate-logs .*--account-id $M" "$ST_CALLS" && ! grep "validate-logs" "$ST_CALLS" | grep -vq -- "--account-id" &&
  ok TC31 "validate-logs runs with --account-id for the management account" || ko TC31 "management validate-logs call omits --account-id"
STUB_cloudtrail_validate_logs=$VL_invalid
expect_line TC33 "AC8 line, a digest file INVALID" FAIL AC8 check_ac8 TC33
FAKE_NOW=""

# ------------------------------------------------------------ TC34-TC40 (AC9)
LC=$(fixture bucket-lifecycle.json)
expect_clean TC37 "90-day and 30-day whole-bucket rule, delete markers rule" ac9_lifecycle_eval "$LC"
expect_problems TC39 "expiration 89 days" ac9_lifecycle_eval "$(printf '%s' "$LC" | jx '.Rules[0].Expiration.Days = 89')"
expect_problems TC39 "expiration 91 days" ac9_lifecycle_eval "$(printf '%s' "$LC" | jx '.Rules[0].Expiration.Days = 91')"
expect_problems TC39 "noncurrent 29 days" ac9_lifecycle_eval "$(printf '%s' "$LC" | jx '.Rules[0].NoncurrentVersionExpiration.NoncurrentDays = 29')"
expect_problems TC39 "noncurrent 31 days" ac9_lifecycle_eval "$(printf '%s' "$LC" | jx '.Rules[0].NoncurrentVersionExpiration.NoncurrentDays = 31')"
expect_problems TC39 "rule Disabled" ac9_lifecycle_eval "$(printf '%s' "$LC" | jx '.Rules[0].Status = "Disabled"')"
expect_problems TC39 "rule filtered to AWSLogs/ only" ac9_lifecycle_eval "$(printf '%s' "$LC" | jx '.Rules[0].Filter = {"Prefix":"AWSLogs/"}')"
expect_problems TC39 "no noncurrent rule" ac9_lifecycle_eval "$(printf '%s' "$LC" | jx 'del(.Rules[0].NoncurrentVersionExpiration)')"
expect_problems TC38 "no expired delete marker rule" ac9_lifecycle_eval "$(printf '%s' "$LC" | jx '.Rules |= [.[0]]')"
expect_problems TC39 "no lifecycle configuration" ac9_lifecycle_eval ''
expect_clean TC34 "versioning Enabled" ac9_versioning_eval "$(fixture bucket-versioning.json)"
expect_problems TC39 "versioning Suspended" ac9_versioning_eval '{"Status":"Suspended"}'
PAB=$(fixture bucket-pab.json)
expect_clean TC35 "all four public access block settings true" ac9_pab_eval "$PAB"
for k in BlockPublicAcls IgnorePublicAcls BlockPublicPolicy RestrictPublicBuckets; do
  expect_problems TC39 "$k false" ac9_pab_eval "$(printf '%s' "$PAB" | jx --arg k "$k" '.PublicAccessBlockConfiguration[$k] = false')"
done
POL=$(fixture bucket-policy.json | jq -c .)
ACL=$(fixture bucket-acl.json)
PS=$(fixture bucket-policy-status.json)
expect_clean TC35 "not public; owner-only ACL; CloudTrail-only policy with TLS deny" ac9_public_eval "$PS" "$ACL" "$POL"
expect_problems TC35 "policy status IsPublic true" ac9_public_eval '{"PolicyStatus":{"IsPublic":true}}' "$ACL" "$POL"
expect_problems TC35 "ACL grants READ to AllUsers" ac9_public_eval "$PS" \
  "$(printf '%s' "$ACL" | jx '.Grants += [{"Grantee":{"Type":"Group","URI":"http://acs.amazonaws.com/groups/global/AllUsers"},"Permission":"READ"}]')" "$POL"
expect_problems TC35 "policy allows Principal * without a condition" ac9_public_eval "$PS" "$ACL" \
  "$(printf '%s' "$POL" | jx '.Statement += [{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"*"}]')"
expect_problems TC35 "policy allows AWS * without a condition" ac9_public_eval "$PS" "$ACL" \
  "$(printf '%s' "$POL" | jx '.Statement += [{"Effect":"Allow","Principal":{"AWS":"*"},"Action":"s3:GetObject","Resource":"*"}]')"
expect_clean TC36 "AES256" ac9_encryption_eval "$(fixture bucket-encryption.json)"
expect_problems TC36 "aws:kms" ac9_encryption_eval '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}}'
expect_problems TC36 "aws:kms:dsse" ac9_encryption_eval '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms:dsse"}}]}}'
expect_clean TC40 "location null is us-east-1" ac9_location_eval "$(fixture bucket-location.json)"
expect_problems TC40 "location eu-west-1" ac9_location_eval '{"LocationConstraint":"eu-west-1"}'

STUB_s3api_get_bucket_versioning=$(fixture bucket-versioning.json)
STUB_s3api_get_public_access_block=$PAB
STUB_s3api_get_bucket_policy=$POL
STUB_s3api_get_bucket_policy_status=$PS
STUB_s3api_get_bucket_acl=$ACL
STUB_s3api_get_bucket_encryption=$(fixture bucket-encryption.json)
STUB_s3api_get_bucket_lifecycle_configuration=$LC
STUB_s3api_get_bucket_location=$(fixture bucket-location.json)
TRAIL_BUCKET=aws-foundations-cloudtrail-fixture
printf '%s' "$BK" >"$WORK/mgmt-buckets.json"
expect_line TC39 "AC9 line with the good stub" PASS AC9 check_ac9
STUB_s3api_get_bucket_versioning='{"Status":"Suspended"}'
expect_line TC39 "AC9 line, versioning Suspended" FAIL AC9 check_ac9 TC34
STUB_s3api_get_bucket_versioning=$(fixture bucket-versioning.json)
STUB_s3api_get_bucket_lifecycle_configuration=$(printf '%s' "$LC" | jx '.Rules[0].Filter = {"Prefix":"AWSLogs/"}')
expect_line TC39 "AC9 line, lifecycle filtered to AWSLogs/" FAIL AC9 check_ac9 TC37
STUB_s3api_get_bucket_lifecycle_configuration=$LC
printf '["other"]' >"$WORK/mgmt-buckets.json"
expect_line TC40 "AC9 line, bucket not in the management account" FAIL AC9 check_ac9 TC40
printf '%s' "$BK" >"$WORK/mgmt-buckets.json"

# ------------------------------------------------------------ TC41-TC43 (AC10 pure parts)
expect_clean TC41 "ABC Bank sees the management-owned organization trail" ac10_trail_eval "$TR" "$M" "$TRAIL_ARN" abc_bank
expect_problems TC41 "trail not visible" ac10_trail_eval '{"trailList":[]}' "$M" "$TRAIL_ARN" abc_bank
expect_problems TC41 "IsOrganizationTrail false" ac10_trail_eval "$(printf '%s' "$TR" | jx '.trailList[0].IsOrganizationTrail = false')" "$M" "$TRAIL_ARN" abc_bank
expect_clean TC42 "member budgets list empty" ac10_budgets_eval 0 "" '{"Budgets":[]}' "$DEFAULT_BUDGET_NAME" 100 '[]' abc_bank
expect_clean TC42 "member NotFoundException" ac10_budgets_eval 254 "An error occurred (NotFoundException)" "" "$DEFAULT_BUDGET_NAME" 100 '[]' abc_bank
expect_problems TC42 "member AccessDenied is inconclusive" ac10_budgets_eval 254 "An error occurred (AccessDeniedException)" "" "$DEFAULT_BUDGET_NAME" 100 '[]' abc_bank
expect_problems TC42 "member has the organization budget name" ac10_budgets_eval 0 "" "$B" "$DEFAULT_BUDGET_NAME" 100 '[]' abc_bank
expect_problems TC42 "member has the organization budget definition" ac10_budgets_eval 0 "" "$(printf '%s' "$B" | jx '.Budgets[0].BudgetName = "copy"')" "$DEFAULT_BUDGET_NAME" 100 '[]' abc_bank
expect_clean TC43 "Offers Platform budget kept under requirement 7 is allowed" ac10_budgets_eval 0 "" \
  "$(printf '%s' "$B" | jx '.Budgets[0].BudgetName = "offers-v2-monthly"')" "$DEFAULT_BUDGET_NAME" 100 '["offers-v2-monthly"]' offers_platform

# ------------------------------------------------------------ TC47-TC61 (AC11)
BT=$(BASELINE=$BASE_FIX baseline_op_trails)
[ "$(printf '%s\n' "$BT" | sed '/^$/d' | wc -l | tr -d ' ')" = 2 ] && ok TC49 "baseline op-trails.json: two trails found" || ko TC49 "baseline trails parsed: $BT"
k1=$(t=$(printf '%s\n' "$BT" | jq -c 'select(.name == "old-trail")'); ac11_trail_kind "$(printf '%s' "$t" | jq -c .trail)" "$(printf '%s' "$t" | jq -c .selectors)" "$(printf '%s' "$t" | jq -c '.insights // {}')")
k2=$(t=$(printf '%s\n' "$BT" | jq -c 'select(.name == "data-trail")'); ac11_trail_kind "$(printf '%s' "$t" | jq -c .trail)" "$(printf '%s' "$t" | jq -c .selectors)" "$(printf '%s' "$t" | jq -c '.insights // {}')")
[ "$k1" = management-only ] && [ "$k2" = other ] && ok TC47 "old-trail is management-only; data-trail is not" || ko TC47 "kinds: $k1 / $k2"
st=$(printf '%s\n' "$BT" | jq -r 'select(.name == "old-trail") | .status.IsLogging')
[ "$st" = true ] && ok TC51 "baseline trail status found one level down" || ko TC51 "baseline status: $st"
[ "$(ac11_trail_kind '{"SnsTopicARN":"arn:s"}' '{"EventSelectors":[{"IncludeManagementEvents":true}]}' '{}')" = other ] &&
  ok TC47 "a trail with an SNS destination is not management-only" || ko TC47 "SNS trail misclassified"
[ "$(ac11_trail_kind '{}' '{"EventSelectors":[{"IncludeManagementEvents":true}]}' '{"InsightSelectors":[{"InsightType":"ApiCallRateInsight"}]}')" = other ] &&
  ok TC47 "a trail with Insights is not management-only" || ko TC47 "Insights trail misclassified"
[ "$(ac11_trail_kind '{}' '{"AdvancedEventSelectors":[{"FieldSelectors":[{"Field":"eventCategory","Equals":["NetworkActivity"]}]}]}' '{}')" = other ] &&
  ok TC47 "a trail with network-activity events is not management-only" || ko TC47 "network-activity trail misclassified"

SEC="$ST_TMP/section.md"
NAMES="$ST_TMP/names.tsv"
readme_section "$FIX/readme-op-section.md" >"$SEC"
head -n 1 "$SEC" | grep -q '^## Offers Platform existing setup' && ! grep -q '^## Next section' "$SEC" && ! grep -q 'Something else' "$SEC" &&
  ok TC48 "README section extracted up to the next heading of the same level" || ko TC48 "section extraction wrong"
printf 'trail\told-trail\tremoved\ntrail\tdata-trail\tkept\nbudget\toffers-v2-monthly\tpresent\n' >"$NAMES"
expect_clean TC48 "README lists every baseline item with an action; none found for monitors" ac11_readme_eval "$SEC" "$NAMES"
grep -v 'offers-v2-monthly' "$SEC" >"$SEC.2"
expect_problems TC49 "README misses a baseline budget" ac11_readme_eval "$SEC.2" "$NAMES"
sed 's/| Anomaly monitor | none found | | |/| Anomaly monitor | `ghost-monitor` | x | Kept |/' "$SEC" >"$SEC.3"
expect_problems TC49 "README lists a monitor absent from the baseline" ac11_readme_eval "$SEC.3" "$NAMES"
sed 's/about \$0.40 per month/cost not stated/' "$SEC" >"$SEC.4"
expect_problems TC52 "kept trail without its monthly cost" ac11_readme_eval "$SEC.4" "$NAMES"
sed 's/^| Trail | `old-trail` .*/| Trail | `old-trail` | management events only | (nothing) |/' "$SEC" >"$SEC.5"
expect_problems TC48 "README item without what was done" ac11_readme_eval "$SEC.5" "$NAMES"
expect_problems TC48 "README without the section" ac11_readme_eval /dev/null "$NAMES"
expect_clean TC60 "procedure: reader checks, tagged copy, count check, delete-trail; old bucket kept" ac11_procedure_eval "$SEC"
awk '/^4\. Delete the trail/ { hold = 1 } hold && /delete-trail --name/ { d = $0; next } { print } END { }' "$SEC" >"$SEC.6"
awk '/^### Removing a duplicate trail/ { print; print "       aws cloudtrail delete-trail --name \"$OLD_TRAIL_ARN\""; next } { print }' "$SEC.6" >"$SEC.7"
expect_problems TC60 "delete-trail before the reader checks" ac11_procedure_eval "$SEC.7"
grep -v 'list-access-points' "$SEC" >"$SEC.8"
expect_problems TC60 "reader check missing (access points)" ac11_procedure_eval "$SEC.8"
grep -v 'old bucket is kept' "$SEC" >"$SEC.9"
expect_problems TC60 "does not say the old bucket is kept" ac11_procedure_eval "$SEC.9"

[ "$(count_sensitive <"$FIX/readme-op-section.md")" = 0 ] && ok TC53 "fixture README has no 12-digit number or e-mail" || ko TC53 "fixture README flagged"
[ "$(printf 'x %s y\n' "$M" | count_sensitive)" = 1 ] && ok TC53 "a 12-digit number is flagged" || ko TC53 "12-digit number not flagged"
[ "$(printf 'to %s\n' "$FAKE_EMAIL" | count_sensitive)" = 1 ] && ok TC53 "an e-mail address is flagged" || ko TC53 "e-mail not flagged"
[ "$(printf 'alert_email = "alerts@example.com"\n' | count_sensitive)" = 0 ] && ok TC53 "the example.com placeholder is allowed" || ko TC53 "placeholder flagged"
[ "$(printf 'alerts@example.com and %s\n' "$M" | count_sensitive)" = 1 ] && ok TC53 "a placeholder does not hide an account ID on the same line" || ko TC53 "ID next to placeholder not flagged"
[ "$(printf 'echo x@example.com > out-3.txt; sleep 15 # step 2 of 4\n' | count_sensitive)" = 0 ] && ok TC53 "a placeholder on a line with other (non-12-digit) digits is allowed" || ko TC53 "placeholder with other digits flagged"
[ "$(printf 'a@example.com, b@example.org. c@example.net\n' | count_sensitive)" = 0 ] && ok TC53 "several placeholders on one line are allowed" || ko TC53 "several placeholders flagged"
[ "$(printf 'alerts@example.com and %s\n' "$FAKE_EMAIL" | count_sensitive)" = 1 ] && ok TC53 "a placeholder does not hide a real e-mail address on the same line" || ko TC53 "real e-mail next to placeholder not flagged"
[ "$(printf 'to %s@example.com\n' "$M" | count_sensitive)" = 1 ] && ok TC53 "a 12-digit number inside a placeholder address is flagged" || ko TC53 "12-digit local part not flagged"
[ "$(printf 'to ops%sexample.com.au\n' "$(printf '\100')" | count_sensitive)" = 1 ] && ok TC53 "example.com.au is not a placeholder domain" || ko TC53 "example.com.au treated as a placeholder"

# TC53 committed-diff scan: tests/ and docs/ are not scanned; other files (README.md included) are.
TC53R="$ST_TMP/tc53-repo"
tc53_git() { git -C "$TC53R" -c user.name=selftest -c user.email=selftest@example.com -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
mkdir -p "$TC53R"
git init -q "$TC53R" >/dev/null 2>&1
printf 'base\n' >"$TC53R/README.md"
tc53_git add -A && tc53_git commit -q -m base
TC53B=$(git -C "$TC53R" rev-parse HEAD)
mkdir -p "$TC53R/tests/fixtures" "$TC53R/docs/stories" "$TC53R/guardrails"
printf 'jq 1000 %s\n' "$M" >"$TC53R/tests/x.sh"
printf 'arn:aws:s3:::b-%s\n' "$M" >"$TC53R/tests/fixtures/f.json"
printf 'to %s %s\n' "$FAKE_EMAIL" "$A" >"$TC53R/docs/stories/plan.md"
tc53_git add -A && tc53_git commit -q -m tests-docs
[ "$(tc53_diff_count "$TC53R" "$TC53B")" = 0 ] && ok TC53 "IDs and addresses under tests/ and docs/ are not scanned" || ko TC53 "tests/ or docs/ scanned: $(tc53_diff_count "$TC53R" "$TC53B")"
printf 'variable "x" { default = "%s" }\n' "$M" >"$TC53R/guardrails/main.tf"
tc53_git add -A && tc53_git commit -q -m tf
[ "$(tc53_diff_count "$TC53R" "$TC53B")" = 1 ] && ok TC53 "a 12-digit number in a scanned non-test file is flagged" || ko TC53 "12-digit number in guardrails/main.tf: count $(tc53_diff_count "$TC53R" "$TC53B")"
printf 'mail %s\n' "$FAKE_EMAIL" >>"$TC53R/README.md"
printf 'id %s\n' "$O" >"$TC53R/testsuite.txt"
tc53_git add -A && tc53_git commit -q -m readme
[ "$(tc53_diff_count "$TC53R" "$TC53B")" = 3 ] && ok TC53 "README.md and a root file named like tests* are still scanned" || ko TC53 "README.md or testsuite.txt not scanned: count $(tc53_diff_count "$TC53R" "$TC53B")"

SRC="$ST_TMP/src" DST="$ST_TMP/dst"
fixture legacy-src-keys.txt >"$SRC"
fixture legacy-dst-keys.txt >"$DST"
expect_clean TC56 "key sets match; 3 logs and 2 digests each" ac11_copy_eval "$SRC" "$DST" 5 3 2
sed '$d' "$DST" >"$DST.1"
expect_problems TC58 "copy has one object fewer" ac11_copy_eval "$SRC" "$DST.1" 5 3 2
sed '1s/a1\.json\.gz/renamed.json.gz/' "$DST" >"$DST.2"
expect_problems TC58 "equal counts but one key renamed" ac11_copy_eval "$SRC" "$DST.2" 5 3 2
grep -v CloudTrail-Digest "$SRC" >"$SRC.3"
grep -v CloudTrail-Digest "$DST" >"$DST.3"
expect_problems TC58 "digest files missing from source and copy" ac11_copy_eval "$SRC.3" "$DST.3" "" "" ""
expect_problems TC56 "copy counts differ from legacy-copy.json" ac11_copy_eval "$SRC" "$DST" 5 4 2
expect_problems TC55 "old prefix has fewer objects than at the copy" ac11_copy_eval "$SRC" "$DST" 6 3 2
TG=$(fixture object-tagging.json)
[ "$(legacy_tag_state "$TG")" = ok ] && ok TC57 "tag source=offers-platform-account-trail" || ko TC57 "good tag rejected"
[ "$(legacy_tag_state '{"TagSet":[]}')" = missing ] && ok TC58 "object without the tag" || ko TC58 "untagged object not caught"
[ "$(legacy_tag_state "$(printf '%s' "$TG" | jx '.TagSet[0].Value = "offers-platform"')")" = wrong ] && ok TC58 "source=offers-platform is wrong" || ko TC58 "wrong tag value not caught"
expect_clean TC59 "no trail removed and the legacy prefix is empty: not applicable, passes" ac11_no_record_eval no 0
expect_problems TC59 "no trail removed but objects under the legacy prefix" ac11_no_record_eval no 3
expect_problems TC59 "legacy prefix could not be listed" ac11_no_record_eval no ""
expect_clean TC59 "a trail was removed: TC59 does not apply" ac11_no_record_eval yes 3

GS='{"values":{"root_module":{"resources":[{"address":"aws_cloudtrail.organization","mode":"managed","type":"aws_cloudtrail","values":{"arn":"arn:aws:cloudtrail:us-east-1:'"$M"':trail/t","is_organization_trail":true}},{"address":"aws_s3_bucket.trail","mode":"managed","type":"aws_s3_bucket","values":{"arn":"arn:aws:s3:::b"}}]}}}'
mkdir -p "$ST_TMP/tfdir"
printf 'provider "aws" {\n  region = "us-east-1"\n}\n' >"$ST_TMP/tfdir/providers.tf"
expect_clean TC61 "state ARNs in the management account; organization trail only; no alias" tc61_eval "$GS" "$M" "$ST_TMP/tfdir"
expect_problems TC61 "an Offers Platform trail in state" tc61_eval \
  "$(printf '%s' "$GS" | jx --arg o "$O" '.values.root_module.resources += [{"mode":"managed","type":"aws_cloudtrail","values":{"arn":("arn:aws:cloudtrail:us-east-1:" + $o + ":trail/old"),"is_organization_trail":false}}]')" "$M" "$ST_TMP/tfdir"
printf 'provider "aws" {\n  alias  = "offers_platform"\n  region = "us-east-1"\n}\n' >"$ST_TMP/tfdir/members.tf"
expect_problems TC61 "a member-account provider alias" tc61_eval "$GS" "$M" "$ST_TMP/tfdir"
expect_problems TC61 "state unreadable" tc61_eval "" "$M" /nonexistent

# ------------------------------------------------------------ TC62, TC63 (AC12)
GOOD_TAGS=$(fixture tags-good.json | jq -c .)
expect_clean TC63 "four correct tags" tags_eval TC62 r "$GOOD_TAGS"
expect_clean TC63 "four correct tags plus extra unrelated tags" tags_eval TC62 r "$(printf '%s' "$GOOD_TAGS" | jx '. + [{"Key":"Name","Value":"x"}]')"
expect_problems TC63 "one tag missing" tags_eval TC62 r "$(printf '%s' "$GOOD_TAGS" | jx 'map(select(.Key != "cost-center"))')"
expect_problems TC63 "environment=prod" tags_eval TC62 r "$(printf '%s' "$GOOD_TAGS" | jx 'map(if .Key == "environment" then .Value = "prod" else . end)')"
expect_problems TC63 "key Owner instead of owner" tags_eval TC62 r "$(printf '%s' "$GOOD_TAGS" | jx 'map(if .Key == "owner" then .Key = "Owner" else . end)')"
expect_problems TC63 "tags could not be read" tags_eval TC62 r ''
STUB_cloudtrail_list_tags=$(printf '{"ResourceTagList":[{"ResourceId":"x","TagsList":%s}]}' "$GOOD_TAGS")
STUB_s3api_get_bucket_tagging=$(printf '{"TagSet":%s}' "$GOOD_TAGS")
STUB_budgets_list_tags_for_resource=$(printf '{"ResourceTags":%s}' "$GOOD_TAGS")
STUB_ce_list_tags_for_resource=$(printf '{"ResourceTags":%s}' "$GOOD_TAGS")
STUB_ce_get_anomaly_monitors=$MON
TRAIL_ARN="arn:aws:cloudtrail:us-east-1:$M:trail/aws-foundations-organization-trail"
TRAIL_BUCKET=aws-foundations-cloudtrail-fixture
expect_line TC62 "AC12 line, all four resources tagged" PASS AC12 check_ac12
BAD=$(printf '%s' "$GOOD_TAGS" | jx 'map(if .Key == "owner" then .Key = "Owner" else . end)')
for v in STUB_cloudtrail_list_tags STUB_s3api_get_bucket_tagging STUB_budgets_list_tags_for_resource STUB_ce_list_tags_for_resource; do
  eval "SAVE=\$$v"
  case $v in
    STUB_cloudtrail_list_tags) eval "$v=\$(printf '{\"ResourceTagList\":[{\"ResourceId\":\"x\",\"TagsList\":%s}]}' \"\$BAD\")" ;;
    STUB_s3api_get_bucket_tagging) eval "$v=\$(printf '{\"TagSet\":%s}' \"\$BAD\")" ;;
    *) eval "$v=\$(printf '{\"ResourceTags\":%s}' \"\$BAD\")" ;;
  esac
  expect_line TC63 "AC12 line, Owner key on ${v#STUB_}" FAIL AC12 check_ac12 "tag owner missing"
  eval "$v=\$SAVE"
done
grep -v aws_ce_anomaly_monitor "$WORK/state.guardrails" >"$WORK/state.tmp" && mv "$WORK/state.tmp" "$WORK/state.guardrails"
expect_line TC62 "AC12 line, monitor not in Terraform state" FAIL AC12 check_ac12 "no aws_ce_anomaly_monitor"

# ------------------------------------------------------------ REG-TC72 helpers
mkdir -p "$ST_TMP/tf72"
printf 'variable "a" {\n  description = "x"\n  type        = string\n  default     = "y"\n}\n\noutput "b" {\n  description = "z"\n  value       = 1\n}\n' >"$ST_TMP/tf72/ok.tf"
printf 'variable "c" {\n  type = map(string)\n  default = {\n    description = "nested, not the block description"\n  }\n}\n' >"$ST_TMP/tf72/bad.tf"
[ -z "$(tf_desc_eval "$ST_TMP/tf72/ok.tf")" ] && ok TC72 "documented variable and output pass" || ko TC72 "documented blocks flagged"
tf_desc_eval "$ST_TMP/tf72/bad.tf" | grep -q 'variable c' && ok TC72 "variable without a description (only a nested key) is flagged" || ko TC72 "undocumented variable not flagged"

# ------------------------------------------------------------ redaction
R=$(printf 'acct %s:%s mail %s\n' "$M" "$A" "$FAKE_EMAIL" | redact)
printf '%s' "$R" | grep -qE "$M|$A|$FAKE_EMAIL" && ko TC74 "redact leaves an ID or e-mail: $R" || ok TC74 "output filter masks account IDs and e-mail addresses -> $R"

# ------------------------------------------------------------ TC74 (whole script, stub commands)
STUB_BIN="$ST_TMP/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/aws" <<'EOF'
#!/usr/bin/env bash
# Stub aws: logs every call; the profile in FND4_STUB_MISSING does not exist;
# sts returns a fake account per profile; every other call returns {}.
printf '%s\n' "$*" >>"$FND4_STUB_LOG"
p=""
prev=""
for a in "$@"; do
  [ "$prev" != --profile ] || p=$a
  prev=$a
done
if [ -n "$FND4_STUB_MISSING" ] && [ "$p" = "$FND4_STUB_MISSING" ]; then
  echo "The config profile ($p) could not be found" >&2
  exit 255
fi
case "$p" in
  fnd-management-admin) id=$FND4_STUB_M ;;
  fnd-abc-bank-admin | fnd-abc-bank-engineering) id=$FND4_STUB_A ;;
  fnd-offers-platform-admin) id=$FND4_STUB_O ;;
  *) id="" ;;
esac
for a in "$@"; do
  if [ "$a" = get-caller-identity ]; then
    printf '{"Account":"%s","Arn":"arn:aws:sts::%s:assumed-role/AWSReservedSSO_Administrator_0123abcd/engineer"}\n' "$id" "$id"
    exit 0
  fi
done
echo '{}'
EOF
cat >"$STUB_BIN/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform stub: $*" >&2
exit 1
EOF
chmod +x "$STUB_BIN/aws" "$STUB_BIN/terraform"

EXPECTED_IDS="AC1 AC2 AC3 AC4 AC5 AC6 AC7 AC8 AC9 AC10 AC11 AC12 AC13 AC14 REG-TC68 REG-TC69 REG-TC70 REG-TC71 REG-TC72"

# run_stubbed CASE DESC BASELINE_DIR MISSING_PROFILE
run_stubbed() {
  local case=$1 desc=$2 base=$3 miss=$4 tmp="$ST_TMP/run.$RANDOM" out err rc=0 ids bad calls="$ST_TMP/stub-calls.$RANDOM"
  mkdir -p "$tmp"
  : >"$calls"
  out=$(PATH="$STUB_BIN:$PATH" FND4_STUB_MISSING="$miss" FND4_STUB_LOG="$calls" FND4_STUB_M="$M" FND4_STUB_A="$A" FND4_STUB_O="$O" \
    FND4_TMPDIR="$tmp" FND4_BASELINE_DIR="$base" FND4_ALERT_EMAIL="$FAKE_EMAIL" bash "$SCRIPT" 2>"$tmp.err") || rc=$?
  err=$(cat "$tmp.err")
  ids=$(printf '%s\n' "$out" | awk '{ print $2 }' | tr '\n' ' ' | sed 's/ $//')
  bad=$(printf '%s\n' "$out" | grep -cvE '^(PASS|FAIL|MANUAL) (AC[0-9]+|REG-TC(68|69|70|71|72)) ' || true)
  [ "$rc" = 1 ] && ok "$case" "$desc: exit 1" || ko "$case" "$desc: exit $rc, expected 1"
  [ "$ids" = "$EXPECTED_IDS" ] && ok "$case" "$desc: AC1..AC14 in order, then REG-TC68..REG-TC72" || ko "$case" "$desc: line IDs were '$ids'"
  [ "$bad" = 0 ] && ok "$case" "$desc: no other lines on stdout" || ko "$case" "$desc: $bad stray stdout line(s)"
  printf '%s\n%s\n' "$out" "$err" | grep -qF "$FAKE_EMAIL" && ko "$case" "$desc: the engineer e-mail appears in the output" ||
    ok "$case" "$desc: the engineer e-mail never appears (stdout or stderr)"
  printf '%s\n%s\n' "$out" "$err" | grep -qE "$M|$A|$O" && ko "$case" "$desc: an account ID appears in the output" ||
    ok "$case" "$desc: no account ID in the output"
  grep -qE 'create-bucket|delete-bucket|put-bucket|put-object|stop-logging|delete-trail|update-trail|terraform apply' "$calls" &&
    ko "$case" "$desc: a changing call was made: $(grep -E 'create-bucket|delete-bucket|put-|stop-logging|delete-trail|update-trail' "$calls" | head -n 1)" ||
    ok "$case" "$desc: no AWS change (no create, delete, put, stop-logging or update-trail call)"
  printf '%s\n' "$out" | grep -qE '^FAIL AC7 .*not created' && ok "$case" "$desc: AC7 fails fast without creating its bucket" ||
    ko "$case" "$desc: AC7 line: $(printf '%s\n' "$out" | grep ' AC7 ')"
  [ -z "$(ls -A "$tmp")" ] && ok "$case" "$desc: scratch directory removed (no clone or plan file left)" ||
    ko "$case" "$desc: left behind: $(ls -A "$tmp" | tr '\n' ' ')"
  rm -f "$tmp.err"
  RUN_OUT=$out
}

grep -qx 'set -euo pipefail' "$SCRIPT" && ok TC74 "script uses set -euo pipefail" || ko TC74 "set -euo pipefail missing"
grep -nE '(awsp|awsr|aws_call|aws_capture)[^|]*(stop-logging|delete-trail)' "$SCRIPT" >/dev/null &&
  ko TC74 "script calls stop-logging or delete-trail" || ok TC74 "script never calls stop-logging or delete-trail"

RUN_OUT=""
run_stubbed TC74 "one profile missing" "$BASE_FIX" fnd-abc-bank-engineering
printf '%s\n' "$RUN_OUT" | grep -qE '^FAIL REG-TC69 ' && ok TC74 "missing engineering profile: REG-TC69 FAIL, not an abort" ||
  ko TC74 "missing profile: REG-TC69 line: $(printf '%s\n' "$RUN_OUT" | grep REG-TC69)"
EMPTY_BASE="$ST_TMP/empty-baseline"
mkdir -p "$EMPTY_BASE"
run_stubbed TC74 "baseline directory empty" "$EMPTY_BASE" ""
printf '%s\n' "$RUN_OUT" | grep -qE '^FAIL AC4 .*baseline missing' && printf '%s\n' "$RUN_OUT" | grep -qE '^FAIL AC11 .*baseline missing' &&
  ok TC74 "empty baseline: AC4 and AC11 FAIL with baseline missing" || ko TC74 "empty baseline: AC4/AC11 did not FAIL with baseline missing"
run_stubbed TC74 "baseline directory does not exist" "$ST_TMP/no-such-dir" ""

[ "$ST_FAIL" = 0 ] || exit 1
exit 0
