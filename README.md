# Linux 7.2.9 kernel-efficiency package

Stock **Linux 7.2.9** source plus a measurement harness, patches, and scored results from an efficiency roadmap (tasks 0–16).

The stock tree is **not** modified by this package. Apply patches only when you intentionally build a test kernel.

## Layout

```
linux-kernel/
  linux-7.2.9/           # untouched stock source (in git)
  kernel-measure/        # measurement harness, reports, lean runs index, patches copy
  patches/               # same patches at repo top level for easy browsing
  RESULTS.md             # pointer to scoreboard + how to read reports
  README.md              # this file
  # optional local only (gitignored): linux-7.2.9.tar.xz, parts/
```

## Goal

Evaluate concrete kernel (and policy) ideas for efficiency on a real host, with a repeatable before/after harness — then keep what wins and leave alone what does not. Artificial intelligence analyzed existing source code looking for areas with optimization potential, results of this analysis produced sixteen tasks. Optimization was attempted for each task, changes were benchmarked against stock kernel. Results provided below... 

Task | Verdict | Note
-----|---------|-----
0 | PASS (harness) | Measurement framework built; collect/compare/tasks.conf/workloads in place.
1 | FAIL | per-LLC idle bitmap (v1+v2) regresses wake latency / rq_latency vs stock on this 1-LLC box. No ship. See task1-before-after.txt / task1-v2-before-after.txt.
2 | INCONCLUSIVE | One migration policy (ai-opt) — not a claimed win; 1-NUMA/1-LLC cannot prove NUMA half. task2-before-after.txt.
3 | INCONCLUSIVE | cgroup deadline servers (t3) — not a claimed win / not clear fail. task3-before-after.txt.
4 | BLOCKED | TCP recv zero-copy needs NIC HDS/memory-provider; wl_zc_available=0 here. No patch. task4-before-after.txt.
5 | PASS (app-path) | Hot buffered reads: mmap beats buffered copy on stock; no kernel patch. task5-before-after.txt.
6 | PASS (policy) | Anon fault zeroing amortized via PMD/mTHP already in-tree; no patch. task6-before-after.txt.
7 | PASS (policy) | Prefer thp defrag=defer (+ proactive compaction); no ungated reclaim skip. task7-before-after.txt.
8 | PASS (policy) | Order-aware THP_SWAP already keeps large anon folios; no never-split patch. task8-before-after.txt.
9 | WEAK WIN | Lockless single-issuer io_uring (7.2.9-t9) — submission throughput up; boot left on t9. task9-before-after.txt.
10 | PASS (harness) | Locality/cache-miss telemetry; 1-LLC caps documented. No kernel win claim. task10-before-after.txt.
11 | PASS (policy) | util_est already in placement; NO_UTIL_EST A/B no clear win to rip out. task11-before-after.txt.
12 | PASS (policy) | softirq/RCU defer via boot knobs works but regresses softirq_storm — leave OFF. task12-before-after.txt.
13 | SKIP / DEFERRED | Unbound work LLC pin — not measurable on 1-LLC box. (Noted in task12 report.)
14 | SKIP / DEFERRED | NUMA hint-fault off access path — not measurable on 1-NUMA box. (Noted in task12 report.)
15 | PASS (leave-alone) | Hashed folio_wait_table kept; collision stress shows no herd win vs storage noise; no per-folio WQ patch. task15-before-after.txt.
16 | PASS (leave-alone) | SysV IPC stays stock; migrate callers to POSIX mq / io_uring; no kernel redesign. task16-before-after.txt.


## Harness (`kernel-measure/`)

- **Scripts:** `collect.sh`, `baseline.sh`, `compare.sh`, plus task-specific `run-t*.sh` helpers.
- **Config:** `tasks.conf`, `workloads.conf`, `workloads/`, `lib/`, `bpf/`.
- **Reports:** `reports/scoreboard-tasks-0-16.txt` and per-task `task*-before-after.txt`.
- **Runs (staged):** `runs/INDEX.md`, `SETS.txt` / `*-SETS.txt`, and `BASELINE-MAP.txt` — not the full raw perf trees (those remain on the measurement server).
- **Patches (copy):** `kernel-measure/patches/` mirrors top-level `patches/`.

Run the harness on a **Linux** host booted into the kernel under test. Collectors skip gracefully when tools are missing; see `kernel-measure/README.md` for details.

## Scoreboard summary

Measured on a single-socket Xeon E-2386G (12 CPUs, 1×12 MiB L3). Headline outcomes:

- **Weak win shipped:** Task 9 — lockless single-issuer io_uring (`0009-io-uring-lockless-single-issuer.patch`).
- **Failed / do not ship here:** Task 1 — per-LLC idle bitmap (v1 + v2) regresses wake latency on this 1-LLC topology.
- **Policy / leave-alone PASSes:** Tasks 5–8, 11–12, 15–16 (prefer existing knobs or userspace paths; no new kernel claim).
- **Inconclusive on this box:** Tasks 2–3 (NUMA / cgroup DL servers).
- **Blocked / deferred:** Task 4 (NIC HDS); Tasks 13–14 (need multi-LLC / multi-NUMA).

See [`RESULTS.md`](RESULTS.md) and [`kernel-measure/reports/scoreboard-tasks-0-16.txt`](kernel-measure/reports/scoreboard-tasks-0-16.txt).

## Patches included

| Patch | Task | Outcome on this host |
| --- | --- | --- |
| `0001-per-llc-idle-bitmap.patch` | 1 | FAIL |
| `0001-per-llc-idle-bitmap-v2.patch` | 1 | FAIL |
| `0002-one-migration-policy.patch` | 2 | INCONCLUSIVE |
| `0003-cgroup-deadline-servers-prototype.patch` | 3 | INCONCLUSIVE |
| `0009-io-uring-lockless-single-issuer.patch` | 9 | WEAK WIN |

## What’s in vs out of this tree

**In**

- Stock `linux-7.2.9/` source tree.
- Full measurement harness sources and configs.
- All scored reports + scoreboard.
- Patches listed above (top-level and under `kernel-measure/patches/`).
- Lean `runs/` index and SETS / baseline maps.

**Out (on purpose)**

- `linux-7.2.9.tar.xz` and `parts/` (redundant with the unpacked tree; gitignored).
- Raw large `perf` / collector run directories (see `kernel-measure/runs/INDEX.md` for ids; data lives on the test host).
- Built kernels / installed boot entries from the lab machine.
- Any modifications to stock `linux-7.2.9/` source.

## Quick start (reading results)

1. Open `RESULTS.md`.
2. Open `kernel-measure/reports/scoreboard-tasks-0-16.txt`.
3. Drill into `kernel-measure/reports/taskN-before-after.txt` for any task of interest.
