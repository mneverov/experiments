# memtest: does a Go process give RAM back to the OS without a restart?

The app holds `--base-mib` (200 MiB) for its lifetime, holds `--spike-mib` more (+600 MiB, so 800 MiB in
total) from `--spike-after` for `--spike-for`, then drops the spike and runs forever. It allocates nothing else unless `--churn-mib-per-sec` makes it a busy app.
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

`make setup-env` builds the image and creates kind cluster `memtest2026`, kindest/node v1.35.0, with 14 nodes (12 apps, monitoring, control plane):

- One `apps` worker per run (the `RUNS` list in `env/common.sh`). The runner puts each run's two apps
  on a free apps node, so all runs can go at the same time without sharing memory. The setup sets
  `system-reserved = host RAM - PODS_BUDGET_MIB` (1200 MiB by default), so the kubelet caps
  `kubepods.slice` at 1200 MiB (`memory.max`) and reports that as allocatable. kind nodes share the host
  kernel and see the host's `/proc/meminfo`, so this cgroup is the node's real RAM limit. kindnet and
  kube-proxy use about 30 MiB of it.
- Host requirements: about 15 GB free RAM while all twelve A apps spike at once, and
  `fs.inotify.max_user_instances` of at least 512 (`sudo sysctl fs.inotify.max_user_instances=512`), or
  some kind nodes fail with "too many open files".
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
3. To see one run, open its link in `results/<time>/index.txt` or in the Results table below. The link
   sets the `run` variable and the time range. The `pod` variable selects pods of that run, and `apps node`
   follows the run's pods.

If the port-forward stops (e.g. after a laptop sleep), run `make grafana` again. `make prometheus`
forwards Prometheus to <http://localhost:9090> the same way.

The dashboard has these sections:

- Experiment: one tile per pod with the number of OOM kills in the time range (red when > 0), held memory,
  and OOM kills over time as red bars.
- Annotations on every panel: red "OOM kill <pod>" at the restart that follows each OOM kill (kube-state-metrics
  sees the kill only through that restart, within about 10s), blue at phase changes.
- Inside the pod: the Go heap broken down per pod, the kernel view per pod (RSS, dirty, LazyFree,
  cgroup charge), GC cycles and FreeOSMemory calls, scavenger CPU, cgroup reclaim counters, PSI.
- Apps node of the run, from cAdvisor: pods stacked against allocatable, `kubepods.slice` usage/rss/cache/swap,
  node PSI, memory failures, the whole node container.
- Host, from node-exporter: shared by all kind nodes, so useful only for host swap.

## Experiments

`make experiments` starts all twelve runs at once, each on its own apps node; the last one ends after 14 min.
`make experiment-<mode>-<late|early>` (e.g. `make experiment-madv-free-late`) or
`./env/run-experiments.sh <run>...` starts only the given runs. Each run replaces its two apps, takes a
flight recorder snapshot of both every minute, deletes the apps when it ends (a restarted pod would rerun
its spike schedule; Prometheus keeps the data), and saves to `results/<time>/<run>/`:

- `a.log`, `b.log` (and `*.previous.log` after a restart): gctrace and scavtrace lines.
- `pods.yaml`, `summary.txt`: pod status, restarts, last termination reason, and the Grafana link.
- `fr-<app>-<seconds>s.trace`: flight recorder snapshots, for `go tool trace`.

`results/<time>/index.txt` lists each run with its Grafana link.

Modes:

| mode | how | what it tests |
|---|---|---|
| `default` | nothing | Linux and Go defaults: background scavenger, `MADV_DONTNEED` |
| `free-os-memory` | `--free-os-memory-every=30s` | `debug.FreeOSMemory()` |
| `madv-free` | `GODEBUG=madvdontneed=0` | lazy release: does node pressure take the memory back? |
| `gomemlimit-800` | `GOMEMLIMIT=800MiB` | the usual production setting (~95% of the container limit) |
| `gomemlimit-400` | `GOMEMLIMIT=400MiB` | a soft limit below the spike: does the runtime return memory sooner? |
| `alloc` | default settings, `--churn-mib-per-sec=20`, 100 MiB base, +300 MiB spike | a busy app: does the default return memory sooner when the GC runs every few seconds? |

The `alloc` apps allocate 20 MiB/s of short-lived garbage for their whole life, like a service handling
requests. Garbage lets the heap grow to twice the live data (`GOGC=100`), so they hold half the live data
of the other modes, which gives the same RSS: about 215 MiB at base and 818 MiB during the spike.

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

