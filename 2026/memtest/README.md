# memtest: does a Go process give RAM back to the OS without a restart?

The app holds `--base-mib` (200 MiB) for its lifetime, holds `--spike-mib` more (+600 MiB, so 800 MiB in
total) from `--spike-after` for `--spike-for`, then drops the spike and runs forever without allocating.
Every page it holds is written, so it is resident.

It exports on `:6060/metrics`:

- `go_*`: all `runtime/metrics` (heap classes `objects/unused/free/released`, heap goal, GC cycles,
  scavenger CPU) and the `runtime.ReadMemStats`-based `go_memstats_*` (client_golang Go collector).
- `process_*`: RSS and VSZ (client_golang process collector).
- `memtest_smaps_rollup_bytes{field}`: `/proc/self/smaps_rollup` (`Rss`, `Private_Dirty`, `LazyFree`, `Swap`, ...).
- `memtest_cgroup_memory_*`: the container's own cgroup: `memory.stat` (`anon`, `pglazyfree`, `pglazyfreed`,
  `pgscan`, `pgsteal`, ...), `memory.events`, `memory.current`, `memory.max`, `memory.pressure` (PSI).
- `memtest_held_bytes`, `memtest_phase`, `memtest_free_os_memory_calls_total`, `memtest_info{experiment,godebug,...}`.

`/debug/flightrecorder` writes the `runtime/trace` flight recorder window (about the last minute),
and `/debug/pprof` is there as usual. `GODEBUG=gctrace=1,scavtrace=1` puts GC and scavenger lines in the log.

## Background

- The Go runtime returns memory itself: the background scavenger `madvise`s free heap pages. Since Go 1.16
  it uses `MADV_DONTNEED` on Linux (RSS drops at once). `GODEBUG=madvdontneed=0` switches to `MADV_FREE`:
  the pages stay in RSS and in the cgroup charge, and the kernel takes them only when it needs memory.
  So the "madvdontneed flag" is on by default, and the experiment that matters turns it **off**.
- The kernel cannot ask a process to give memory back. Under pressure it can only drop clean or
  `MADV_FREE`d pages, or swap anonymous ones. Pods get `memory.swap.max=0` here (kubelet `NoSwap`), so
  heap memory the runtime still holds cannot be reclaimed, and pressure ends in an OOM kill.
- `debug.FreeOSMemory()` forces a GC and returns all free heap memory at once.

## Environment

`make setup-env` builds the image and creates kind cluster `memtest2026`, kindest/node v1.35.0:

- `apps` worker: runs the two apps. The setup sets `system-reserved = host RAM - PODS_BUDGET_MIB` (1200 MiB by
  default), so the kubelet caps `kubepods.slice` at 1200 MiB (`memory.max`) and reports that as allocatable.
  kind nodes share the host kernel and see the host's `/proc/meminfo`, so this cgroup is the node's
  real RAM limit. kindnet and kube-proxy use about 30 MiB of it.
- `monitoring` worker: kube-prometheus-stack (Prometheus, Grafana, kube-state-metrics, node-exporter)
  with a 5s scrape interval for the PodMonitor and for cAdvisor.
- App pods: request 250Mi, limit 850Mi. Budget: base + spike = 220 + 820 MiB RSS fits, spike + spike
  = 1640 MiB does not.

### Access Grafana

The cluster keeps running after the experiments; only `make teardown-env` deletes it. Prometheus keeps the
data for 10 days (chart default).

1. In this directory, start the port-forward and leave it running:
   ```sh
   make grafana   # kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
   ```
   It uses `env/kubeconfig.yaml`. For your own `kubectl`, run `export KUBECONFIG=$PWD/env/kubeconfig.yaml`.
2. Open <http://localhost:3000/d/memtest> and log in as `admin` / `prom-operator`. The dashboard is
   "memtest: does Go return RAM to the OS?".
3. To see one run, open the link in its `results/<run>/summary.txt` (also in the Results table below);
   it sets the time range to that run. Red annotations mark phase changes, and the `pod` variable selects
   the pods of the per-pod panels.

If the port-forward stops (e.g. after a laptop sleep), run `make grafana` again. `make prometheus`
forwards Prometheus to <http://localhost:9090> the same way.

The dashboard has these sections:

- Experiment: held memory, restarts and OOM kills, with phase changes as annotations.
- Inside the pod: the Go heap broken down per pod, the kernel view per pod (RSS, dirty, LazyFree,
  cgroup charge), GC cycles and FreeOSMemory calls, scavenger CPU, cgroup reclaim counters, PSI.
