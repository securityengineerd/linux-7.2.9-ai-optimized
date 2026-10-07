#!/usr/bin/env bash
# Plain-text before/after table for two run directories, two --all sets, or
# (with --task N) the workloads and metrics that tasks.conf lists for task N.
set -euo pipefail
HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HARNESS_DIR/lib/common.sh"

usage() {
  cat <<USAGE
Usage: compare.sh BEFORE AFTER
       compare.sh --task N BEFORE AFTER

BEFORE and AFTER are either:
  - two workload run directories (each contains metrics.env), or
  - two set directories (each contains set.info): --all sets, --task sets,
    or runs/BASELINE / runs/BASELINE-taskN

The first path is "before". The second path is "after".
delta = after - before. Skipped workloads are not scored (metrics are n/a).

Without --task: prints wall time, cycles, instructions, cache-misses, LLC
misses, TLB misses (dTLB-load-misses + iTLB-load-misses), pgsteal delta, and
compact_stall delta for every workload.

With --task N: for each workload tasks.conf lists for task N, prints that
task's primary metrics plus every workload-reported wl_* metric, then the
task's pass/fail note. It prints both kernels and warns when they are the
same kernel or when the workload engine/arguments differ. It does not decide
pass or fail for you; single runs are noisy, so repeat and look at spread.

This script only reads result directories. It does not require Linux.
USAGE
}

TASK_ID=""
if [[ $# -ge 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi
if [[ $# -ge 1 && "$1" == "--task" ]]; then
  [[ $# -ge 2 ]] || die "--task needs a task id"
  TASK_ID=$2
  shift 2
elif [[ $# -ge 1 && "$1" == --task=* ]]; then
  TASK_ID=${1#--task=}
  shift
fi
if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

BEFORE=$1
AFTER=$2
[[ -d "$BEFORE" ]] || die "not a directory: $BEFORE"
[[ -d "$AFTER" ]] || die "not a directory: $AFTER"

is_set() { [[ -f "$1/set.info" ]]; }
is_run() { [[ -f "$1/metrics.env" ]]; }

field() {
  local file=$1 key=$2 line
  line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 || true)
  if [[ -z "$line" ]]; then
    echo n/a
  else
    printf '%s\n' "${line#*=}"
  fi
}

# Label for a metrics.env key in --task tables.
label_for() {
  case "$1" in
    wall_time_sec) echo "wall time (s)" ;;
    cache_misses) echo "cache-misses" ;;
    cache_miss_rate) echo "cache-miss-rate" ;;
    llc_load_misses) echo "LLC-load-misses" ;;
    llc_misses_per_kinstr) echo "LLC-misses/kinstr" ;;
    l3_misses) echo "l3-misses (PEBS)" ;;
    l3_hits) echo "l3-hits (PEBS)" ;;
    tlb_misses) echo "TLB-misses" ;;
    ttwu_remote_frac) echo "ttwu-remote-frac" ;;
    ttwu_remote_delta) echo "ttwu-remote" ;;
    rq_latency_ns) echo "rq_latency_ns (schedstat)" ;;
    wl_bursts_per_sec) echo "bursts/sec" ;;
    wl_wake_lat_p50_ns) echo "wake-lat p50 (ns)" ;;
    wl_wake_lat_p99_ns) echo "wake-lat p99 (ns)" ;;
    wl_burst_migrate_frac) echo "burst migrate frac" ;;
    wl_sched_feat_util_est) echo "UTIL_EST feat" ;;
    wl_softirq_total_delta) echo "softirq total delta" ;;
    wl_softirq_timer_delta) echo "TIMER softirq delta" ;;
    wl_softirq_net_rx_delta) echo "NET_RX softirq delta" ;;
    wl_softirq_rcu_delta) echo "RCU softirq delta" ;;
    wl_ksoftirqd_ms_delta) echo "ksoftirqd CPU ms delta" ;;
    wl_rcu_stall_lines_delta) echo "RCU stall dmesg delta" ;;
    wl_cmdline_threadirqs) echo "threadirqs cmdline" ;;
    wl_cmdline_rcu_nocbs) echo "rcu_nocbs cmdline" ;;
    wl_rcutree_use_softirq) echo "rcutree.use_softirq" ;;
    wl_folio_wait_ops_per_sec) echo "folio wait ops/s" ;;
    wl_folio_wait_lat_p50_ns) echo "folio wait lat p50" ;;
    wl_folio_wait_lat_p99_ns) echo "folio wait lat p99" ;;
    wl_folio_wait_mode) echo "folio wait mode" ;;
    wl_page_wait_table_bits) echo "PAGE_WAIT_TABLE_BITS" ;;
    *) echo "$1" ;;
  esac
}

