# Sourced by the env scripts.
CLUSTER=memtest2026
# One apps node per run (<mode>-<scenario>); setup.sh creates them, run-experiments.sh runs on them.
RUNS=(
  default-late free-os-memory-late madv-free-late gomemlimit-800-late gomemlimit-400-late
  default-early free-os-memory-early madv-free-early gomemlimit-800-early gomemlimit-400-early
)
