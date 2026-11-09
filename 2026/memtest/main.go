// memtest holds a base amount of memory, holds spike-mib more for a while, then drops back to
// base and runs forever. It exports Go runtime, process (smaps), and cgroup memory metrics so the
// question "does a Go process give RAM back to the OS without a restart?" can be answered in
// Grafana. See README.md for the experiments.
package main

import (
	"bufio"
	"flag"
	"log"
	"net/http"
	_ "net/http/pprof"
	"os"
	"runtime"
	"runtime/debug"
	"runtime/trace"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	mib      = 1 << 20
	pageSize = 4096
)

var (
	addr        = flag.String("addr", ":6060", "listen address for /metrics, /debug/pprof and /debug/flightrecorder")
	experiment  = flag.String("experiment", "local", "experiment name, exported as a label of memtest_info")
	baseMiB     = flag.Int("base-mib", 200, "memory held for the whole lifetime")
	spikeMiB    = flag.Int("spike-mib", 600, "extra memory held during the spike")
	spikeAfter  = flag.Duration("spike-after", 2*time.Minute, "time from start to the spike")
	spikeFor    = flag.Duration("spike-for", 2*time.Minute, "spike duration")
	freeOSEvery = flag.Duration("free-os-memory-every", 0, "call debug.FreeOSMemory at this interval; 0 disables it")
	churnMiB    = flag.Int("churn-mib-per-sec", 0, "allocate this much short-lived garbage per second, like a service handling requests; 0 disables it")
)

var (
	heldBytes = prometheus.NewGauge(prometheus.GaugeOpts{Name: "memtest_held_bytes", Help: "Bytes the app intentionally keeps reachable."})
	phase     = prometheus.NewGauge(prometheus.GaugeOpts{Name: "memtest_phase", Help: "0 = base, 1 = spike."})
	freeOS    = prometheus.NewCounter(prometheus.CounterOpts{Name: "memtest_free_os_memory_calls_total", Help: "debug.FreeOSMemory calls."})
)

func main() {
	flag.Parse()

	fr := trace.NewFlightRecorder(trace.FlightRecorderConfig{MinAge: time.Minute, MaxBytes: 16 << 20})
	if err := fr.Start(); err != nil {
		log.Fatalf("start flight recorder: %v", err)
	}

	reg := prometheus.NewRegistry()
	reg.MustRegister(
		// All runtime/metrics (heap classes, released, goal, GC cycles, scavenger CPU) plus the
		// runtime.ReadMemStats-based go_memstats_* series.
		collectors.NewGoCollector(collectors.WithGoCollectorRuntimeMetrics(collectors.MetricsAll)),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		procCollector{},
		heldBytes, phase, freeOS,
		prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Name: "memtest_info",
			Help: "Experiment settings; always 1.",
			ConstLabels: prometheus.Labels{
				"experiment":           *experiment,
				"godebug":              os.Getenv("GODEBUG"),
				"gomemlimit":           os.Getenv("GOMEMLIMIT"),
				"free_os_memory_every": freeOSEvery.String(),
				"churn_mib_per_sec":    strconv.Itoa(*churnMiB),
			},
		}, func() float64 { return 1 }),
	)

	http.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	http.HandleFunc("/debug/flightrecorder", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		if _, err := fr.WriteTo(w); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
	})
	go func() { log.Fatal(http.ListenAndServe(*addr, nil)) }()

	if *churnMiB > 0 {
		go churn(*churnMiB)
	}
	if *freeOSEvery > 0 {
		go func() {
			for range time.Tick(*freeOSEvery) {
				debug.FreeOSMemory()
				freeOS.Inc()
			}
		}()
	}

	log.Printf("experiment=%s base=%dMiB spike=+%dMiB after=%s for=%s free-os-memory-every=%s churn=%dMiB/s GODEBUG=%q GOMEMLIMIT=%q",
		*experiment, *baseMiB, *spikeMiB, *spikeAfter, *spikeFor, *freeOSEvery, *churnMiB, os.Getenv("GODEBUG"), os.Getenv("GOMEMLIMIT"))

	base := hold(*baseMiB)
	heldBytes.Set(float64(len(base) * mib))
	log.Printf("holding base %d MiB", *baseMiB)

	time.Sleep(*spikeAfter)
	spike := hold(*spikeMiB)
	phase.Set(1)
	heldBytes.Set(float64((len(base) + len(spike)) * mib))
	log.Printf("spike: holding %d MiB", *baseMiB+*spikeMiB)

	time.Sleep(*spikeFor)
	// Without KeepAlive the compiler treats spike as dead after its last use above, and a GC
	// during the sleep frees it before the spike is over.
	runtime.KeepAlive(spike)
	phase.Set(0)
	heldBytes.Set(float64(len(base) * mib))
	log.Printf("spike over: holding %d MiB", *baseMiB)

	// Keep base reachable forever. Without --churn-mib-per-sec nothing allocates from here on, so only
	// the runtime's periodic GC (sysmon forces one every 2 min) and the background scavenger act.
	for {
		time.Sleep(time.Hour)
		runtime.KeepAlive(base)
	}
}