- Apps node, from cAdvisor: pods stacked against allocatable, `kubepods.slice` usage/rss/cache/swap,
  node PSI, memory failures, the whole node container.
- Host, from node-exporter: shared by all kind nodes, so useful only for host swap.

## Experiments

`make experiment-<mode>` (late scenario) or `./env/run-experiment.sh <mode> <late|early>`, or
`make experiments` for all ten runs (about 2h15m). Each run replaces the two apps, takes a flight
recorder snapshot of both every minute, saves logs and pod status to `results/<mode>-<scenario>-<time>/`,
and prints the Grafana link for its time range.

Modes:

| mode | how | what it tests |
|---|---|---|
| `default` | nothing | Linux and Go defaults: background scavenger, `MADV_DONTNEED` |
| `free-os-memory` | `--free-os-memory-every=30s` | `debug.FreeOSMemory()` |
| `madv-free` | `GODEBUG=madvdontneed=0` | lazy release: does node pressure take the memory back? |
| `gomemlimit-800` | `GOMEMLIMIT=800MiB` | the usual production setting (~95% of the container limit) |
| `gomemlimit-400` | `GOMEMLIMIT=400MiB` | a soft limit below the spike: does the runtime return memory sooner? |

`GOMEMLIMIT` makes the runtime keep its total memory under the limit: the GC runs more often (capped at
about 50% CPU when the live heap exceeds the limit), and the scavenger releases free memory down to 95% of
the limit, independent of the heap goal.

Timeline: app A spikes from 2m to 4m30s. App B spikes for 2m starting at:

- `late`, at 10m: after A's runtime has released (or `MADV_FREE`d) the spike.
- `early`, at 5m30s: 1 min after A's spike ends, before A's runtime released anything.

Why ~8m: measured locally (Go 1.27.3, 200 + 600 MiB, idle after the spike), the runtime releases the freed
spans at the **second** GC after they become garbage, not the first. An idle app only GCs when sysmon
forces one every 2 min, so the release comes about 4 min after the spike ends:

| mode | RSS during spike | after 1st GC | after 2nd GC |
|---|---|---|---|
| default | 815 MiB | 823 MiB (605 MiB heap free, retained) | 246 MiB (585 MiB released) |
| free-os-memory | 815 MiB | 218 MiB within 30s of the spike end | |
| madv-free | 815 MiB | 826 MiB | 827 MiB, of which LazyFree 578 MiB |

Expected:

| mode | late | early |
|---|---|---|
| default | fits: A is back at about 250 MiB | OOM kill: A still holds 820 MiB |
| free-os-memory | fits | fits: A released within 30s |
| madv-free | fits only because the kernel reclaims A's LazyFree pages (`pglazyfreed` > 0, PSI > 0) | OOM kill: nothing is lazy-free yet |
| gomemlimit-800 | fits | OOM kill: the 760 MiB scavenger goal lets A keep about 800 MiB |
| gomemlimit-400 | fits | open: A frees the spike only at its next GC, then the scavenger targets 380 MiB; the question is whether it still waits a GC cycle before releasing |

All expectations held; the open one is answered below.

## Results

Runs from 2026-11-09, Go 1.27.3, kindest/node v1.35.0, host kernel 7.0, THP `madvise`. Pods budget 1200 MiB
(`kubepods.slice` `memory.max`); kindnet and kube-proxy use about 30 MiB of it. Raw data: `results/<run>/`.
The Grafana links need `make grafana` running.

