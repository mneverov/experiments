#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source env/common.sh
kind delete cluster --name "$CLUSTER"
\rm -f env/kubeconfig.yaml
