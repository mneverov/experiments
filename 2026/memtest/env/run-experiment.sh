#!/usr/bin/env bash
# usage: run-experiment.sh <default|free-os-memory|madv-free|gomemlimit-800|gomemlimit-400> [late|early]
#
# Deploys app a and app b on the apps node (pods budget 1200Mi: one app at spike + one at base
# fits, two at spike do not). A spikes from 2m to 4m30s. An idle Go app releases freed spans
# at the second GC after they became garbage; without allocation those are forced GCs every
# 2 min, so A's runtime gives the memory back at ~8m.
#   late:  B spikes at 10m, after A's runtime released (or MADV_FREE'd) the spike.
#   early: B spikes at 5m30s, before that.
# Saves flight recorder snapshots (every minute), logs (gctrace, scavtrace) and pod status to
# results/<mode>-<scenario>-<time>/ and prints the Grafana link for the run.
set -euo pipefail
cd "$(dirname "$0")/.."
export KUBECONFIG=env/kubeconfig.yaml

usage="usage: $0 <default|free-os-memory|madv-free|gomemlimit-800|gomemlimit-400> [late|early]"
mode=${1:?$usage}
scenario=${2:-late}

# The app GODEBUG is not called GODEBUG here, or kubectl (a Go program) would pick it up.
export BASE_MIB=200 SPIKE_MIB=600 FREE_OS_MEMORY_EVERY=0s APP_GODEBUG="gctrace=1,scavtrace=1" APP_GOMEMLIMIT=
case $mode in
  default) ;; # MADV_DONTNEED: the default on Linux since Go 1.16
  free-os-memory) FREE_OS_MEMORY_EVERY=30s ;;
  madv-free) APP_GODEBUG="madvdontneed=0,$APP_GODEBUG" ;; # MADV_FREE: pages stay in RSS until the kernel needs them
  gomemlimit-800) APP_GOMEMLIMIT=800MiB ;; # ~95% of the 850Mi container limit, the usual production setting
  gomemlimit-400) APP_GOMEMLIMIT=400MiB ;; # below the 800 MiB spike: GC runs constantly during it
  *) echo "$usage" >&2; exit 1 ;;
esac
case $scenario in
  late) b_after=600 ;;
  early) b_after=330 ;;
  *) echo "$usage" >&2; exit 1 ;;
esac
export EXPERIMENT=$mode-$scenario
total=$((b_after + 120 + 120)) # B's spike, then 2 min to watch the aftermath
out=results/$EXPERIMENT-$(date +%Y%m%dT%H%M%S)
mkdir -p "$out"

kubectl delete deploy -n memtest -l app.kubernetes.io/name=memtest --ignore-not-found --wait
kubectl wait --for=delete pod -n memtest -l app.kubernetes.io/name=memtest --timeout=60s 2>/dev/null || true

deploy() { APP=$1 SPIKE_AFTER=$2 SPIKE_FOR=$3 envsubst < env/deployment.yaml | kubectl apply -f -; }
deploy a 2m 2m30s
deploy b "${b_after}s" 2m
for app in a b; do kubectl rollout status -n memtest "deploy/memtest-$app" --timeout=120s; done
start=$(date +%s)
echo "$EXPERIMENT started at $(date -d "@$start" +%T), runs $((total / 60))m$((total % 60))s; results in $out"

pod() { kubectl get pod -n memtest -l "app.kubernetes.io/instance=$1" -o jsonpath='{.items[0].metadata.name}'; }
# The flight recorder keeps about the last minute, so a snapshot per minute covers the run.
for ((t = 60; t <= total; t += 60)); do
  sleep $((start + t - $(date +%s)))
  for app in a b; do
    kubectl get --raw "/api/v1/namespaces/memtest/pods/$(pod $app):6060/proxy/debug/flightrecorder" \
      > "$out/fr-$app-$(printf %04d $t)s.trace" || echo "flight recorder snapshot of $app at ${t}s failed"
  done
done
end=$(date +%s)

for app in a b; do
  kubectl logs -n memtest "$(pod $app)" > "$out/$app.log"
  kubectl logs -n memtest "$(pod $app)" --previous > "$out/$app.previous.log" 2>/dev/null || \rm -f "$out/$app.previous.log"
done
kubectl get pods -n memtest -o yaml > "$out/pods.yaml"
kubectl get pods -n memtest -o custom-columns='POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST_TERMINATED:.status.containerStatuses[0].lastState.terminated.reason,AT:.status.containerStatuses[0].lastState.terminated.finishedAt' | tee "$out/summary.txt"
url="http://localhost:3000/d/memtest?from=$(((start - 60) * 1000))&to=$(((end + 60) * 1000))"
echo "grafana: $url" | tee -a "$out/summary.txt"
