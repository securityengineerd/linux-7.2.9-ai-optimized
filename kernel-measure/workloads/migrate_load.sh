#!/usr/bin/env bash
# kernel-measure: prepare
# Task 2 migration / cache-placement storm.
#
# Engines (MIGRATE_ENGINE=auto tries them in this order):
#   c          build/migrate_storm from workloads/src/migrate_storm.c.
#              nproc*1.5 cache-hot pointer-chase workers; phases free / storm
#              (pin-unpin rotating affinity every MIGRATE_STORM_MS) / settle.
#              Reports loads/sec, CPU changes, se.nr_migrations per phase,
#              NUMA node count, and L3 domain count into workload.metrics.
#   stress-ng  stress-ng --affinity N --affinity-rand --cache N/2 --timeout
#              No per-phase metrics; perf (cpu-migrations, cache-misses) only.
#
# Single-socket note: with one NUMA node and one L3 domain, the NUMA half of
# Task 2 and cross-LLC preference cannot be proven here. This workload still
# measures migration rate and the L1/L2 refill cost of migrations.
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
MIGRATE_ENGINE=${MIGRATE_ENGINE:-auto}
MIGRATE_WORKERS=${MIGRATE_WORKERS:-0}
MIGRATE_BUF_KB=${MIGRATE_BUF_KB:-256}
MIGRATE_STORM_MS=${MIGRATE_STORM_MS:-10}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

topology_note() {
  local nodes llcs
  nodes=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l | tr -d ' ')
  llcs=$(cat /sys/devices/system/cpu/cpu[0-9]*/cache/index3/shared_cpu_list 2>/dev/null | sort -u | wc -l | tr -d ' ')
  {
    echo "numa_nodes=${nodes:-unknown}"
    echo "llc_domains=${llcs:-unknown}"
    if [[ "${nodes:-1}" -le 1 ]]; then
      echo "Task 2 NUMA part (get_pref_llc vs numa_preferred_nid) cannot be proven on a single-node box."
    fi
    if [[ "${llcs:-1}" -le 1 ]]; then
      echo "Single L3 domain: preferred-LLC placement has only one LLC to choose; measure migration rate and L1/L2 refill cost instead."
    fi
    if command -v numactl >/dev/null 2>&1; then
      numactl --hardware 2>/dev/null | head -n 4
    fi
  } > "$RUN_DIR/topology_note.txt"
}

if [[ "${1:-}" == "--prepare" ]]; then
  topology_note
  if [[ "$MIGRATE_ENGINE" == auto || "$MIGRATE_ENGINE" == c ]]; then
    if build_tool migrate_storm >/dev/null; then
      record_build migrate_storm "$RUN_DIR"
      echo "prepared build/migrate_storm"
    else
      echo "could not build migrate_storm (no C compiler or build failed)"
    fi
  fi
  exit 0
fi

bin="$HARNESS_DIR/build/migrate_storm"
if [[ "$MIGRATE_ENGINE" == auto || "$MIGRATE_ENGINE" == c ]] && [[ -x "$bin" ]]; then
  printf 'build/migrate_storm -d %s -w %s -k %s -t %s (nproc=%s)\n' "$DURATION" "$MIGRATE_WORKERS" \
    "$MIGRATE_BUF_KB" "$MIGRATE_STORM_MS" "$(nproc)" > "$RUN_DIR/command.txt"
  exec "$bin" -d "$DURATION" -w "$MIGRATE_WORKERS" -k "$MIGRATE_BUF_KB" -t "$MIGRATE_STORM_MS" \
    -o "$RUN_DIR/workload.metrics"
fi
if [[ "$MIGRATE_ENGINE" == c ]]; then
  skip "MIGRATE_ENGINE=c but build/migrate_storm is missing (no C compiler?)"
fi

if [[ "$MIGRATE_ENGINE" == auto || "$MIGRATE_ENGINE" == stress-ng ]] && command -v stress-ng >/dev/null 2>&1; then
  help=$(stress-ng --help 2>&1 || true)
  n=$(nproc)
  half=$(( n / 2 > 0 ? n / 2 : 1 ))
  cmd=(stress-ng --timeout "${DURATION}s")
  if grep -q -- '--affinity N' <<<"$help"; then
    cmd+=(--affinity "$n")
    if grep -q -- '--affinity-rand' <<<"$help"; then
      cmd+=(--affinity-rand)
    fi
  fi
  if grep -q -- '--cache N' <<<"$help"; then
    cmd+=(--cache "$half")
  fi
  if grep -q -- '--metrics-brief' <<<"$help"; then
    cmd+=(--metrics-brief)
  fi
  printf '%s ' "${cmd[@]}" > "$RUN_DIR/command.txt"
  printf '\n' >> "$RUN_DIR/command.txt"
  echo "wl_engine=stress-ng-affinity" > "$RUN_DIR/workload.metrics"
  "${cmd[@]}"
  exit 0
fi

skip "no migrate_load engine: need a C compiler (build/migrate_storm) or stress-ng"
