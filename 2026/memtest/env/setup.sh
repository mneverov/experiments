#!/usr/bin/env bash
# Creates the kind cluster (one apps node per run in env/common.sh), installs kube-prometheus-stack,
# the dashboard and the PodMonitor. Expects the memtest:dev image (make image).
set -euo pipefail
cd "$(dirname "$0")/.."
source env/common.sh

export KUBECONFIG=env/kubeconfig.yaml
# RAM for all pods on each apps node: fits one app at base + one at spike, not two at spike.
PODS_BUDGET_MIB=${PODS_BUDGET_MIB:-1200}
host_mib=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
# kind nodes share the host kernel and see the host /proc/meminfo. system-reserved = host RAM - budget
# makes the kubelet cap kubepods.slice (memory.max) at the budget and report it as allocatable, so
# that cgroup is the apps node's real RAM limit.
system_reserved_mib=$((host_mib - PODS_BUDGET_MIB))

{
  cat <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
  labels:
    role: monitoring
YAML
  for _ in "${RUNS[@]}"; do
    cat <<YAML
- role: worker
  labels:
    role: apps
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        system-reserved: "memory=${system_reserved_mib}Mi"
YAML
  done
} | kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --image kindest/node:v1.35.0 --config -
kind load docker-image memtest:dev --name "$CLUSTER"

kubectl create namespace monitoring
kubectl create namespace memtest
kubectl create configmap memtest-dashboard -n monitoring --from-file=env/dashboard.json
kubectl label configmap memtest-dashboard -n monitoring grafana_dashboard=1

helm install kube-prometheus-stack kube-prometheus-stack --wait --timeout 10m \
  --repo https://prometheus-community.github.io/helm-charts --version 93.1.0 \
  --namespace monitoring --values env/values.yaml
kubectl apply -f env/podmonitor.yaml

echo "apps nodes, kubepods.slice memory.max:"
for node in $(kubectl get nodes -l role=apps -o jsonpath='{.items[*].metadata.name}'); do
  echo "  $node $(docker exec "$node" cat /sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/memory.max)"
done
echo "Grafana: make grafana, then http://localhost:3000/d/memtest (admin:prom-operator)"
