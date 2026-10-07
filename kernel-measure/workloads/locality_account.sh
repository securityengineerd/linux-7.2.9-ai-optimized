#!/usr/bin/env bash
# kernel-measure: prepare
# Task 10 locality / cache-miss accounting survey helper.
#
# prepare: writes topology_note.txt + locality_caps.txt (which PMU events
#          perf list/stat accept). Does not invent LLC events the PMU lacks.
# run:     reuses build/migrate_storm (cross-CPU affinity storm) so cache
#          misses / LLC misses / ttwu remote frac land beside cycles in
#          metrics.env. Prefer --task 10 workloads for official sets.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
HARNESS_DIR=${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=lib/build_tool.sh
source "$HARNESS_DIR/lib/build_tool.sh"
DURATION=${DURATION:-18}
RUN_DIR=${RUN_DIR:-.}
MIGRATE_WORKERS=${MIGRATE_WORKERS:-0}
MIGRATE_BUF_KB=${MIGRATE_BUF_KB:-256}
MIGRATE_STORM_MS=${MIGRATE_STORM_MS:-10}
mkdir -p "$RUN_DIR"

write_caps() {
  local list="" ev
  {
    echo "# Task 10 locality capability survey"
    echo "uname_r=$(uname -r)"
    echo "nproc=$(nproc 2>/dev/null || echo unknown)"
    local nodes llcs
    nodes=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l | tr -d " ")
    llcs=$(cat /sys/devices/system/cpu/cpu[0-9]*/cache/index3/shared_cpu_list 2>/dev/null | sort -u | wc -l | tr -d " ")
    echo "numa_nodes=${nodes:-unknown}"
    echo "llc_domains=${llcs:-unknown}"
    if [[ "${nodes:-1}" -le 1 ]]; then
      echo "remote_numa=n/a (single node)"
    else
      echo "remote_numa=measurable (multi-node)"
    fi
    if [[ "${llcs:-1}" -le 1 ]]; then
      echo "cross_llc=n/a (single LLC)"
    else
      echo "cross_llc=measurable (multi-LLC)"
    fi
    if ! command -v perf >/dev/null 2>&1; then
      echo "perf=missing"
      return 0
    fi
    list=$(perf list --no-desc 2>/dev/null || true)
    for ev in cycles instructions cache-references cache-misses LLC-load-misses llc-load-misses dTLB-load-misses dtlb-load-misses iTLB-load-misses itlb-load-misses mem_load_retired.l3_miss mem_load_retired.l3_hit longest_lat_cache.miss context-switches cpu-migrations; do
      if perf stat -e "$ev" -x, -o /dev/null -- true >/dev/null 2>&1; then
        echo "perf_ok=$ev"
      else
        echo "perf_no=$ev"
      fi
    done
    if [[ -r /proc/schedstat ]]; then
      echo "schedstat=present"
    else
      echo "schedstat=missing"
    fi
    if [[ -r /proc/pressure/memory ]]; then
      echo "psi=present"
    else
      echo "psi=missing"
    fi
    if [[ -r /proc/sys/kernel/numa_balancing ]]; then
      echo "numa_balancing=$(tr -d "[:space:]" < /proc/sys/kernel/numa_balancing)"
    fi
  } > "$RUN_DIR/locality_caps.txt"
  {
    echo "numa_nodes=${nodes:-unknown}"
    echo "llc_domains=${llcs:-unknown}"
    if [[ "${nodes:-1}" -le 1 ]]; then
      echo "Task 10 NUMA remote-access rates are not meaningful on a single-node box."
    fi
    if [[ "${llcs:-1}" -le 1 ]]; then
      echo "Single L3: LLC-miss / cache-miss still recorded; cross-LLC placement wins cannot be proven."
    fi
  } > "$RUN_DIR/topology_note.txt"
}

if [[ "${1:-}" == "--prepare" ]]; then
  write_caps
  if build_tool migrate_storm >/dev/null; then
    record_build migrate_storm "$RUN_DIR"
    echo "prepared build/migrate_storm + locality_caps.txt"
  else
    echo "prepared locality_caps.txt (migrate_storm build failed)"
  fi
  exit 0
fi

bin="$HARNESS_DIR/build/migrate_storm"
if [[ -x "$bin" ]]; then
  printf "build/migrate_storm -d %s -w %s -k %s -t %s (locality_account)\n" \
    "$DURATION" "$MIGRATE_WORKERS" "$MIGRATE_BUF_KB" "$MIGRATE_STORM_MS" > "$RUN_DIR/command.txt"
  exec "$bin" -d "$DURATION" -w "$MIGRATE_WORKERS" -k "$MIGRATE_BUF_KB" -t "$MIGRATE_STORM_MS" \
    -o "$RUN_DIR/workload.metrics"
fi
printf "%s\n" "migrate_storm missing; run with --prepare first" > "$RUN_DIR/skip_reason.txt"
echo "SKIP: migrate_storm missing" >&2
exit 2