TABLE_ROWS=""
EXTRA_PREFIX=""
if [[ -n "$TASK_ID" ]]; then
  tm=$(task_metrics "$TASK_ID") || exit 1
  rows="wall_time_sec|$(label_for wall_time_sec)"
  for m in $tm; do
    [[ "$m" == wall_time_sec ]] && continue
    rows="${rows},${m}|$(label_for "$m")"
  done
  TABLE_ROWS=$rows
  EXTRA_PREFIX=wl_
fi

run_kernel() {
  local d=$1
  if [[ -f "$d/meta/kernel_version.txt" ]]; then
    grep -E '^uname_r=' "$d/meta/kernel_version.txt" | head -n 1 | cut -d= -f2-
  else
    echo unknown
  fi
}

compare_pair() {
  local title=$1 a=$2 b=$3
  echo "== ${title} =="
  if [[ ! -f "$a/metrics.env" || ! -f "$b/metrics.env" ]]; then
    echo "missing metrics.env (workload not collected in one of the runs)"
    echo "before: $a"
    echo "after:  $b"
    echo
    return 0
  fi
  local kb ka cb ca
  kb=$(run_kernel "$a")
  ka=$(run_kernel "$b")
  echo "kernel_before: ${kb}"
  echo "kernel_after:  ${ka}"
  if [[ -n "$TASK_ID" && "$kb" == "$ka" && "$kb" != unknown ]]; then
    echo "WARNING: before and after ran on the same kernel (${kb}). Differences are run-to-run noise, not a patch effect."
  fi
  echo "status_before: $(field "$a/metrics.env" status)"
  echo "status_after:  $(field "$b/metrics.env" status)"
  if [[ -f "$a/skip_reason.txt" ]]; then
    echo "skip_before: $(head -n 1 "$a/skip_reason.txt")"
  fi
  if [[ -f "$b/skip_reason.txt" ]]; then
    echo "skip_after:  $(head -n 1 "$b/skip_reason.txt")"
  fi
  if [[ -n "$TASK_ID" ]]; then
    cb=$(head -n 1 "$a/command.txt" 2>/dev/null || echo unknown)
    ca=$(head -n 1 "$b/command.txt" 2>/dev/null || echo unknown)
    echo "command_before: ${cb}"
    if [[ "$cb" != "$ca" ]]; then
      echo "command_after:  ${ca}"
      echo "WARNING: workload command differs; the comparison is not like for like."
    fi
    local sb sa
    sb=$(field "$a/metrics.env" schedstats)
    sa=$(field "$b/metrics.env" schedstats)
    if [[ "$sb" != "$sa" ]]; then
      echo "WARNING: schedstats differs (before=${sb} after=${sa}); ttwu_*/sched_count rows are not comparable."
    fi
  fi
  awk -f "$HARNESS_DIR/lib/delta.awk" -v mode=table -v rows="$TABLE_ROWS" -v extra_prefix="$EXTRA_PREFIX" \
    "$a/metrics.env" "$b/metrics.env"
  echo
}

echo "before: $BEFORE"
echo "after:  $AFTER"
echo "delta = after - before"
if [[ -n "$TASK_ID" ]]; then
  echo "task ${TASK_ID}: $(task_name "$TASK_ID")"
  echo "measures: $(task_measures "$TASK_ID")"
  echo "workloads: $(task_workloads "$TASK_ID")"
  echo "primary metrics: $(task_metrics "$TASK_ID")"
fi
echo

if is_set "$BEFORE" && is_set "$AFTER"; then
  if [[ -n "$TASK_ID" ]]; then
    names=$(task_workloads "$TASK_ID") || exit 1
    read -r -a list <<<"$names"
  else
    list=("${WORKLOAD_IDS[@]}")
  fi
  for name in "${list[@]}"; do
    compare_pair "$name" "$BEFORE/$name" "$AFTER/$name"
  done
elif is_run "$BEFORE" && is_run "$AFTER"; then
  title=$(cat "$BEFORE/workload_name.txt" 2>/dev/null || basename "$BEFORE")
  compare_pair "$title" "$BEFORE" "$AFTER"
else
  die "both arguments must be workload run directories or both must be set directories (set.info)"
fi

if [[ -n "$TASK_ID" ]]; then
  echo "pass/fail note (judge by hand, across repeated runs): $(task_passfail "$TASK_ID")"
  echo "No verdict is computed. One run per side is not enough to claim a win."
fi
