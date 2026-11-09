#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
kind delete cluster --name memtest2026
\rm -f env/kubeconfig.yaml
