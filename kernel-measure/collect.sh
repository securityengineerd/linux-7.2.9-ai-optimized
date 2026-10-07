#!/usr/bin/env bash
# Collect one named workload, or every workload, into runs/.
# Does not need root. Missing tools are skipped and named in the run summary.
set -euo pipefail
HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HARNESS_DIR/lib/common.sh"

RUNS_DIR="$HARNESS_DIR/runs"
CONFIG="$HARNESS_DIR/workloads.conf"
ALL=0
WORKLOAD=""
TASK_ID=""
SCHEDSTATS_FLAG=""

usage() {
  cat <<USAGE
Usage: collect.sh [--all | --task N | WORKLOAD] [--schedstats] [--config FILE] [--runs-dir DIR]
       collect.sh --list-tasks

WORKLOAD is one of: ${WORKLOAD_IDS[*]}

Records kernel identity, optional perf stat, optional sched tracepoints,
vmstat and /proc/schedstat deltas, and an optional bpftrace one-shot.
Missing tools are skipped and named in the run summary. Does not need root.
Refuses to run unless uname -s is Linux.

  --all        run every workload under runs/<timestamp>-set/<workload>/
  --task N     run only the workloads tasks.conf lists for task N, under
               runs/<timestamp>-taskN/<workload>/
  --list-tasks print the task -> workload map from tasks.conf and exit
  --schedstats enable kernel.sched_schedstats for the run and restore it after
               (needs root or passwordless sudo; same as SCHEDSTATS_ENABLE=1).
               Without it, sched_count/sched_goidle/ttwu_* are n/a when the
               sysctl is 0. run_delay_ns/pcount/rq_latency_ns never need it.
  --config     workload manifest (default: workloads.conf)
  --runs-dir   where run directories are created (default: <harness>/runs)
  -h, --help   show this help and exit

A single workload is stored at runs/<timestamp>-<workload>/.
On success, --all prints RUN_SET=<dir> and writes runs/LAST_SET.
On success, --task N prints RUN_SET=<dir> and writes runs/LAST_TASK<N>.
A single run prints RUN_DIR=<dir> and writes runs/LAST_RUN.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --all)
      ALL=1
      shift
      ;;
    --task)
      [[ $# -ge 2 ]] || die "--task needs a task id"
      TASK_ID=$2
      shift 2
      ;;
    --task=*)
      TASK_ID=${1#--task=}
      shift
      ;;
    --list-tasks)
      list_tasks
      exit 0
      ;;
    --schedstats)
      SCHEDSTATS_FLAG=1
      shift
      ;;
    --config)
      [[ $# -ge 2 ]] || die "--config needs a path"
      CONFIG=$2
      shift 2
      ;;
    --runs-dir)
      [[ $# -ge 2 ]] || die "--runs-dir needs a path"
      RUNS_DIR=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$WORKLOAD" ]]; then
        die "only one workload name is accepted"
      fi
      WORKLOAD=$1
      shift
      ;;
  esac
done

modes=0
[[ "$ALL" -eq 1 ]] && modes=$((modes + 1))
[[ -n "$WORKLOAD" ]] && modes=$((modes + 1))
[[ -n "$TASK_ID" ]] && modes=$((modes + 1))
if (( modes > 1 )); then
  die "pass exactly one of --all, --task N, or one workload"
fi
if (( modes == 0 )); then
  usage >&2
  exit 2
fi
TASK_WORKLOADS=()
if [[ -n "$TASK_ID" ]]; then
  tw=$(task_workloads "$TASK_ID") || exit 1
  read -r -a TASK_WORKLOADS <<<"$tw"
  for w in "${TASK_WORKLOADS[@]}"; do
    valid_workload "$w" || die "tasks.conf task ${TASK_ID} names unknown workload: ${w}"
  done
  ((${#TASK_WORKLOADS[@]})) || die "task ${TASK_ID} lists no workloads"
fi

require_linux
load_config "$CONFIG"
if [[ -n "$SCHEDSTATS_FLAG" ]]; then
  SCHEDSTATS_ENABLE=1
fi
mkdir -p "$RUNS_DIR"

TRACE_ARMED=0
TRACE_LIVE=0
TRACEFS=""
PREV_TRACING_ON=""
PREV_SWITCH=""
PREV_WAKEUP=""
BPF_PID=""
RUN_DIR=""
PERF_EVENTS=""
PERF_DROPPED=""
PERF_NOTE=""
PROBE_DIR=""
SCHEDSTATS_SYSCTL=/proc/sys/kernel/sched_schedstats
SCHEDSTATS_PREV=""
SCHEDSTATS_TOGGLED=0
SCHEDSTATS_NOTE=""

note() {
  [[ -n "$RUN_DIR" ]] || return 0
  printf '%s\n' "$*" >> "$RUN_DIR/collector_notes.txt"
}

stop_bpf() {
  if [[ -z "${BPF_PID}" ]]; then
    return 0
  fi
  if kill -0 "$BPF_PID" 2>/dev/null; then
    kill -INT "$BPF_PID" 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if ! kill -0 "$BPF_PID" 2>/dev/null; then
        break
      fi
      sleep 0.2
    done
    if kill -0 "$BPF_PID" 2>/dev/null; then
      kill -TERM "$BPF_PID" 2>/dev/null || true
    fi
  fi
  wait "$BPF_PID" 2>/dev/null || true
  BPF_PID=""
}

disarm_trace() {
  if [[ "${TRACE_ARMED}" != 1 ]]; then
    return 0
  fi
  local tf=$TRACEFS
  local max=${TRACE_COPY_MAX_BYTES:-33554432}
  if [[ -n "$tf" && -w "$tf/tracing_on" ]]; then
    echo 0 > "$tf/tracing_on" || true
  fi
  if [[ "$TRACE_LIVE" == 1 && -n "$RUN_DIR" && -n "$tf" && -r "$tf/trace" ]]; then
    mkdir -p "$RUN_DIR"
    local blocks=$((max / 4096))
    if (( blocks <= 0 )); then
      blocks=1
    fi
    if dd if="$tf/trace" of="$RUN_DIR/trace.txt" bs=4096 count="$blocks" status=none 2>/dev/null; then
      local bytes
      bytes=$(wc -c < "$RUN_DIR/trace.txt" | tr -d ' ')
      printf '%s\n' "copied sched:sched_switch and sched:sched_wakeup (${bytes} bytes, cap ${max}); tracing restored" > "$RUN_DIR/trace_status.txt"
    else
      printf '%s\n' "failed to copy trace; tracing restore still attempted" > "$RUN_DIR/trace_status.txt"
    fi
  fi
  if [[ -n "$tf" && -n "$PREV_SWITCH" && -w "$tf/events/sched/sched_switch/enable" ]]; then
    echo "$PREV_SWITCH" > "$tf/events/sched/sched_switch/enable" || true
  fi
  if [[ -n "$tf" && -n "$PREV_WAKEUP" && -w "$tf/events/sched/sched_wakeup/enable" ]]; then
    echo "$PREV_WAKEUP" > "$tf/events/sched/sched_wakeup/enable" || true
  fi
  if [[ -n "$tf" && -n "$PREV_TRACING_ON" && -w "$tf/tracing_on" ]]; then
    echo "$PREV_TRACING_ON" > "$tf/tracing_on" || true
  fi
  if [[ "$TRACE_LIVE" == 1 && -n "$tf" && -w "$tf/trace" ]]; then
    : > "$tf/trace" || true
  fi
  TRACE_LIVE=0
  TRACE_ARMED=0
}

schedstats_value() {
  if [[ -r "$SCHEDSTATS_SYSCTL" ]]; then
    tr -d '[:space:]' < "$SCHEDSTATS_SYSCTL"
  else
    echo unknown
  fi
}

write_schedstats() {
  local v=$1
  if [[ -w "$SCHEDSTATS_SYSCTL" ]]; then
    echo "$v" > "$SCHEDSTATS_SYSCTL" 2>/dev/null && return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    # -n: never prompt. If sudo needs a password this just fails.
    sudo -n sysctl -q "kernel.sched_schedstats=${v}" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Opt-in only (SCHEDSTATS_ENABLE=1 or --schedstats). Restored by the EXIT trap.
arm_schedstats() {
  SCHEDSTATS_PREV=$(schedstats_value)
  if [[ "$SCHEDSTATS_ENABLE" != 1 ]]; then
    SCHEDSTATS_NOTE="sched_schedstats=${SCHEDSTATS_PREV} (not changed; pass --schedstats to enable for the run)"
    return 0
  fi
  if [[ "$SCHEDSTATS_PREV" == 1 ]]; then
    SCHEDSTATS_NOTE="sched_schedstats already 1; left as is"
    return 0
  fi
  if [[ "$SCHEDSTATS_PREV" == unknown ]]; then
    SCHEDSTATS_NOTE="sched_schedstats sysctl not present; ttwu/sched_count stay n/a"
    return 0
  fi
  if write_schedstats 1; then
    SCHEDSTATS_TOGGLED=1
    SCHEDSTATS_NOTE="sched_schedstats set 1 for this collect (was ${SCHEDSTATS_PREV}); restored on exit"
  else
    SCHEDSTATS_NOTE="could not enable sched_schedstats (no root, no passwordless sudo); ttwu/sched_count stay n/a"
  fi
}

disarm_schedstats() {
  if [[ "$SCHEDSTATS_TOGGLED" == 1 ]]; then
    write_schedstats "$SCHEDSTATS_PREV" || echo "warning: could not restore kernel.sched_schedstats=${SCHEDSTATS_PREV}" >&2
    SCHEDSTATS_TOGGLED=0
  fi
}

cleanup_collectors() {
  stop_bpf || true
  disarm_trace || true
  disarm_schedstats || true
  if [[ -n "${PROBE_DIR}" && -d "${PROBE_DIR}" ]]; then
    rm -rf "${PROBE_DIR}" || true
  fi
}
trap cleanup_collectors EXIT

arm_trace() {
  local tf=/sys/kernel/debug/tracing
  local reason=""
  TRACE_ARMED=0
  TRACE_LIVE=0
  if [[ ! -d "$tf" ]]; then
    reason="tracefs not mounted at ${tf}"
  elif [[ ! -w "$tf/tracing_on" ]]; then
    reason="tracefs not writable; skipped (no root or trace permission required)"
  elif [[ ! -w "$tf/events/sched/sched_switch/enable" || ! -w "$tf/events/sched/sched_wakeup/enable" ]]; then
    reason="sched:sched_switch or sched:sched_wakeup not writable; skipped"
  else
    local ton sw wu tracer
    ton=$(tr -d '[:space:]' < "$tf/tracing_on")
    sw=$(tr -d '[:space:]' < "$tf/events/sched/sched_switch/enable")
    wu=$(tr -d '[:space:]' < "$tf/events/sched/sched_wakeup/enable")
    tracer=$(tr -d '[:space:]' < "$tf/current_tracer" 2>/dev/null || echo unknown)
    if [[ "$ton" != 0 || "$sw" != 0 || "$wu" != 0 ]]; then
      reason="tracing already active (tracing_on=${ton} sched_switch=${sw} sched_wakeup=${wu}); not changing it"
    elif [[ "$tracer" != "nop" ]]; then
      reason="current_tracer is ${tracer}, not nop; not switching tracer and not mixing events into it"
    else
      PREV_TRACING_ON=$ton
      PREV_SWITCH=$sw
      PREV_WAKEUP=$wu
      TRACEFS=$tf
      TRACE_ARMED=1
      if ! echo 0 > "$tf/tracing_on"; then
        disarm_trace
        printf '%s\n' "could not set tracing_on=0; previous state restored" > "$RUN_DIR/trace_status.txt"
        return 0
      fi
      if ! : > "$tf/trace"; then
        echo 0 > "$tf/trace" || true
      fi
      if ! echo 1 > "$tf/events/sched/sched_switch/enable"; then
        disarm_trace
        printf '%s\n' "failed to enable sched:sched_switch; previous state restored" > "$RUN_DIR/trace_status.txt"
        return 0
      fi
      if ! echo 1 > "$tf/events/sched/sched_wakeup/enable"; then
        disarm_trace
        printf '%s\n' "failed to enable sched:sched_wakeup; previous state restored" > "$RUN_DIR/trace_status.txt"
        return 0
      fi
      if ! echo 1 > "$tf/tracing_on"; then
        disarm_trace
        printf '%s\n' "failed to set tracing_on=1; previous state restored" > "$RUN_DIR/trace_status.txt"
        return 0
      fi
      TRACE_LIVE=1
      printf '%s\n' "enabled sched:sched_switch and sched:sched_wakeup for this run" > "$RUN_DIR/trace_status.txt"
      return 0
    fi
  fi
  printf '%s\n' "$reason" > "$RUN_DIR/trace_status.txt"
}

start_bpf() {
  local bt="$HARNESS_DIR/bpf/runq_latency.bt"
  if ! command -v bpftrace >/dev/null 2>&1; then
    printf '%s\n' "bpftrace not installed" > "$RUN_DIR/bpf_status.txt"
    return 0
  fi
  if [[ ! -f "$bt" ]]; then
    printf '%s\n' "bpftrace is installed but bpf/runq_latency.bt is missing" > "$RUN_DIR/bpf_status.txt"
    return 0
  fi
  set +e
  bpftrace "$bt" </dev/null >"$RUN_DIR/bpftrace.out" 2>"$RUN_DIR/bpftrace.err" &
  BPF_PID=$!
  set -e
  sleep 0.3
  if ! kill -0 "$BPF_PID" 2>/dev/null; then
    wait "$BPF_PID" 2>/dev/null || true
    BPF_PID=""
    printf '%s\n' "bpftrace failed to start; see bpftrace.err" > "$RUN_DIR/bpf_status.txt"
    return 0
  fi
  printf '%s\n' "bpftrace started" > "$RUN_DIR/bpf_status.txt"
}

finish_bpf() {
  local was=0
  if [[ -n "$BPF_PID" ]]; then
    was=1
  fi
  stop_bpf
  if (( was == 1 )); then
    printf '%s\n' "bpftrace stopped after the workload" > "$RUN_DIR/bpf_status.txt"
  fi
}

probe_perf() {
  PERF_EVENTS=""
  PERF_DROPPED=""
  PERF_NOTE=""
  if ! command -v perf >/dev/null 2>&1; then
    PERF_NOTE="perf not installed"
    return 0
  fi
  local list=""
  list=$(perf list --no-desc 2>/dev/null || perf list 2>/dev/null || true)
  # Canonical names match delta.awk. perf list on some CPUs only prints lowercase
  # aliases (llc-load-misses, …); list matching is case-insensitive so those are
  # not dropped before perf stat. Optional mem_load_retired.l3_* /
  # longest_lat_cache.miss fill gaps when LLC-load-misses is absent.
  local -a candidates=(cycles instructions cache-references cache-misses LLC-load-misses dTLB-load-misses iTLB-load-misses context-switches cpu-migrations mem_load_retired.l3_miss mem_load_retired.l3_hit longest_lat_cache.miss)
  local -a accepted=()
  local -a dropped=()
  local ev out rc val list_ok=0
  PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kernel-measure-perf.XXXXXX")
  if [[ -n "$list" ]]; then
    list_ok=1
  fi
  for ev in "${candidates[@]}"; do
    if (( list_ok == 1 )) && ! grep -iE -q "(^|[[:space:]])${ev}([[:space:]]|$)" <<<"$list"; then
      dropped+=("$ev")
      continue
    fi
    set +e
    perf stat -e "$ev" -x, -o "$PROBE_DIR/stat.csv" -- true >/dev/null 2>"$PROBE_DIR/stat.err"
    rc=$?
    set -e
    val=$(awk -F, -v ev="$ev" '
      index($0, ev) { line = $1 }
      END {
        gsub(/[[:space:]]/, "", line)
        print line
      }
    ' "$PROBE_DIR/stat.csv" 2>/dev/null || true)
    if [[ "$rc" -eq 0 && "$val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      accepted+=("$ev")
    else
      dropped+=("$ev")
    fi
  done
  if ((${#accepted[@]})); then
    local IFS=,
    PERF_EVENTS="${accepted[*]}"
  fi
  if ((${#dropped[@]})); then
    local IFS=,
    PERF_DROPPED="${dropped[*]}"
  fi
  if (( list_ok == 0 )); then
    PERF_NOTE="perf list produced no output; events kept only when perf stat accepted them"
  else
    PERF_NOTE="events kept if perf list matches (case-insensitive) and perf stat accepts them"
  fi
  if [[ -z "$PERF_EVENTS" ]]; then
    PERF_NOTE="${PERF_NOTE}; no requested events accepted"
  fi
}

collect_meta() {
  local d=$1/meta
  mkdir -p "$d"
  uname -a > "$d/uname.txt"
  {
    echo "uname_r=$(uname -r)"
    echo "uname_v=$(uname -v)"
    if [[ -r /proc/version ]]; then
      cat /proc/version
    fi
  } > "$d/kernel_version.txt"
  date '+%Y-%m-%dT%H:%M:%S%z %Z' > "$d/date.txt"
  {
    echo "nproc=$(nproc 2>/dev/null || echo unknown)"
    if [[ -r /proc/cpuinfo ]]; then
      grep -m1 -E 'model name|Model name|Hardware|CPU implementer|CPU part|cpu model' /proc/cpuinfo || true
    else
      echo "cpuinfo not readable"
    fi
  } > "$d/cpu.txt"
  if [[ -r /proc/meminfo ]]; then
    grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|AnonPages|Committed_AS):' /proc/meminfo > "$d/meminfo_summary.txt" || true
  else
    echo "meminfo not readable" > "$d/meminfo_summary.txt"
  fi
  {
    local found=0 gov first="" mixed=0 n=0 g
    shopt -s nullglob
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      [[ -f "$g" ]] || continue
      found=1
      gov=$(tr -d '[:space:]' < "$g")
      n=$((n + 1))
      if [[ -z "$first" ]]; then
        first=$gov
      elif [[ "$gov" != "$first" ]]; then
        mixed=1
      fi
    done
    shopt -u nullglob
    if (( found == 0 )); then
      echo "scaling governor not available (no cpufreq sysfs)"
    elif (( mixed == 0 )); then
      echo "scaling_governor=${first}"
      echo "cpus=${n}"
    else
      echo "scaling_governor=mixed"
      for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$g" ]] || continue
        echo "$(basename "$(dirname "$g")"): $(tr -d '[:space:]' < "$g")"
      done
    fi
  } > "$d/scaling_governor.txt"
  if [[ -r /proc/sys/kernel/perf_event_paranoid ]]; then
    echo "perf_event_paranoid=$(tr -d '[:space:]' < /proc/sys/kernel/perf_event_paranoid)" > "$d/perf_event_paranoid.txt"
  fi
  # Topology / locality accounting (Task 10): always record NUMA + LLC shape.
  {
    local nodes llcs
    nodes=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l | tr -d ' ')
    llcs=$(cat /sys/devices/system/cpu/cpu[0-9]*/cache/index3/shared_cpu_list 2>/dev/null | sort -u | wc -l | tr -d ' ')
    echo "numa_nodes=${nodes:-unknown}"
    echo "llc_domains=${llcs:-unknown}"
    if [[ -r /sys/devices/system/cpu/cpu0/cache/index3/size ]]; then
      echo "llc_size=$(tr -d '[:space:]' < /sys/devices/system/cpu/cpu0/cache/index3/size)"
    fi
    if [[ -r /sys/devices/system/cpu/cpu0/cache/index3/shared_cpu_list ]]; then
      echo "llc0_shared_cpus=$(tr -d '[:space:]' < /sys/devices/system/cpu/cpu0/cache/index3/shared_cpu_list)"
    fi
    if [[ -r /proc/sys/kernel/numa_balancing ]]; then
      echo "numa_balancing=$(tr -d '[:space:]' < /proc/sys/kernel/numa_balancing)"
    else
      echo "numa_balancing=n/a"
    fi
    if [[ "${nodes:-1}" -le 1 ]]; then
      echo "note=single_NUMA_node; remote NUMA access rates are not meaningful here"
    fi
    if [[ "${llcs:-1}" -le 1 ]]; then
      echo "note=single_LLC_domain; cross-LLC migration wins cannot be proven here"
    fi
    if command -v numactl >/dev/null 2>&1; then
      echo "numactl_H:"
      numactl --hardware 2>/dev/null | sed 's/^/  /' | head -n 12
    fi
  } > "$d/topology.txt"
}

snapshot() {
  local which=$1
  if [[ -r /proc/vmstat ]]; then
    cat /proc/vmstat > "$RUN_DIR/vmstat.${which}"
  else
    : > "$RUN_DIR/vmstat.${which}"
    note "vmstat: /proc/vmstat not readable"
  fi
  if [[ -r /proc/schedstat ]]; then
    cat /proc/schedstat > "$RUN_DIR/schedstat.${which}"
  else
    : > "$RUN_DIR/schedstat.${which}"
    note "schedstat: /proc/schedstat not readable (CONFIG_SCHEDSTATS may be off)"
  fi
  mkdir -p "$RUN_DIR/psi"
  for res in memory cpu io; do
    if [[ -r "/proc/pressure/${res}" ]]; then
      cat "/proc/pressure/${res}" > "$RUN_DIR/psi/${res}.${which}"
    else
      echo "n/a" > "$RUN_DIR/psi/${res}.${which}"
    fi
  done
}

metric_from() {
  local file=$1 key=$2 line
  if [[ ! -f "$file" ]]; then
    echo n/a
    return 0
  fi
  line=$(grep -E "^${key}=" "$file" | tail -n 1 || true)
  if [[ -z "$line" ]]; then
    echo n/a
  else
    printf '%s\n' "${line#*=}"
  fi
}

write_metrics() {
  local status=$1 wall=$2 k
  {
    echo "status=${status}"
    if [[ "$status" == "skip" ]]; then
      echo "wall_time_sec=n/a"
    else
      echo "wall_time_sec=${wall}"
    fi
    for k in cycles instructions cache_references cache_misses llc_load_misses dtlb_load_misses itlb_load_misses tlb_misses; do
      if [[ "$status" == "skip" ]]; then
        echo "${k}=n/a"
      else
        echo "${k}=$(metric_from "$RUN_DIR/perf.metrics" "$k")"
      fi
    done
    for k in pgscan_delta pgsteal_delta compact_stall_delta compact_success_delta thp_fault_alloc_delta thp_fault_fallback_delta numa_hint_faults_delta; do
      if [[ "$status" == "skip" ]]; then
        echo "${k}=n/a"
      else
        echo "${k}=$(metric_from "$RUN_DIR/vmstat.metrics" "$k")"
      fi
    done
    for k in context_switches cpu_migrations ipc cache_misses_per_kinstr cache_miss_rate llc_misses_per_kinstr l3_misses l3_hits; do
      if [[ "$status" == "skip" ]]; then
        echo "${k}=n/a"
      else
        echo "${k}=$(metric_from "$RUN_DIR/perf.metrics" "$k")"
      fi
    done
    for k in sched_count_delta sched_goidle_delta run_delay_ns_delta pcount_delta rq_latency_ns ttwu_count_delta ttwu_local_delta ttwu_remote_delta ttwu_remote_frac; do
      if [[ "$status" == "skip" ]]; then
        echo "${k}=n/a"
      else
        echo "${k}=$(metric_from "$RUN_DIR/sched.metrics" "$k")"
      fi
    done
    echo "schedstats=${RUN_SCHEDSTATS:-unknown}"
    echo "perf_events=${PERF_EVENTS:-none}"
    echo "perf_dropped=${PERF_DROPPED:-none}"
    # Workload-reported metrics (wl_*), e.g. wake-to-run latency percentiles.
    # Only key=value lines with a number, n/a, or the engine/args strings.
    if [[ "$status" != "skip" && -f "$RUN_DIR/workload.metrics" ]]; then
      grep -E '^wl_[a-z0-9_]+=(-?[0-9]+([.][0-9]+)?|n/a)$|^wl_(engine|args)=' "$RUN_DIR/workload.metrics" || true
    fi
  } > "$RUN_DIR/metrics.env"
}

write_summary() {
  local status=$1 wall=$2 rc=$3
  local cmd="unknown" trace="trace status missing" bpf="bpf status missing" wname
  wname=$(cat "$RUN_DIR/workload_name.txt" 2>/dev/null || basename "$RUN_DIR")
  if [[ -f "$RUN_DIR/command.txt" ]]; then
    cmd=$(head -n 1 "$RUN_DIR/command.txt")
  fi
  if [[ -f "$RUN_DIR/trace_status.txt" ]]; then
    trace=$(head -n 1 "$RUN_DIR/trace_status.txt")
  fi
  if [[ -f "$RUN_DIR/bpf_status.txt" ]]; then
    bpf=$(head -n 1 "$RUN_DIR/bpf_status.txt")
  fi
  {
    echo "workload: ${wname}"
    echo "status: ${status}"
    echo "exit_code: ${rc}"
    echo "wall_time_sec: ${wall}"
    echo "command: ${cmd}"
    if [[ "$status" == "skip" && -f "$RUN_DIR/skip_reason.txt" ]]; then
      echo "skip_reason: $(head -n 1 "$RUN_DIR/skip_reason.txt")"
    fi
    echo "perf: ${PERF_NOTE:-n/a}"
    echo "perf_events: ${PERF_EVENTS:-none}"
    echo "perf_dropped: ${PERF_DROPPED:-none}"
    echo "trace: ${trace}"
    echo "sched_method: /proc/schedstat deltas (not perf sched)"
    echo "sched_count_delta: $(metric_from "$RUN_DIR/metrics.env" sched_count_delta)"
    echo "sched_goidle_delta: $(metric_from "$RUN_DIR/metrics.env" sched_goidle_delta)"
    echo "run_delay_ns_delta: $(metric_from "$RUN_DIR/metrics.env" run_delay_ns_delta)"
    echo "pcount_delta: $(metric_from "$RUN_DIR/metrics.env" pcount_delta)"
    echo "rq_latency_ns: $(metric_from "$RUN_DIR/metrics.env" rq_latency_ns)"
    echo "schedstats: ${SCHEDSTATS_NOTE:-n/a}"
    echo "ttwu_count_delta: $(metric_from "$RUN_DIR/metrics.env" ttwu_count_delta)"
    echo "ttwu_remote_delta: $(metric_from "$RUN_DIR/metrics.env" ttwu_remote_delta)"
    echo "context_switches: $(metric_from "$RUN_DIR/metrics.env" context_switches)"
    echo "cpu_migrations: $(metric_from "$RUN_DIR/metrics.env" cpu_migrations)"
    echo "ipc: $(metric_from "$RUN_DIR/metrics.env" ipc)"
    echo "cache_misses_per_kinstr: $(metric_from "$RUN_DIR/metrics.env" cache_misses_per_kinstr)"
    echo "cache_miss_rate: $(metric_from "$RUN_DIR/metrics.env" cache_miss_rate)"
    echo "llc_misses_per_kinstr: $(metric_from "$RUN_DIR/metrics.env" llc_misses_per_kinstr)"
    echo "l3_misses: $(metric_from "$RUN_DIR/metrics.env" l3_misses)"
    echo "l3_hits: $(metric_from "$RUN_DIR/metrics.env" l3_hits)"
    echo "ttwu_remote_frac: $(metric_from "$RUN_DIR/metrics.env" ttwu_remote_frac)"
    echo "pgsteal_delta: $(metric_from "$RUN_DIR/metrics.env" pgsteal_delta)"
    echo "pgscan_delta: $(metric_from "$RUN_DIR/metrics.env" pgscan_delta)"
    echo "compact_stall_delta: $(metric_from "$RUN_DIR/metrics.env" compact_stall_delta)"
    echo "compact_success_delta: $(metric_from "$RUN_DIR/metrics.env" compact_success_delta)"
    echo "thp_fault_alloc_delta: $(metric_from "$RUN_DIR/metrics.env" thp_fault_alloc_delta)"
    echo "thp_fault_fallback_delta: $(metric_from "$RUN_DIR/metrics.env" thp_fault_fallback_delta)"
    echo "numa_hint_faults_delta: $(metric_from "$RUN_DIR/metrics.env" numa_hint_faults_delta)"
    echo "cycles: $(metric_from "$RUN_DIR/metrics.env" cycles)"
    echo "instructions: $(metric_from "$RUN_DIR/metrics.env" instructions)"
    echo "cache_misses: $(metric_from "$RUN_DIR/metrics.env" cache_misses)"
    echo "llc_load_misses: $(metric_from "$RUN_DIR/metrics.env" llc_load_misses)"
    echo "tlb_misses: $(metric_from "$RUN_DIR/metrics.env" tlb_misses)"
    echo "bpf: ${bpf}"
    if [[ -f "$RUN_DIR/workload.metrics" ]]; then
      echo "workload_metrics:"
      sed 's/^/  /' "$RUN_DIR/workload.metrics"
    fi
    if [[ -f "$RUN_DIR/topology_note.txt" ]]; then
      echo "topology:"
      sed 's/^/  /' "$RUN_DIR/topology_note.txt"
    fi
    if [[ -f "$RUN_DIR/collector_notes.txt" ]]; then
      echo "notes:"
      cat "$RUN_DIR/collector_notes.txt"
    fi
  } > "$RUN_DIR/summary.txt"
}

run_one() {
  local name=$1
  local dir=$2
  local dur script limit rc=0 wall start end status
  RUN_DIR=$dir
  mkdir -p "$RUN_DIR"
  dur=$(duration_for "$name")
  if [[ ! "$dur" =~ ^[0-9]+$ ]] || (( dur <= 0 )); then
    die "duration for ${name} must be a positive integer (got ${dur})"
  fi
  warn_duration "$name" "$dur"
  export DURATION="$dur"
  export RUN_DIR HARNESS_DIR
  echo "$name" > "$RUN_DIR/workload_name.txt"
  cp -a "$CONFIG" "$RUN_DIR/workloads.conf.copy"
  collect_meta "$RUN_DIR"
  script="$HARNESS_DIR/workloads/${name}.sh"
  # Optional prepare step (e.g. compile a workload engine) outside perf stat.
  if head -n 3 "$script" | grep -q '^# kernel-measure: prepare'; then
    if ! bash "$script" --prepare > "$RUN_DIR/prepare.log" 2>&1; then
      note "prepare step failed; see prepare.log"
    fi
  fi
  {
    printf '%s\n' "$PERF_NOTE"
    printf '%s\n' "used=${PERF_EVENTS:-none}"
    printf '%s\n' "dropped=${PERF_DROPPED:-none}"
  } > "$RUN_DIR/perf_probe.txt"
  local ss_before ss_after
  ss_before=$(schedstats_value)
  snapshot before
  arm_trace
  start_bpf
  start=$(date +%s%N 2>/dev/null || echo 0)
  local -a cmd
  if [[ -n "$PERF_EVENTS" ]]; then
    cmd=(perf stat -x, -e "$PERF_EVENTS" -o "$RUN_DIR/perf_stat.csv" -- bash "$script")
  else
    cmd=(bash "$script")
    note "perf stat not used (${PERF_NOTE})"
  fi
  limit=$((dur + OUTER_TIMEOUT_GRACE))
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$limit" "${cmd[@]}" >"$RUN_DIR/workload.log" 2>&1
    rc=$?
  else
    note "timeout(1) not installed; no outer watchdog"
    "${cmd[@]}" >"$RUN_DIR/workload.log" 2>&1
    rc=$?
  fi
  set -e
  end=$(date +%s%N 2>/dev/null || echo 0)
  printf '%s\n' "$rc" > "$RUN_DIR/exit_code.txt"
  finish_bpf
  disarm_trace
  snapshot after
  ss_after=$(schedstats_value)
  if [[ "$ss_before" == 1 && "$ss_after" == 1 ]]; then
    RUN_SCHEDSTATS=on
  elif [[ "$ss_before" == 0 && "$ss_after" == 0 ]]; then
    RUN_SCHEDSTATS=off
  elif [[ "$ss_before" == unknown && "$ss_after" == unknown ]]; then
    RUN_SCHEDSTATS=unavailable
  else
    RUN_SCHEDSTATS="mixed(${ss_before}->${ss_after})"
  fi
  printf '%s\n' "$SCHEDSTATS_NOTE" "run_schedstats=${RUN_SCHEDSTATS}" > "$RUN_DIR/schedstats_status.txt"
  if [[ -s "$RUN_DIR/perf_stat.csv" ]]; then
    awk -f "$HARNESS_DIR/lib/delta.awk" -v mode=perf -v metrics="$RUN_DIR/perf.metrics" \
      "$RUN_DIR/perf_stat.csv" > "$RUN_DIR/perf_stat.txt" || note "perf csv parse failed"
  else
    note "no perf_stat.csv (perf absent, no accepted events, or perf produced no output)"
  fi
  awk -f "$HARNESS_DIR/lib/delta.awk" -v mode=vmstat -v metrics="$RUN_DIR/vmstat.metrics" \
    "$RUN_DIR/vmstat.before" "$RUN_DIR/vmstat.after" > "$RUN_DIR/vmstat.delta" || note "vmstat delta failed"
  awk -f "$HARNESS_DIR/lib/delta.awk" -v mode=schedstat -v metrics="$RUN_DIR/sched.metrics" -v schedstats="$RUN_SCHEDSTATS" \
    "$RUN_DIR/schedstat.before" "$RUN_DIR/schedstat.after" > "$RUN_DIR/schedstat.delta" || note "schedstat delta failed"
  printf '%s\n' "method: /proc/schedstat CPU-line deltas (sched_count, sched_goidle, run_delay_ns, pcount). perf sched was not used because it needs extra privileges and would add its own load. Layout matches Linux 7.2.9 kernel/sched/stats.c SCHEDSTAT_VERSION 17: cpuN yld_count legacy0 sched_count sched_goidle ttwu_count ttwu_local rq_cpu_time run_delay_ns pcount. rq_latency_ns = run_delay_ns_delta / pcount_delta. ttwu_remote_delta = ttwu_count_delta - ttwu_local_delta (wakeups placed on a CPU other than the waker). sched_count, sched_goidle, and ttwu_* are only incremented while kernel.sched_schedstats=1; when it was not 1 for the whole run they are n/a, not 0. run_delay_ns and pcount come from sched_info and are always counted." > "$RUN_DIR/sched_method.txt"
  if [[ "$start" != 0 && "$end" != 0 ]]; then
    wall=$(awk -f "$HARNESS_DIR/lib/delta.awk" -v mode=elapsed -v start="$start" -v end="$end")
  else
    wall="n/a"
  fi
  # perf stat usually forwards the workload exit code. Also honor skip_reason.txt
  # so a skip is not scored if the wrapper reports 0.
  if [[ "$rc" -eq 2 || -f "$RUN_DIR/skip_reason.txt" ]]; then
    status=skip
    wall="n/a"
  elif [[ "$rc" -eq 0 ]]; then
    status=ok
  else
    status=fail
    if [[ "$rc" -eq 124 || "$rc" -eq 137 || "$rc" -eq 143 ]]; then
      note "workload exceeded the outer timeout or was killed (exit ${rc})"
    fi
  fi
  printf '%s\n' "$wall" > "$RUN_DIR/wall_time_sec.txt"
  write_metrics "$status" "$wall"
  write_summary "$status" "$wall" "$rc"
  echo "collected ${name}: status=${status} dir=${RUN_DIR}" >&2
  if [[ "$status" == "fail" ]]; then
    return 1
  fi
  return 0
}

probe_perf
arm_schedstats

run_set() {
  # run_set SUFFIX WORKLOAD...
  local suffix=$1
  shift
  local -a names=("$@")
  stamp=$(date +%Y%m%dT%H%M%S%z)
  setdir="$RUNS_DIR/${stamp}-${suffix}"
  mkdir -p "$setdir"
  {
    echo "stamp=${stamp}"
    echo "workloads=${names[*]}"
    echo "config=${CONFIG}"
    if [[ -n "$TASK_ID" ]]; then
      echo "task=${TASK_ID}"
      echo "task_name=$(task_name "$TASK_ID")"
      echo "task_pass_fail=$(task_passfail "$TASK_ID")"
    fi
    echo "kernel=$(uname -r)"
    echo "schedstats_enable=${SCHEDSTATS_ENABLE}"
  } > "$setdir/set.info"
  cp -a "$CONFIG" "$setdir/workloads.conf.copy"
  if [[ -f "$TASKS_CONF" ]]; then
    cp -a "$TASKS_CONF" "$setdir/tasks.conf.copy"
  fi
  failures=0
  for name in "${names[@]}"; do
    if ! run_one "$name" "$setdir/$name"; then
      failures=$((failures + 1))
    fi
    # Also expose runs/<stamp>-<workload> as the per-workload path.
    ln -sfn "${stamp}-${suffix}/${name}" "$RUNS_DIR/${stamp}-${name}"
  done
  {
    echo "stamp=${stamp}"
    echo "failures=${failures}"
    printf '%-16s %-8s %s\n' "workload" "status" "summary"
    for name in "${names[@]}"; do
      st=$(grep -E '^status=' "$setdir/$name/metrics.env" | tail -n 1 | cut -d= -f2- || true)
      printf '%-16s %-8s %s\n' "$name" "${st:-missing}" "$setdir/$name/summary.txt"
    done
  } > "$setdir/summary.txt"
  if (( failures > 0 )); then
    echo "error: ${failures} workload(s) failed. Set directory kept at ${setdir}. BASELINE was not written." >&2
    return 1
  fi
  return 0
}

if [[ "$ALL" -eq 1 ]]; then
  run_set set "${WORKLOAD_IDS[@]}" || exit 1
  printf '%s\n' "$setdir" > "$RUNS_DIR/LAST_SET"
  echo "RUN_SET=${setdir}"
  exit 0
fi

if [[ -n "$TASK_ID" ]]; then
  run_set "task${TASK_ID}" "${TASK_WORKLOADS[@]}" || exit 1
  printf '%s\n' "$setdir" > "$RUNS_DIR/LAST_TASK${TASK_ID}"
  echo "RUN_SET=${setdir}"
  exit 0
fi

if ! valid_workload "$WORKLOAD"; then
  die "unknown workload: ${WORKLOAD} (expected: ${WORKLOAD_IDS[*]})"
fi
stamp=$(date +%Y%m%dT%H%M%S%z)
one="$RUNS_DIR/${stamp}-${WORKLOAD}"
if ! run_one "$WORKLOAD" "$one"; then
  echo "RUN_DIR=${one}"
  exit 1
fi
printf '%s\n' "$one" > "$RUNS_DIR/LAST_RUN"
echo "RUN_DIR=${one}"
exit 0
