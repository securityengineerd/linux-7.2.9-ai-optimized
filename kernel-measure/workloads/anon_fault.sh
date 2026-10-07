#!/usr/bin/env bash
# kernel-measure: prepare
# Task 6: anonymous write-fault zeroing — 4k (MADV_NOHUGEPAGE) vs PMD/mTHP
# (MADV_HUGEPAGE) under the current transparent_hugepage sysfs policy.
#
# Engines (ANONFAULT_ENGINE=auto tries them in this order):
#   c    build/anon_fault from workloads/src/anon_fault.c
#        mmap SIZE MiB anon, write-touch every page twice (nohuge / hugeprefer).
#        Reports wl_*_fault_ns, wl_*_minflt, wl_hugeprefer_vs_nohuge_fault_ns_ratio.
#   python3 fallback: same two-path mmap touch (slower; regression only).
# Compare only runs with the same engine and arguments.
#
# Optional: ANONFAULT_ENABLE_MTHP=1 temporarily sets intermediate mTHP sizes
# (64k..1024k) to "always" for the duration of the run, then restores. Needs
# passwordless sudo. Default 0 = leave sysfs alone (stock: only 2M inherits).
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
HARNESS_DIR=${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=lib/build_tool.sh
source "$HARNESS_DIR/lib/build_tool.sh"
DURATION=${DURATION:-8}
RUN_DIR=${RUN_DIR:-.}
ANONFAULT_ENGINE=${ANONFAULT_ENGINE:-auto}
ANONFAULT_SIZE_MIB=${ANONFAULT_SIZE_MIB:-1024}
ANONFAULT_STRIDE=${ANONFAULT_STRIDE:-4096}
ANONFAULT_RETOUCH=${ANONFAULT_RETOUCH:-1}
ANONFAULT_ENABLE_MTHP=${ANONFAULT_ENABLE_MTHP:-0}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

THP_ROOT=/sys/kernel/mm/transparent_hugepage
MTHP_SIZES=(64kB 128kB 256kB 512kB 1024kB)
declare -a MTHP_RESTORE=()

restore_mthp() {
  local i pair size mode
  for pair in "${MTHP_RESTORE[@]:-}"; do
    size=${pair%%=*}
    mode=${pair#*=}
    if [[ -w "$THP_ROOT/hugepages-${size}/enabled" ]]; then
      echo "$mode" > "$THP_ROOT/hugepages-${size}/enabled" 2>/dev/null || \
        sudo -n sh -c "echo $mode > $THP_ROOT/hugepages-${size}/enabled" 2>/dev/null || true
    fi
  done
  MTHP_RESTORE=()
}

enable_mthp_mid() {
  local size cur
  MTHP_RESTORE=()
  for size in "${MTHP_SIZES[@]}"; do
    [[ -f "$THP_ROOT/hugepages-${size}/enabled" ]] || continue
    cur=$(cat "$THP_ROOT/hugepages-${size}/enabled" 2>/dev/null | tr -d '[]' | awk '{for(i=1;i<=NF;i++) if($i ~ /^always|inherit|madvise|never$/){print $i; exit}}')
    # Prefer the bracketed current mode.
    cur=$(awk '{
      if (match($0, /\[[^]]+\]/)) {
        s=substr($0, RSTART+1, RLENGTH-2); print s; exit
      }
    }' "$THP_ROOT/hugepages-${size}/enabled" 2>/dev/null || echo never)
    MTHP_RESTORE+=("${size}=${cur}")
    if [[ -w "$THP_ROOT/hugepages-${size}/enabled" ]]; then
      echo always > "$THP_ROOT/hugepages-${size}/enabled" || \
        sudo -n sh -c "echo always > $THP_ROOT/hugepages-${size}/enabled"
    else
      sudo -n sh -c "echo always > $THP_ROOT/hugepages-${size}/enabled"
    fi
  done
  {
    echo "mthp_mid_enabled=1"
    for pair in "${MTHP_RESTORE[@]}"; do
      echo "mthp_restore_${pair%%=*}=${pair#*=}"
    done
  } > "$RUN_DIR/mthp_policy.txt"
}

if [[ "${1:-}" == "--prepare" ]]; then
  if [[ "$ANONFAULT_ENGINE" == auto || "$ANONFAULT_ENGINE" == c ]]; then
    if build_tool anon_fault >/dev/null; then
      record_build anon_fault "$RUN_DIR"
      echo "prepared build/anon_fault"
    else
      echo "could not build anon_fault (no C compiler or build failed)"
    fi
  fi
  exit 0
fi

bin="$HARNESS_DIR/build/anon_fault"

if [[ "$ANONFAULT_ENABLE_MTHP" == "1" ]]; then
  trap restore_mthp EXIT
  enable_mthp_mid || skip "ANONFAULT_ENABLE_MTHP=1 but could not set mTHP mid sizes (need sudo)"
fi

# Snapshot vmstat THP counters around the workload for the run dir.
snap_vmstat() {
  local tag=$1
  {
    echo "tag=$tag"
    echo "time=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    grep -E '^(thp_|nr_anon|pgfault|pgmajfault)' /proc/vmstat || true
    for d in "$THP_ROOT"/hugepages-*/stats; do
      [[ -d "$d" ]] || continue
      sz=$(basename "$(dirname "$d")")
      for f in anon_fault_alloc anon_fault_fallback nr_anon; do
        [[ -f "$d/$f" ]] || continue
        echo "${sz}_${f}=$(cat "$d/$f")"
      done
    done
  } > "$RUN_DIR/vmstat_${tag}.txt"
}

if [[ "$ANONFAULT_ENGINE" == auto || "$ANONFAULT_ENGINE" == c ]] && [[ -x "$bin" ]]; then
  printf 'build/anon_fault -s %s -p %s -r %s\n' \
    "$ANONFAULT_SIZE_MIB" "$ANONFAULT_STRIDE" "$ANONFAULT_RETOUCH" \
    > "$RUN_DIR/command.txt"
  snap_vmstat before
  "$bin" -s "$ANONFAULT_SIZE_MIB" -p "$ANONFAULT_STRIDE" -r "$ANONFAULT_RETOUCH" \
    -o "$RUN_DIR/workload.metrics"
  snap_vmstat after
  # Append policy note into metrics.
  {
    echo "wl_mthp_mid_enabled=${ANONFAULT_ENABLE_MTHP}"
  } >> "$RUN_DIR/workload.metrics"
  exit 0
fi
if [[ "$ANONFAULT_ENGINE" == c ]]; then
  skip "ANONFAULT_ENGINE=c but build/anon_fault is missing (no C compiler?)"
fi

# python3 fallback
if [[ "$ANONFAULT_ENGINE" == auto || "$ANONFAULT_ENGINE" == python3 ]] && command -v python3 >/dev/null 2>&1; then
  printf 'python3 anon_fault fallback size_mib=%s\n' "$ANONFAULT_SIZE_MIB" > "$RUN_DIR/command.txt"
  snap_vmstat before
  python3 - "$ANONFAULT_SIZE_MIB" "$RUN_DIR/workload.metrics" <<'PY'
import mmap, os, sys, time, resource
size_mib = int(sys.argv[1]); out = sys.argv[2]
bytes_ = size_mib * 1024 * 1024
stride = 4096
MADV_HUGEPAGE, MADV_NOHUGEPAGE = 14, 15

def run(advice):
    buf = mmap.mmap(-1, bytes_, flags=mmap.MAP_PRIVATE|mmap.MAP_ANONYMOUS, prot=mmap.PROT_READ|mmap.PROT_WRITE)
    try:
        buf.madvise(advice)
    except Exception:
        pass
    f0 = resource.getrusage(resource.RUSAGE_SELF).ru_minflt
    t0 = time.perf_counter_ns()
    for off in range(0, bytes_, stride):
        buf[off] = off & 0xff
    t1 = time.perf_counter_ns()
    f1 = resource.getrusage(resource.RUSAGE_SELF).ru_minflt
    buf.close()
    return t1 - t0, max(0, f1 - f0)

n_ns, n_flt = run(MADV_NOHUGEPAGE)
h_ns, h_flt = run(MADV_HUGEPAGE)
ratio = (h_ns / n_ns) if n_ns else 0.0
with open(out, "w") as f:
    f.write("wl_engine=python3-fallback\n")
    f.write(f"wl_size_mib={size_mib}\n")
    f.write(f"wl_bytes={bytes_}\n")
    f.write(f"wl_nohuge_fault_ns={n_ns}\n")
    f.write(f"wl_hugeprefer_fault_ns={h_ns}\n")
    f.write(f"wl_nohuge_minflt={n_flt}\n")
    f.write(f"wl_hugeprefer_minflt={h_flt}\n")
    f.write(f"wl_hugeprefer_vs_nohuge_fault_ns_ratio={ratio:.6f}\n")
print(f"anon_fault.py nohuge={n_ns} hugeprefer={h_ns} ratio={ratio:.4f}")
PY
  snap_vmstat after
  echo "wl_mthp_mid_enabled=${ANONFAULT_ENABLE_MTHP}" >> "$RUN_DIR/workload.metrics"
  exit 0
fi

skip "no anon_fault engine: need a C compiler (build/anon_fault) or python3"
