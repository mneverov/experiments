#!/usr/bin/env bash
# Creates the kind cluster, installs kube-prometheus-stack, the dashboard and the PodMonitor.
# Expects the memtest:dev image (make image).
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=memtest2026
export KUBECONFIG=env/kubeconfig.yaml
# RAM for all pods on the apps node: fits one app at base + one at spike, not two at spike.
PODS_BUDGET_MIB=${PODS_BUDGET_MIB:-1200}
host_mib=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
export SYSTEM_RESERVED_MIB=$((host_mib - PODS_BUDGET_MIB))

envsubst < env/kind-cfg.yaml |
  kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --image kindest/node:v1.35.0 --config -
kind load docker-image memtest:dev --name "$CLUSTER"

kubectl create namespace monitoring
kubectl create namespace memtest
kubectl create configmap memtest-dashboard -n monitoring --from-file=env/dashboard.json
kubectl label configmap memtest-dashboard -n monitoring grafana_dashboard=1

helm install kube-prometheus-stack kube-prometheus-stack --wait --timeout 10m \
  --repo https://prometheus-community.github.io/helm-charts --version 93.1.0 \
  --namespace monitoring --values env/values.yaml
kubectl apply -f env/podmonitor.yaml

echo "apps node kubepods.slice memory.max: $(docker exec "$CLUSTER-worker" cat /sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/memory.max)"
echo "Grafana: make grafana, then http://localhost:3000/d/memtest (admin:prom-operator)"