// hold allocates n 1 MiB chunks and writes one byte per page, so every page is resident:
// memory fresh from the OS is already zero and Go does not touch it.
// churnSink makes each churn allocation escape to the heap; a local 64 KiB slice could live on the stack.
var churnSink []byte

// churn allocates mibPerSec MiB per second as 64 KiB objects that die right away, writing every page
// like a request handler would, so the GC runs as in a busy service.
func churn(mibPerSec int) {
	const obj = 64 << 10
	perTick := mibPerSec * mib / obj / 100 // every 10 ms
	for range time.Tick(10 * time.Millisecond) {
		for range perTick {
			churnSink = make([]byte, obj)
			for p := 0; p < obj; p += pageSize {
				churnSink[p] = 1
			}
		}
	}
}

func hold(n int) [][]byte {
	chunks := make([][]byte, n)
	for i := range chunks {
		chunks[i] = make([]byte, mib)
		for p := 0; p < mib; p += pageSize {
			chunks[i][p] = 1
		}
	}
	return chunks
}

// procCollector exports the kernel's view of this process and of its cgroup (the container):
// /proc/self/smaps_rollup (Rss, Anonymous, LazyFree, Private_Dirty, Swap, ...),
// /sys/fs/cgroup/memory.{stat,events,current,max,swap.current,pressure}.
type procCollector struct{}

var (
	smapsDesc    = prometheus.NewDesc("memtest_smaps_rollup_bytes", "/proc/self/smaps_rollup field.", []string{"field"}, nil)
	cgStatDesc   = prometheus.NewDesc("memtest_cgroup_memory_stat", "/sys/fs/cgroup/memory.stat field: bytes, or event count for pg*, workingset_*, thp_* fields.", []string{"field"}, nil)
	cgEventsDesc = prometheus.NewDesc("memtest_cgroup_memory_events_total", "/sys/fs/cgroup/memory.events field.", []string{"field"}, nil)
	cgFileDesc   = prometheus.NewDesc("memtest_cgroup_memory_bytes", "/sys/fs/cgroup/memory.<file>; max is absent when unlimited.", []string{"file"}, nil)
	cgPSIDesc    = prometheus.NewDesc("memtest_cgroup_memory_pressure_seconds_total", "/sys/fs/cgroup/memory.pressure total stall time.", []string{"kind"}, nil)
)

func (procCollector) Describe(chan<- *prometheus.Desc) {} // unchecked: fields depend on the kernel

func (procCollector) Collect(ch chan<- prometheus.Metric) {
	// smaps_rollup lines: "Rss:              123456 kB"; the first line is the address range.
	eachLine("/proc/self/smaps_rollup", func(f []string) {
		if len(f) == 3 && f[2] == "kB" {
			emit(ch, smapsDesc, prometheus.GaugeValue, f[1], 1024, strings.TrimSuffix(f[0], ":"))
		}
	})
	// memory.stat mixes byte gauges and event counters, so it stays untyped.
	eachLine("/sys/fs/cgroup/memory.stat", func(f []string) {
		emit(ch, cgStatDesc, prometheus.UntypedValue, f[1], 1, f[0])
	})
	eachLine("/sys/fs/cgroup/memory.events", func(f []string) {
		emit(ch, cgEventsDesc, prometheus.CounterValue, f[1], 1, f[0])
	})
	for _, file := range []string{"current", "max", "swap.current", "swap.max", "peak"} {
		// Single-value files; "max" (unlimited) fails to parse and is skipped.
		eachLine("/sys/fs/cgroup/memory."+file, func(f []string) {
			emit(ch, cgFileDesc, prometheus.GaugeValue, f[0], 1, file)
		})
	}
	// memory.pressure: "some avg10=0.00 avg60=0.00 avg300=0.00 total=12345" (total in µs).
	eachLine("/sys/fs/cgroup/memory.pressure", func(f []string) {
		if total, ok := strings.CutPrefix(f[len(f)-1], "total="); ok {
			emit(ch, cgPSIDesc, prometheus.CounterValue, total, 1e-6, f[0])
		}
	})
}

func emit(ch chan<- prometheus.Metric, d *prometheus.Desc, t prometheus.ValueType, v string, scale float64, label string) {
	n, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return
	}
	ch <- prometheus.MustNewConstMetric(d, t, n*scale, label)
}

// eachLine calls fn with the whitespace-separated fields of every non-empty line of path.
// Missing files (e.g. no cgroup v2 when run outside a container) are skipped silently.
func eachLine(path string, fn func([]string)) {
	f, err := os.Open(path)
	if err != nil {
		logOnce(path, err)
		return
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		if fields := strings.Fields(s.Text()); len(fields) > 0 {
			fn(fields)
		}
	}
}

var logged sync.Map

func logOnce(path string, err error) {
	if _, dup := logged.LoadOrStore(path, true); !dup {
		log.Printf("metrics: %v", err)
	}
}
