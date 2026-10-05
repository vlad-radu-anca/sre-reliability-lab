#!/usr/bin/env bash
# Runs one game-day scenario against the running platform and checks that the
# alerting behaves as designed:
#
#   1. start steady user traffic (load/k6.yaml) and let a clean baseline build up
#   2. inject the fault from chaos/
#   3. assert on Alertmanager: the expected page fires and reaches the receiver,
#      and the alerts that should stay silent do
#   4. remove the fault and the traffic, and print a summary
#
# Usage: scripts/gameday.sh latency|outage|pod-kill
# Exits non-zero if alerting did not behave as expected. Needs kubectl, curl
# and jq, and a cluster deployed from gitops-platform with the SRE layer.
set -euo pipefail

SCENARIO="${1:?usage: $0 latency|outage|pod-kill}"
BASELINE="${BASELINE:-120}"          # seconds of clean traffic before the fault
PAGE_TIMEOUT="${PAGE_TIMEOUT:-600}"  # seconds to wait for the expected page
QUIET_PERIOD="${QUIET_PERIOD:-300}"  # seconds the control scenario must stay quiet
AM_PORT="${AM_PORT:-19093}"

case "$SCENARIO" in
  latency)
    FAULT=chaos/latency.yaml
    EXPECT_PAGE=PodinfoProdSlow
    EXPECT_SILENT="PodinfoProdUnavailable PodinfoProdErrors" ;;
  outage)
    FAULT=chaos/gateway-outage.yaml
    EXPECT_PAGE=PodinfoProdUnavailable
    # The gateway answers these requests itself, so the request-based SLO is
    # blind to them. Asserting it stays silent documents that blind spot.
    EXPECT_SILENT="PodinfoProdErrors" ;;
  pod-kill)
    FAULT=chaos/pod-kill.yaml
    EXPECT_PAGE=""
    EXPECT_SILENT="PodinfoProdUnavailable PodinfoProdErrors PodinfoProdSlow" ;;
  *)
    echo "unknown scenario: $SCENARIO (expected latency, outage or pod-kill)" >&2
    exit 2 ;;
esac

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }

PF_PID=""
cleanup() {
  kubectl delete -f "$FAULT" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete -f load/k6.yaml --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

kubectl port-forward -n monitoring svc/alertmanager-operated "$AM_PORT:9093" >/dev/null 2>&1 &
PF_PID=$!
for _ in $(seq 1 20); do curl -sf "localhost:$AM_PORT/-/ready" >/dev/null && break; sleep 1; done

# Active pages for one alert name, as a count.
pages() {
  curl -sfG "localhost:$AM_PORT/api/v2/alerts" \
    --data-urlencode active=true --data-urlencode silenced=false --data-urlencode inhibited=false \
    --data-urlencode "filter=alertname=\"$1\"" --data-urlencode 'filter=severity="page"' |
    jq 'length'
}

# Every SLO alert currently active, one per line.
active_slo_alerts() {
  curl -sfG "localhost:$AM_PORT/api/v2/alerts" --data-urlencode active=true \
    --data-urlencode 'filter=sloth_id=~".+"' |
    jq -r '.[] | "  \(.labels.alertname) (\(.labels.severity))"' | sort -u
}

if [[ -n "$EXPECT_PAGE" && "$(pages "$EXPECT_PAGE")" -gt 0 ]]; then
  log "FAIL: $EXPECT_PAGE is already paging, so this experiment cannot show it firing; wait for it to resolve"
  exit 1
fi

# Burn-rate alerts resolve slowly by design: after a short outage, the 30 minute
# window stays above its threshold for up to 30 minutes. An alert still paging
# from an earlier experiment cannot be checked for silence, so note it instead.
already_paging=""
for alert in $EXPECT_SILENT; do
  if [[ "$(pages "$alert")" -gt 0 ]]; then
    already_paging="$already_paging $alert"
  fi
done

log "scenario: $SCENARIO"
log "starting steady traffic (10 requests per second through the gateway)"
kubectl delete -f load/k6.yaml --ignore-not-found --wait=true >/dev/null
kubectl apply -f load/k6.yaml >/dev/null

log "building a ${BASELINE}s baseline of healthy traffic"
sleep "$BASELINE"

log "injecting the fault: $FAULT"
kubectl apply -f "$FAULT" >/dev/null
started=$(date +%s)

result=pass
time_to_page=""

if [[ -n "$EXPECT_PAGE" ]]; then
  log "waiting up to ${PAGE_TIMEOUT}s for $EXPECT_PAGE to page"
  while true; do
    if [[ "$(pages "$EXPECT_PAGE")" -gt 0 ]]; then
      time_to_page=$(( $(date +%s) - started ))
      log "$EXPECT_PAGE is paging, ${time_to_page}s after the fault"
      break
    fi
    if (( $(date +%s) - started > PAGE_TIMEOUT )); then
      log "FAIL: $EXPECT_PAGE did not page within ${PAGE_TIMEOUT}s"
      result=fail
      break
    fi
    sleep 10
  done

  if [[ "$result" == pass ]]; then
    # The receiver logs each webhook body on one line, including the name of
    # the Alertmanager receiver that sent it. Allow for the group wait.
    delivered=no
    for _ in $(seq 1 12); do
      if kubectl logs -n sre deploy/alert-sink --since=20m 2>/dev/null |
        grep 'slo-routing/page' | grep -q "$EXPECT_PAGE"; then
        delivered=yes
        break
      fi
      sleep 5
    done
    if [[ "$delivered" == yes ]]; then
      log "the page reached the receiver (alert-sink, /page)"
    else
      log "FAIL: Alertmanager shows the page, but the receiver never got it"
      result=fail
    fi
  fi
else
  log "control scenario: nothing may page for ${QUIET_PERIOD}s"
  sleep "$QUIET_PERIOD"
fi

for alert in $EXPECT_SILENT; do
  if [[ " $already_paging " == *" $alert "* ]]; then
    log "not checked: $alert was still paging from an earlier experiment"
  elif [[ "$(pages "$alert")" -gt 0 ]]; then
    log "FAIL: $alert paged, but this scenario should not trigger it"
    result=fail
  else
    log "as expected, $alert did not page"
  fi
done

log "SLO alerts active at the end of the experiment:"
active_slo_alerts || true

page_cell="n/a"
[[ -n "$time_to_page" ]] && page_cell="${time_to_page}s"

{
  echo "### Game day: $SCENARIO"
  echo
  echo "| | |"
  echo "| --- | --- |"
  echo "| Fault | \`$FAULT\` |"
  echo "| Expected page | ${EXPECT_PAGE:-none} |"
  echo "| Time to page | $page_cell |"
  echo "| Expected silent | ${EXPECT_SILENT// /, } |"
  echo "| Result | $result |"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

[[ "$result" == pass ]]
