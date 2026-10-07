# kernel-measure

Task 0 measurement harness for a Linux kernel under test. It records a baseline and, later, a before/after comparison. It does not modify a kernel tree, and it does not install or boot a kernel.

Run it on the Linux machine that is actually booted into the kernel under test. `collect.sh` and `baseline.sh` exit immediately when `uname -s` is not Linux, including on macOS.

No collector requires root. If a tool or a tracefs write is missing, that collector is skipped and the run summary says so. A skipped workload is not a failed run. A workload that exits with any status other than 0 or 2 fails the run. `baseline.sh` does not publish `runs/BASELINE` when any workload fails.

## Rule

No implementation task starts until a baseline exists.

`runs/BASELINE` is the gate. It is a symlink to one `--all` set directory. If it is missing, stop. Do not start an implementation task, and do not treat a partial or failed set as the baseline.

## Layout

| Path | Role |
| --- | --- |
| `workloads.conf` | Durations and knobs. Original workloads default to 15 seconds or less; `wake_llc` and `migrate_load` default to 30 seconds or less. |
| `tasks.conf` | Task map: roadmap task id 0-16 to name, what it measures, required workloads, primary metrics, and a one-line pass/fail note. |
| `workloads/*.sh` | One concrete command per category, plus the documented fallback. |
| `workloads/src/*.c` | Engines for `wake_llc` (`wake_storm.c`) and `migrate_load` (`migrate_storm.c`). |
| `build/` | Compiled engines, built on the test host on first use (outside perf stat) and reused across boots so stock and patched runs use the same binary. Not shipped; safe to delete. |
| `lib/build_tool.sh` | Builds `workloads/src/NAME.c` into `build/NAME` when the source hash changes. |
| `collect.sh` | One workload, `--task N`, or `--all`. |
| `baseline.sh` | `collect.sh --all` (or `--task N`), then point `runs/BASELINE` (or `runs/BASELINE-taskN`) at that set. |
| `compare.sh` | Plain-text before/after table for two run directories or two sets. `--task N` picks that task's workloads and metrics. |
| `bpf/runq_latency.bt` | bpftrace runqueue-latency script. Used only when `bpftrace` is installed. |
| `lib/delta.awk` | Exact integer deltas and the compare table. |
| `runs/<timestamp>-set/` | One `--all` invocation. |
| `runs/<timestamp>-taskN/` | One `--task N` invocation (only that task's workloads). |
| `runs/<timestamp>-<workload>` | Symlink into that set, or a directory when a single workload was collected. |

Timestamps look like `20261003T194530-0700` (local time of the test machine).

## How to run a baseline

On the Linux test host:

```bash
./baseline.sh
```

That runs every workload once and, only if none of them fail, creates `runs/BASELINE` as a relative symlink to `runs/<timestamp>-set`.

`baseline.sh` will not replace an existing baseline unless you pass `--force`. `--force` moves the symlink only. It does not delete old run directories.

Do not run two collects at once. They share tracefs when tracing is enabled, and the second one will refuse to touch an already-active tracer.

## How a later task records before and after

1. Confirm the gate: `test -L runs/BASELINE`. Read `runs/BASELINE/general/meta/uname.txt` (any workload's `meta/` is the same boot) and write down the kernel you measured.
2. Make the kernel change outside this harness, build it, and boot it on the test machine. This harness does not do that.
3. On the new boot, from this same directory: `./collect.sh --all`
   The last stdout line is `RUN_SET=<dir>`.
4. Compare against the published baseline, not against a loose run:

```bash
./compare.sh runs/BASELINE "$RUN_SET" | tee "runs/compare-$(date +%Y%m%dT%H%M%S%z).txt"
```

5. Keep that text with the task notes. Do not move `runs/BASELINE` unless you mean to change the reference (`baseline.sh --force`).

`compare.sh` treats the first directory as before and the second as after. `delta = after - before`.

## Per-task before/after (`--task N`)

`tasks.conf` maps every roadmap task to the workloads that exercise it and the metrics to read. List it with `./collect.sh --list-tasks`.

| Task | Name | Workloads | Primary metrics (first rows of `compare.sh --task N`) |
| --- | --- | --- | --- |
| 0 | measurement harness | all eight | cycles, instructions, cache_misses, rq_latency_ns |
| 1 | per-LLC idle bitmap | wake_llc general | wake latency p50/p99 (idle and busy phases), rq_latency_ns, ttwu_remote_delta, ttwu_count_delta, cpu_migrations, context_switches, cache_misses, cache_misses_per_kinstr, cycles, instructions, ipc |
| 2 | one migration policy | migrate_load general | loads/sec per phase (free, storm, settle), settle nr_migrations, cpu_migrations, cache_misses, cache_misses_per_kinstr, cycles, instructions, ipc, rq_latency_ns |
| 3 | cgroup deadline servers | cgroup_cpu general | wl_weight_err_pct, wl_throttled_usec, cycles, instructions, rq_latency_ns, cache_misses |
| 4 | TCP recv zero-copy | tcp_recv_zc | cycles, instructions, cache_misses, wall time, wl_bytes_per_sec, wl_zc_available |
| 5 | buffered-read copy | database storage | cycles, instructions, cache_misses, wall time |
| 6 | anon write-fault zeroing / mTHP | general | cycles, instructions, cache_misses, tlb_misses |
| 7 | background reclaim/compaction | database general | wall time, rq_latency_ns, compact_stall_delta, pgsteal_delta |
| 8 | large anon folios on reclaim | general containers | pgsteal/pgscan deltas, thp_fault_fallback_delta, cache_misses |
| 9 | lockless io_uring submission | storage networking | cycles, instructions, wall time, cache_misses |
| 10 | cache-miss accounting | wake_llc migrate_load general database | cache_misses, cache_misses_per_kinstr, cycles, instructions, ipc, cpu_migrations, rq_latency_ns |
| 11 | util_est for placement | general wake_llc | cycles, instructions, ipc, rq_latency_ns, cpu_migrations, cache_misses |
| 12 | softirq/RCU off irq-exit | networking storage | rq_latency_ns, wall time, cycles |
| 13 | unbound work LLC pin | storage general | cache_misses, cache_misses_per_kinstr, cycles, instructions, cpu_migrations |
| 14 | NUMA hint-fault off access path | database | numa_hint_faults_delta, cycles, wall time, cache_misses |
| 15 | per-folio wait queue | database storage | cycles, instructions, wall time |
| 16 | SysV IPC leave-alone | general | cycles, instructions, wall time |

Tasks 1-3, 4 and 9 (and 10/11, which reuse 1/2) have workloads aimed at their code path (`wake_llc`, `migrate_load`, `cgroup_cpu`, `tcp_recv_zc`, `io_uring_submit`). Tasks 5-8 and 12-16 reuse the original workloads, which do not target those paths (for example, nothing here creates memory pressure). For those tasks a before/after is a regression screen, not proof of the change.

`LLC-load-misses`, `dTLB-load-misses`, and `iTLB-load-misses` are not accepted by perf on the test CPU (Xeon E-2386G). The harness still asks for them and drops them. Read `cache-misses` (plus `cache_misses_per_kinstr`), `cycles`, `instructions`, and `rq_latency_ns` instead.

```bash
./collect.sh --task 1                     # only wake_llc + general -> runs/<stamp>-task1, prints RUN_SET=
./baseline.sh --task 1                    # same, then runs/BASELINE-task1 -> that set
./compare.sh --task 1 BEFORE_SET AFTER_SET
```

`compare.sh --task N` prints both kernels (from `meta/kernel_version.txt`), warns when both sides ran on the same kernel, when the workload command line differs, or when schedstats state differs, then prints the task's primary metrics followed by every `wl_*` metric the workload reported. It ends with the task's pass/fail note. It does not compute a verdict.

### Rule: BASELINE on stock first, then patched

For every task, the baseline is collected on the **stock** kernel before the patched kernel is ever measured for that task. Do not collect the patched side first and back-fill the baseline later.

### Task 1: stock vs patched

On the test host the stock build is `7.2.9-baseline` and the Task 1 build (patch `0001-per-llc-idle-bitmap.patch`) is `7.2.9-llc-idle`. This harness does not build, install, or boot either. Booting is a manual step outside the harness.

1. Boot the stock kernel. Confirm with `uname -r` (expect `7.2.9-baseline`).
2. Keep the box quiet (no other jobs). Optionally pin the governor the same way on both boots; `meta/scaling_governor.txt` records it.
3. Collect the stock side, with schedstats so `ttwu_*` is populated (needs root or passwordless sudo; the previous sysctl value is restored on exit):

   ```bash
   ./baseline.sh --task 1 --schedstats      # -> runs/BASELINE-task1 (stock)
   ./collect.sh  --task 1 --schedstats      # repeat 2+ more times; note each RUN_SET
   ```

   The first `wake_llc` run builds `build/wake_storm`. Later runs, including the patched boot, reuse that exact binary; `build_info.txt` in each run records its sha256.
4. Reboot into the patched kernel (`7.2.9-llc-idle`). Confirm with `uname -r`.
5. Collect the patched side with the same command, the same `workloads.conf`, and the same flags, the same number of times:

   ```bash
   ./collect.sh --task 1 --schedstats       # x3; note each RUN_SET
   ```

6. Compare against the stock baseline:

   ```bash
   ./compare.sh --task 1 runs/BASELINE-task1 "$RUN_SET" | tee "runs/compare-task1-$(date +%Y%m%dT%H%M%S%z).txt"
   ```

   Also compare stock run 2 against stock run 3. That same-kernel pair is your noise floor. Two identical-kernel runs of `wake_llc` can differ by tens of percent on p99 and max, so a patched-minus-stock delta smaller than the stock-minus-stock spread is not a result.
7. Read the rows in this order: `wl_busy_wake_lat_p50_ns` / `wl_busy_wake_lat_p99_ns` (busy phase, where the idle search has to skip busy CPUs), `wl_idle_*` latency, `ttwu_remote_delta` relative to `ttwu_count_delta`, `rq_latency_ns`, then `cache-misses` / `cache_misses_per_kinstr` and `ipc`. Task 1 passes only if the patched kernel shows lower wake-to-run latency and no increase in remote wakeups, consistently across the repeats, and `general` does not regress beyond its own noise.

The same recipe works for any task: `--task 2` on stock, reboot, `--task 2` on the patched build, `compare.sh --task 2`.

## Workloads

Eight categories are in the manifest. The task list named five and then added virtualization; virtualization is included and always skipped.

| Category | Default | Command | If the tool is missing |
| --- | --- | --- | --- |
| general | 10s | `stress-ng --cpu 2 --fork 2 --timeout 10s` (`--metrics-brief` only if that flag exists) | python3 CPU + `fork`/`wait` loop; else the same loop in bash |
| containers | 10s, at most 3 runs | `docker` or `podman` `run --rm --network none --entrypoint /bin/true <local image>` | skip if neither runtime exists, `info` fails, or no local image matches `CONTAINER_IMAGE_CANDIDATES`. Never pulls. |
| database | 10s | `sqlite3` temp db: create, insert `SQLITE_ROWS` (2000), update, select, delete, `synchronous=FULL` | if `sqlite3` is absent and `sysbench` is present: `sysbench threads --threads 2 --thread-yields 200 --time 10 run`. That is a stand-in. sysbench OLTP needs a database server, which this harness will not configure. If neither tool exists, skip. |
| storage | 8s | `fio` randrw 4k, 32M, `--direct=1` on a file under `$TMPDIR` | `dd` `bs=1M count=32 oflag=direct`, then read it back. If `O_DIRECT` fails, retry buffered and record that. The file is removed on exit. |
| networking | 8s | `iperf3` server and client on `127.0.0.1` only | python3 loopback TCP transfer. No off-host traffic. |
| virtualization | n/a | none | skip. If `qemu-system-*` is on `PATH`, record `--version`. A VM is never launched. |
| wake_llc | 20s | `build/wake_storm` (Task 1). 2 messenger threads each futex-wake `nproc` workers in a burst every 1 ms; each worker records wake-to-run latency (waker timestamp to first instruction after `futex_wait` returns), spins 20 us, sleeps. First half: storm only (mostly idle LLC). Second half: plus `nproc/2` spinner threads, so the idle search has to skip busy CPUs. Writes `workload.metrics` (`wl_idle_*`, `wl_busy_*`: wakes, p50/p90/p99/p99.9/max/mean latency, CPU-changed and on-waker-CPU permille). | `stress-ng --switch $(nproc)` (perf/schedstat only, no per-wake latency). Skip if neither a C compiler nor stress-ng exists. |
| migrate_load | 18s | `build/migrate_storm` (Task 2). `nproc*1.5` pointer-chase workers, 256 KiB private working set each. Phases of 6s: free (balancer only), storm (pin each worker to a rotating single CPU, then unpin, every 10 ms), settle (full mask, recovery). Writes per-phase loads/sec, observed CPU changes, `se.nr_migrations` sums, NUMA node count, L3 domain count. | `stress-ng --affinity $(nproc) --affinity-rand --cache $(nproc)/2`. Skip if neither exists. |

`wake_llc` and `migrate_load` have a prepare step (`# kernel-measure: prepare` in the script header). `collect.sh` runs `workload.sh --prepare` before perf/trace/schedstat start, so compiling the engine is never counted. `build/` is reused across boots.

**Single-socket limit for Task 2.** The test host has one socket, one NUMA node, and one L3 (12 MiB shared by CPUs 0-11). The NUMA half of Task 2 (`get_pref_llc` vs `numa_preferred_nid`) and cross-LLC preference cannot be proven on it: there is only one node and one LLC to prefer. `migrate_load` records this in `topology_note.txt` and as `wl_numa_nodes` / `wl_llc_domains`. What it can show is migration rate (`cpu_migrations`, `wl_*_nr_migrations`, `wl_*_cpu_changes`) and the L1/L2 refill cost of migrations (`wl_*_mloads_per_sec`, `cache-misses`).

Exit 2 from a workload means "skipped on purpose". Those runs are not scored: cycles, misses, vmstat deltas, and wall time are `n/a` in `metrics.env`. The raw snapshots are still in the run directory.

`workloads.conf` is the only place durations live. A duration above 30 seconds prints a warning. `collect.sh` also applies an outer `timeout` of duration + `OUTER_TIMEOUT_GRACE` (15s) when `timeout(1)` exists.

## What each run records

For each workload, under the run directory:

- `meta/uname.txt`, `meta/kernel_version.txt`, `meta/date.txt`, `meta/cpu.txt`, `meta/meminfo_summary.txt`, `meta/scaling_governor.txt`
- `command.txt`, `workload.log`, `exit_code.txt`, `wall_time_sec.txt`, `summary.txt`, `metrics.env`
- perf, when `perf` exists: `perf stat -e <accepted events> -x,` around the workload. Requested events are `cycles`, `instructions`, `cache-references`, `cache-misses`, `LLC-load-misses`, `dTLB-load-misses`, `iTLB-load-misses`, `context-switches`, `cpu-migrations`. Derived: `ipc` = instructions / cycles, `cache_misses_per_kinstr` = cache-misses * 1000 / instructions. An event is kept only if `perf list` shows it and `perf stat -e EVENT -- true` accepts it. The rest are dropped and listed in `perf_probe.txt` and the summary.
- tracepoints, only when `/sys/kernel/debug/tracing` is mounted and writable, `current_tracer` is `nop`, and `sched:sched_switch` / `sched:sched_wakeup` are currently off. The harness enables those two events for the run, copies `trace` (capped at 32 MiB), restores the previous enable bits and `tracing_on`, and clears the buffer it used. It does not switch the tracer to `function_graph`. An `EXIT` trap disarms tracing if the script fails after it enabled anything. If tracing is already active, it is left alone.
- memory pressure: `/proc/vmstat` before and after. `vmstat.delta` lists `pgscan*`, `pgsteal*`, `compact_stall`, `compact_success`, `thp_fault_alloc`, `thp_fault_fallback`, and `numa_hint_faults` when those keys exist. `pgsteal_delta` and `pgscan_delta` are the sums. Absent keys stay `n/a`, not zero.
- runqueue latency: `/proc/schedstat` deltas, not `perf sched`. `perf sched record` needs extra privileges and would add its own load, so it is not used. On Linux 7.2.9, `kernel/sched/stats.c` `SCHEDSTAT_VERSION` 17 prints CPU lines as `cpuN yld_count legacy0 sched_count sched_goidle ttwu_count ttwu_local rq_cpu_time run_delay_ns pcount`. `legacy0` is always 0. The summary reports `sched_count`, `sched_goidle`, `run_delay_ns`, `pcount`, `rq_latency_ns` (`run_delay_ns_delta / pcount_delta`), and `ttwu_count`, `ttwu_local`, `ttwu_remote` (`ttwu_count - ttwu_local`: wakeups placed on a CPU other than the waker's). The same note is in `sched_method.txt`.
- schedstats: `sched_count`, `sched_goidle`, and `ttwu_*` only move while `kernel.sched_schedstats=1`. The host default is 0, so without `--schedstats` those keys are `n/a` (earlier runs reported them as 0, which was a frozen counter, not a measurement). `run_delay_ns`, `pcount`, and `rq_latency_ns` come from sched_info and are always valid. `collect.sh --schedstats` (or `SCHEDSTATS_ENABLE=1`) sets the sysctl to 1 for the collect, using a direct write or `sudo -n` (never prompts), and restores the previous value on exit. `metrics.env` records `schedstats=on|off|mixed|unavailable`.
- workload metrics: if the workload writes `workload.metrics`, its numeric `wl_*` keys plus `wl_engine` / `wl_args` are appended to `metrics.env`.
- bpftrace: if `bpftrace` is installed, `bpf/runq_latency.bt` runs beside the workload and is stopped with SIGINT so it can print the histogram. If it is not installed, the run records `bpftrace not installed` and continues. The script measures time from `sched_wakeup` of a task until `sched_switch` selects that task.

`summary.txt` is the human rollup. `metrics.env` is what `compare.sh` reads.

## Compare table

`compare.sh BEFORE AFTER` prints, per workload:

wall time, cycles, instructions, cache-misses, LLC misses, TLB misses, pgsteal delta, compact_stall delta.

TLB misses are `dTLB-load-misses + iTLB-load-misses`. Pass two set directories (including `runs/BASELINE`) or two single-workload directories.

## Smoke test

Syntax only. This does not create a baseline and does not boot a kernel.

```bash
bash -n collect.sh compare.sh baseline.sh workloads/*.sh lib/common.sh lib/build_tool.sh
awk -f lib/delta.awk -v mode=selftest
./collect.sh --help
./compare.sh --help
./baseline.sh --help
./collect.sh --list-tasks
```

One real run of the Task 1 workload (noisy; not a baseline):

```bash
./collect.sh wake_llc --runs-dir runs/smoke-wake_llc
```

## What this harness will not do

- Edit, build, install, or boot a kernel.
- Pull a container image.
- Launch a VM.
- Open a network connection to anything but `127.0.0.1`.
- Leave `sched:sched_switch` or `sched:sched_wakeup` enabled if this process turned them on.
- Require root. Privilege-gated collectors are skipped, not treated as success-with-zeros. `--schedstats` is opt-in and only uses non-interactive `sudo -n`.
- Claim a win from one run. `compare.sh` prints deltas and the task note; judging pass/fail across repeated runs is a human step.
