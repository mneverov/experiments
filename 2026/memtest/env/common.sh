# Sourced by the env scripts.
CLUSTER=memtest2026
# All runs (<mode>-<scenario>). setup.sh creates one apps node per run; run-experiments.sh puts each run on
# a free apps node.
RUNS=(
  default-late free-os-memory-late madv-free-late gomemlimit-800-late gomemlimit-400-late alloc-late
  default-early free-os-memory-early madv-free-early gomemlimit-800-early gomemlimit-400-early alloc-early
)
