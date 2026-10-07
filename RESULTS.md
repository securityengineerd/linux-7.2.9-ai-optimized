# Measurement results (pointer)

This directory holds the Linux 7.2.9 efficiency-roadmap measurement package beside an **untouched** stock `linux-7.2.9/` tree.

## Where to look

| File / path | What it is |
| --- | --- |
| [`kernel-measure/reports/scoreboard-tasks-0-16.txt`](kernel-measure/reports/scoreboard-tasks-0-16.txt) | **Primary scoreboard** for tasks 0–16 (verdict + one-line note). Start here. |
| `kernel-measure/reports/task*-before-after.txt` | Per-task before/after compare tables and notes. |
| `kernel-measure/reports/*-survey*.txt` | Survey / prep notes for selected tasks. |
| [`kernel-measure/runs/INDEX.md`](kernel-measure/runs/INDEX.md) | Inventory of run ids on the test host (raw perf dirs not shipped). |
| `kernel-measure/runs/*SETS*` / `BASELINE-MAP.txt` | Which run ids belong to each baseline / A/B arm. |
| [`patches/`](patches/) | Kernel patches exercised in the campaign (also under `kernel-measure/patches/`). |

## How to read a report

1. Open the scoreboard for the task’s **Verdict** (PASS / FAIL / WEAK WIN / INCONCLUSIVE / BLOCKED / SKIP).
2. Open the matching `taskN-before-after.txt` for metrics, deltas, and caveats (topology: 1 socket / 1 NUMA / 1×12 MiB L3).
3. If you need the exact collect sets, check `runs/BASELINE-MAP.txt` and `runs/INDEX.md` — full raw `perf` trees stay on the measurement host (`kernelmaster`), not in this tree.

## Scoreboard snapshot (tasks 0–16)

Host: Xeon E-2386G, 12 CPUs, 31 GB, 1 LLC — measured on `kernelmaster`.

| Task | Verdict | Note |
| --- | --- | --- |
| 0 | PASS (harness) | Measurement framework in place. |
| 1 | FAIL | per-LLC idle bitmap regresses wake/rq latency on this 1-LLC box. |
| 2 | INCONCLUSIVE | One migration policy — cannot prove NUMA half here. |
| 3 | INCONCLUSIVE | cgroup deadline servers prototype — not a claimed win. |
| 4 | BLOCKED | TCP recv zero-copy needs NIC HDS; no patch. |
| 5 | PASS (app-path) | Hot buffered reads: mmap beats buffered copy on stock. |
| 6 | PASS (policy) | Anon fault zeroing amortized via PMD/mTHP already in-tree. |
| 7 | PASS (policy) | Prefer `thp defrag=defer` (+ proactive compaction). |
| 8 | PASS (policy) | Order-aware THP_SWAP already keeps large anon folios. |
| 9 | WEAK WIN | Lockless single-issuer io_uring — submission throughput up. |
| 10 | PASS (harness) | Locality/cache-miss telemetry; 1-LLC caps documented. |
| 11 | PASS (policy) | util_est already in placement; no clear win to rip out. |
| 12 | PASS (policy) | softirq/RCU defer knobs regress softirq_storm — leave OFF. |
| 13 | SKIP / DEFERRED | Unbound work LLC pin — needs multi-LLC hardware. |
| 14 | SKIP / DEFERRED | NUMA hint-fault — needs multi-NUMA hardware. |
| 15 | PASS (leave-alone) | Hashed folio_wait_table kept; no per-folio WQ patch. |
| 16 | PASS (leave-alone) | SysV IPC stays stock; prefer POSIX mq / io_uring. |

Full text: `kernel-measure/reports/scoreboard-tasks-0-16.txt`.