Two samples per mode and scenario, on 2026-11-09, Go 1.27.3, kindest/node v1.35.0, host kernel 7.0, THP
`madvise`. Pods budget 1200 MiB per apps node (`kubepods.slice` `memory.max`); kindnet and kube-proxy use about
30 MiB of it.

- Parallel: all ten at once from 13:56:36, each on its own apps node (`results/20261109T135636/`). The
  host had at least 7.3 GB available throughout, and swap stayed at 1.3 GB, so the runs did not affect
  each other. The Grafana links point to this sample and need `make grafana` running.
- Serial: one at a time, 11:35–13:35, on the earlier 3-node cluster (`results/<run>-<time>/`). That
  cluster was deleted, so these runs have no Grafana links.

Kill order comes from the kernel log (`journalctl -k`); the dashboard shows each kill as a red annotation
about 7s later.

| mode | scenario | A's RSS < 400 MiB after its spike, parallel / serial | kubepods peak, parallel | outcome (both samples) | Grafana |
|---|---|---|---|---|---|
| default | late | 210s / 170s, at the 2nd GC after the spike | 1135 MiB | fits | [run](http://localhost:3000/d/memtest?var-run=default-late&from=1794228936000&to=1794229896000) |
| free-os-memory | late | 30s / 30s, at the next `FreeOSMemory` | 1092 MiB | fits | [run](http://localhost:3000/d/memtest?var-run=free-os-memory-late&from=1794228936000&to=1794229896000) |
| madv-free | late | 330s / 330s, only when B's spike caused pressure | 1200 MiB (the limit) | fits: the kernel reclaimed 522 / 502 MiB of A's LazyFree pages | [run](http://localhost:3000/d/memtest?var-run=madv-free-late&from=1794228936000&to=1794229896000) |
| gomemlimit-800 | late | 120s / 120s, at the 2nd GC after the spike | 1126 MiB | fits | [run](http://localhost:3000/d/memtest?var-run=gomemlimit-800-late&from=1794228936000&to=1794229896000) |
| gomemlimit-400 | late | 5s / 5s | 1104 MiB | fits | [run](http://localhost:3000/d/memtest?var-run=gomemlimit-400-late&from=1794228936000&to=1794229896000) |
| default | early | not released: A OOM-killed when B's spike started | kill not sampled | **A killed first (831 / 831 MiB), B in the same second** | [run](http://localhost:3000/d/memtest?var-run=default-early&from=1794228936000&to=1794229626000) |
| free-os-memory | early | 30s / 30s | 1089 MiB | fits | [run](http://localhost:3000/d/memtest?var-run=free-os-memory-early&from=1794228936000&to=1794229626000) |
| madv-free | early | not released: A OOM-killed | kill not sampled | **A killed first (831 / 831 MiB)**; B in the same second in the serial sample, 2 min later by the restarted A's spike in the parallel one | [run](http://localhost:3000/d/memtest?var-run=madv-free-early&from=1794228936000&to=1794229626000) |
| gomemlimit-800 | early | not released: A OOM-killed | kill not sampled | **A killed first (788 / 769 MiB)**; B 2 min later by the restarted A's spike | [run](http://localhost:3000/d/memtest?var-run=gomemlimit-800-early&from=1794228936000&to=1794229626000) |
| alloc | late | 20s (one sample) | 1095 MiB | fits | [run](http://localhost:3000/d/memtest?var-run=alloc-late&from=1794231426000&to=1794232386000) |
| alloc | early | 10s (one sample) | 1101 MiB | **fits** | [run](http://localhost:3000/d/memtest?var-run=alloc-early&from=1794231426000&to=1794232116000) |
| gomemlimit-400 | early | 5s / 5s | 1092 MiB | fits | [run](http://localhost:3000/d/memtest?var-run=gomemlimit-400-early&from=1794228936000&to=1794229626000) |

"kill not sampled": the 5s scrape misses the instant the node hits its limit; the kernel log has the kill.

The `alloc` runs ran later, from 14:38:06 on two of the same apps nodes (`results/20261109T143806/`), once.

Findings:

1. **A Go process does return RAM to the OS without a restart, by default.** The scavenger released 583 MiB
   and RSS dropped from 840 to 263 MiB. It does so late, though: the spike's spans are freed at the first GC
   after the spike, but released only at the second. An idle app runs a GC only every 2 min (sysmon's
   periodic GC), so the memory came back 2 to 3.5 min after the spike ended.
2. **The kernel never asks the process for memory.** Node pressure did not make the Go runtime release
   anything: the runtime has no signal for it. Under pressure the kernel can only take pages that the runtime
   already gave up with `MADV_FREE`. With no swap, memory the runtime still holds cannot be reclaimed, so
   pressure ends in an OOM kill (default and madv-free, early).
3. **The "common knowledge" describes `MADV_FREE`** (the Go 1.12–1.15 default, `GODEBUG=madvdontneed=0`
   today). RSS stayed at 841 MiB with 575 MiB LazyFree for 4 min after the runtime released the spike. When
   B's spike pushed `kubepods` to its 1200 MiB limit, the kernel reclaimed 502 MiB (522 MiB in the second sample) of A's pages
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
7. **The OOM killer hits the wrong pod.** In all three early runs and in both samples, the kernel killed A
   first: the idle pod with the most anonymous memory (769–851 MiB), which still held its finished spike.
   Both pods are Burstable with the same request, so they have the same `oom_score_adj` and RSS decides.
   B, the pod that was spiking, was killed in the same second in default early (both samples) and in the
   serial madv-free early (334–345 MiB, still allocating), because A's memory was not freed fast enough.
   A Deployment restart re-runs the whole spike schedule: 2 min after its kill, the restarted A spiked
   again while B still held its own spike, and the next OOM killed B. That's why only the first OOM of
   an early run is clean.
8. **A busy app returns the spike in 10–20s with default settings, and the OOM does not happen.** At
   20 MiB/s of garbage the GC runs every ~5s at base instead of every 2 min, so the "second GC after the
   spike" comes quickly. In the early scenario, where the idle default app was OOM-killed, the busy app had
   already released the spike when B spiked; `kubepods` peaked at 1101 MiB. The cost is the usual GC cost:
   about 136 cycles in 14 min, 0.07% of a core, and a heap that grows to twice the live data, so
   such an app needs a container limit of about twice its live peak.

Not verified or not covered:

- Kubelet eviction. On a real node the kubelet evicts pods that use more than their request once node memory
  runs low, often before the kernel OOM-kills anything. kind's kubelet sees the host's RAM, so eviction never
  triggered here; the pod over its request is the one that goes either way.
- Swap. Pods run with `memory.swap.max=0` (kubelet `NoSwap`). With `LimitedSwap`, retained heap pages would
  be swapped instead of OOM-killed.
- The `alloc` mode ran once, at one rate (20 MiB/s). The release delay is about the time to allocate
  the spike's remaining heap headroom plus one GC cycle at base. A slower app releases later, approaching
  the idle case's 2–3.5 min.
- Two samples per run. The default timing depends on where the 2-minute periodic GC falls relative to
  the spike end: 170s and 210s for default, 120s for gomemlimit-800, about 240s in the local run.

## Requests and limits for Go pods

`request` < `limit` (Burstable QoS) works for Go apps only if all of these hold:

1. **The app returns the spike quickly.** A busy app does so with default settings (10–20s here). An app
   that goes idle after a spike needs `debug.FreeOSMemory()` when the spike ends, or it holds the memory
   for minutes.
2. **Spikes on a node do not overlap.** Every OOM kill here came from two spikes, or a spike plus memory not
   yet returned, on the same node. Replicas of one service behind a load balancer usually spike together.
3. **The node has room for the spike above the requests.** The scheduler places pods by requests only:
   with 250Mi requests it would put four of these apps on the 1200 MiB node, not two. Four at base
   (4 × ~215 MiB) plus one spike (+600 MiB) exceed the node even if every app returns memory perfectly.
   Nothing reserves that headroom; you rely on spikes staying rare and uncorrelated.

If they hold:

- `request`: steady-state RSS including garbage, about twice the live heap with `GOGC=100` (the `alloc` app:
  100 MiB live, ~215 MiB RSS).
- `limit`: spike peak plus a margin.
- `GOMEMLIMIT`: about 90–95% of the limit. It does not make the app return memory, but it keeps garbage from
  pushing the app over its own limit during a spike.

Use `request` = `limit` (Guaranteed QoS) when spikes are correlated (replicas), when the pod is critical, or
when the app keeps its memory (idle after spikes without `FreeOSMemory`, or a JVM with `-Xms` = `-Xmx`).
Memory cannot be throttled like CPU, so overcommitting it means accepting OOM kills.
