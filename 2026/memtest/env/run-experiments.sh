#!/usr/bin/env bash
# usage: run-experiments.sh [run...]
#   run = <default|free-os-memory|madv-free|gomemlimit-800|gomemlimit-400|alloc>-<late|early>;
#   no arguments: all runs in env/common.sh.
#
# Starts the given runs at the same time, each on its own free apps node (pods budget 1200Mi: one app at
# spike + one at base fits, two at spike do not), so runs do not share memory. Per run, app a spikes from 2m to 4m30s. An idle Go app releases freed spans at the second
# GC after they became garbage; without allocation those are periodic GCs every 2 min, so A's
# runtime gives the memory back 2-4 min after its spike.
#   late:  B spikes at 10m, after A's runtime released (or MADV_FREE'd) the spike.
#   early: B spikes at 5m30s, before that.
# Saves per run, in results/<time>/<run>/: flight recorder snapshots (every minute), logs (gctrace,
# scavtrace), pod status and the Grafana link for the run. results/<time>/index.txt lists the links.
# A run's apps are deleted when it ends.
set -euo pipefail
cd "$(dirname "$0")/.."
source env/common.sh
export KUBECONFIG=env/kubeconfig.yaml

runs=("$@")
((${#runs[@]})) || runs=("${RUNS[@]}")

# configure exports the envsubst variables of env/deployment.yaml for run <mode>-<scenario>, plus
# B_AFTER (seconds). The app's GODEBUG is not called GODEBUG here, or kubectl (a Go program) would
# pick it up.
configure() {
  local mode=${1%-*} scenario=${1##*-}
  export RUN=$1 BASE_MIB=200 SPIKE_MIB=600 FREE_OS_MEMORY_EVERY=0s CHURN_MIB_PER_SEC=0 APP_GODEBUG="gctrace=1,scavtrace=1" APP_GOMEMLIMIT=
  case $mode in
    default) ;; # MADV_DONTNEED: the default on Linux since Go 1.16
    free-os-memory) FREE_OS_MEMORY_EVERY=30s ;;
    madv-free) APP_GODEBUG="madvdontneed=0,$APP_GODEBUG" ;; # MADV_FREE: pages stay in RSS until the kernel needs them
    gomemlimit-800) APP_GOMEMLIMIT=800MiB ;; # ~95% of the 850Mi container limit, the usual production setting
    gomemlimit-400) APP_GOMEMLIMIT=400MiB ;; # below the 800 MiB spike: GC runs constantly during it
    # Default settings in a busy app. The garbage doubles the heap (GOGC=100), so half the live data
    # gives the same RSS as the idle modes: ~200 MiB at base, ~800 MiB during the spike.
    alloc) BASE_MIB=100 SPIKE_MIB=300 CHURN_MIB_PER_SEC=20 ;;
    *) echo "unknown mode in run $1" >&2; return 1 ;;
  esac
  case $scenario in
    late) B_AFTER=600 ;;
    early) B_AFTER=330 ;;
    *) echo "unknown scenario in run $1" >&2; return 1 ;;
  esac
}

declare -A total # run -> duration in seconds: B's spike, then 2 min to watch the aftermath
for run in "${runs[@]}"; do
  configure "$run"
  total[$run]=$((B_AFTER + 240))
done

selector="memtest/run in ($(IFS=,; echo "${runs[*]}"))"
kubectl delete deploy -n memtest -l "$selector" --ignore-not-found --wait
kubectl wait --for=delete pod -n memtest -l "$selector" --timeout=60s 2>/dev/null || true

# Free apps nodes: no memtest pod on them.
mapfile -t free < <(comm -23 \
  <(kubectl get nodes -l role=apps -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort) \
  <(kubectl get pods -n memtest -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u))
((${#free[@]} >= ${#runs[@]})) || { echo "${#runs[@]} runs need ${#runs[@]} free apps nodes, found ${#free[@]}" >&2; exit 1; }

deploy() { APP=$1 SPIKE_AFTER=$2 SPIKE_FOR=$3 envsubst < env/deployment.yaml | kubectl apply -f -; }
i=0
for run in "${runs[@]}"; do
  (export NODE=${free[i]} && configure "$run" && deploy a 2m 2m30s && deploy b "${B_AFTER}s" 2m)
  ((++i))
done
for run in "${runs[@]}"; do for app in a b; do kubectl rollout status -n memtest "deploy/$run-$app" --timeout=120s >/dev/null; done; done
start=$(date +%s)
out=results/$(date -d "@$start" +%Y%m%dT%H%M%S)
max=0
for run in "${runs[@]}"; do
  mkdir -p "$out/$run"
  ((total[$run] > max)) && max=${total[$run]}
done
echo "${#runs[@]} runs started at $(date -d "@$start" +%T), last one ends in $((max / 60))m$((max % 60))s; results in $out"

pod() { kubectl get pod -n memtest -l "memtest/run=$1,app.kubernetes.io/instance=$2" -o jsonpath='{.items[0].metadata.name}'; }

collect() {
  local run=$1 dir=$out/$1 app
  for app in a b; do
    kubectl logs -n memtest "$(pod "$run" $app)" > "$dir/$app.log"
    kubectl logs -n memtest "$(pod "$run" $app)" --previous > "$dir/$app.previous.log" 2>/dev/null || \rm -f "$dir/$app.previous.log"
  done
  kubectl get pods -n memtest -l "memtest/run=$run" -o yaml > "$dir/pods.yaml"
  kubectl get pods -n memtest -l "memtest/run=$run" -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount,LAST_TERMINATED:.status.containerStatuses[0].lastState.terminated.reason,AT:.status.containerStatuses[0].lastState.terminated.finishedAt' > "$dir/summary.txt"
  local url="http://localhost:3000/d/memtest?var-run=$run&from=$(((start - 60) * 1000))&to=$(((start + total[$run] + 60) * 1000))"
  echo "grafana: $url" >> "$dir/summary.txt"
  echo "$run $url" | tee -a "$out/index.txt"
  # A restarted pod reruns its spike schedule, so OOM-killed runs would keep killing each other.
  # Prometheus keeps the data, so the dashboard still shows the run.
  kubectl delete deploy -n memtest -l "memtest/run=$run" --wait=false >/dev/null
}

# The flight recorder keeps about the last minute, so a snapshot per minute covers each run.
declare -A finished
for ((t = 60; t < max + 60; t += 60)); do
  wait_s=$((start + t - $(date +%s)))
  ((wait_s > 0)) && sleep "$wait_s"
  for run in "${runs[@]}"; do
    [[ -n ${finished[$run]:-} ]] && continue
    for app in a b; do
      kubectl get --raw "/api/v1/namespaces/memtest/pods/$(pod "$run" $app):6060/proxy/debug/flightrecorder" \
        > "$out/$run/fr-$app-$(printf %04d $t)s.trace" || echo "flight recorder snapshot of $run/$app at ${t}s failed"
    done
    if ((t >= total[$run])); then
      collect "$run"
      finished[$run]=1
    fi
  done
done