| mode | scenario | A's RSS < 400 MiB after its spike ended | kubepods peak | outcome | Grafana |
|---|---|---|---|---|---|
| default | late | 170s, at the 2nd GC after the spike | 1121 MiB | fits | [run](http://localhost:3000/d/memtest?from=1794220482000&to=1794221442000) |
| free-os-memory | late | 30s, at the next `FreeOSMemory` | 1065 MiB | fits | [run](http://localhost:3000/d/memtest?from=1794221326000&to=1794222287000) |
| madv-free | late | 330s, only when B's spike caused pressure | 1200 MiB (the limit) | fits: the kernel reclaimed 502 MiB of A's LazyFree pages | [run](http://localhost:3000/d/memtest?from=1794222171000&to=1794223131000) |
| gomemlimit-800 | late | 120s, at the 2nd GC after the spike | 1096 MiB | fits | [run](http://localhost:3000/d/memtest?from=1794224648000&to=1794225608000) |
| gomemlimit-400 | late | 5s | 1079 MiB | fits | [run](http://localhost:3000/d/memtest?from=1794225491000&to=1794226452000) |
| default | early | not released: A was OOM-killed when B's spike started | kill not sampled | **both A and B OOM-killed** | [run](http://localhost:3000/d/memtest?from=1794223014000&to=1794223675000) |
| free-os-memory | early | 30s | 1065 MiB | fits | [run](http://localhost:3000/d/memtest?from=1794223559000&to=1794224219000) |
| madv-free | early | not released: A was OOM-killed | kill not sampled | **both A and B OOM-killed** | [run](http://localhost:3000/d/memtest?from=1794224103000&to=1794224764000) |
| gomemlimit-800 | early | not released: A was OOM-killed | kill not sampled | **A OOM-killed**, then a second OOM kill (see below) | [run](http://localhost:3000/d/memtest?from=1794226336000&to=1794226996000) |
| gomemlimit-400 | early | 5s | 1072 MiB | fits | [run](http://localhost:3000/d/memtest?from=1794226880000&to=1794227541000) |

Findings:

1. **A Go process does return RAM to the OS without a restart, by default.** The scavenger released 583 MiB
   and RSS dropped from 840 to 263 MiB. It does so late, though: the spike's spans are freed at the first GC
   after the spike, but released only at the second. An idle app runs a GC only every 2 min (sysmon's
   periodic GC), so the memory came back 2 to 3 min after the spike ended.
2. **The kernel never asks the process for memory.** Node pressure did not make the Go runtime release
   anything: the runtime has no signal for it. Under pressure the kernel can only take pages that the runtime
   already gave up with `MADV_FREE`. With no swap, memory the runtime still holds cannot be reclaimed, so
   pressure ends in an OOM kill (default and madv-free, early).
3. **The "common knowledge" describes `MADV_FREE`** (the Go 1.12–1.15 default, `GODEBUG=madvdontneed=0`
   today). RSS stayed at 841 MiB with 575 MiB LazyFree for 4 min after the runtime released the spike. When
   B's spike pushed `kubepods` to its 1200 MiB limit, the kernel reclaimed 502 MiB of A's pages
   (`pglazyfreed`, 128k pages scanned) and B stalled for 0.1s, with no OOM. Here the node did take the memory
   back, but only because the runtime had marked it free first. `MADV_FREE` also makes RSS, `memory.current`
   and the dashboards report memory that is actually reclaimable.
4. **`debug.FreeOSMemory()` works but is a blunt tool.** Called every 30s, it returned the spike within
   30s and prevented the OOM in the early scenario. Each call is a full GC that blocks the caller until it
   completes, plus a full scavenge, so its cost grows with the live heap and the call rate.
5. **`GOMEMLIMIT` near the container limit (800MiB) changes nothing here.** The memory-limit scavenger goal is
   95% of the limit (760 MiB), so A released only about 20 MiB early and the rest at the 2nd GC, like the
   default, and it was OOM-killed in the early scenario.
6. **`GOMEMLIMIT` below the spike (400MiB) returned memory fastest: within 5s, with no extra code.** During
   the spike the live heap (800 MiB) exceeded the limit, so the GC ran back to back: about 1,390 cycles and
   5.9 CPU-seconds in 2.5 min. That was cheap only because the app allocated almost nothing. An app that
   allocates while over the limit runs the GC up to its 50% CPU cap. After the spike, the next of those GCs
   freed the spans, and memory-limit scavenging released them immediately, without waiting another GC
   cycle.
7. **The OOM killer hits the wrong pod, and then a cascade follows.** In both default and madv-free early,
   the kernel killed A first: the idle pod with the most anonymous memory (851 MB), which still held its
   finished spike. B, the pod that was spiking, was killed in the same second (345 MB, still allocating),
   because A's memory was not freed fast enough. Both are Burstable with the same request, so they have the
   same `oom_score_adj` and RSS decides. In gomemlimit-800 early, the restarted A started its spike again
   2 min later, while B still held its own finished spike, and the next OOM killed both. A Deployment
   restart re-runs the whole spike schedule, so the early runs show only the first OOM cleanly.

Not verified or not covered:

- Swap. Pods run with `memory.swap.max=0` (kubelet `NoSwap`). With `LimitedSwap`, retained heap pages would
  be swapped instead of OOM-killed.
- An app that keeps allocating after the spike. It would run GCs more often than every 2 min, so the
  default mode would release sooner. These runs show the worst case: an idle process.
- Each run was done once. The default timing depends on where the 2-minute periodic GC falls relative to
  the spike end. Measured delays: 170s and 120s here, and about 240s in the local run.
