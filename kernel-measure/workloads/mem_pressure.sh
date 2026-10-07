#!/usr/bin/env bash
# kernel-measure: prepare
# Task 7: allocation latency under memory pressure / fragmentation —
# exercise direct reclaim + direct compaction on the fault path so
# transparent_hugepage/defrag and vm.compaction_proactiveness policies
# can be A/B'd honestly. Idle boxes show compact_stall=0 / pgscan_direct=0.
#
# Engines (MEMPRESS_ENGINE=auto tries them in this order):
#   c    build/mem_pressure from workloads/src/mem_pressure.c
#        fill+punch buddy holes, then THP-preferring alloc rounds.
#   python3 fallback: smaller fill/punch/alloc (regression only).
#
# Optional policy hooks (restored on exit; need passwordless sudo):
#   MEMPRESS_THP_DEFRAG=always|defer|defer+madvise|madvise|never
#   MEMPRESS_COMPACTION_PROACTIVENESS=<0..100>
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
HARNESS_DIR=${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=lib/build_tool.sh
source "$HARNESS_DIR/lib/build_tool.sh"
DURATION=${DURATION:-20}
RUN_DIR=${RUN_DIR:-.}
MEMPRESS_ENGINE=${MEMPRESS_ENGINE:-auto}
MEMPRESS_RESERVE_MIB=${MEMPRESS_RESERVE_MIB:-1024}
MEMPRESS_FILL_PCT=${MEMPRESS_FILL_PCT:-95}
MEMPRESS_CHUNK_MIB=${MEMPRESS_CHUNK_MIB:-64}
MEMPRESS_ROUNDS=${MEMPRESS_ROUNDS:-32}
MEMPRESS_MODE=${MEMPRESS_MODE:-fragment}
MEMPRESS_THP_DEFRAG=${MEMPRESS_THP_DEFRAG:-}
MEMPRESS_COMPACTION_PROACTIVENESS=${MEMPRESS_COMPACTION_PROACTIVENESS:-}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

THP_DEFRAG_PATH=/sys/kernel/mm/transparent_hugepage/defrag
THP_DEFRAG_RESTORE=""
COMPACT_PRO_RESTORE=""

restore_policy() {
  if [[ -n "$THP_DEFRAG_RESTORE" && -e "$THP_DEFRAG_PATH" ]]; then
    sudo -n sh -c "echo $THP_DEFRAG_RESTORE > $THP_DEFRAG_PATH" 2>/dev/null || \
      echo "$THP_DEFRAG_RESTORE" > "$THP_DEFRAG_PATH" 2>/dev/null || true
  fi
  if [[ -n "$COMPACT_PRO_RESTORE" ]]; then
    sudo -n sysctl -w "vm.compaction_proactiveness=$COMPACT_PRO_RESTORE" >/dev/null 2>&1 || true
  fi
}

current_defrag() {
  awk '{
    if (match($0, /\[[^]]+\]/)) {
      s=substr($0, RSTART+1, RLENGTH-2); print s; exit
    }
  }' "$THP_DEFRAG_PATH" 2>/dev/null || echo unknown
}

apply_policy() {
  if [[ -n "$MEMPRESS_THP_DEFRAG" ]]; then
    [[ -e "$THP_DEFRAG_PATH" ]] || skip "THP defrag sysfs missing"
    THP_DEFRAG_RESTORE=$(current_defrag)
    if ! sudo -n sh -c "echo $MEMPRESS_THP_DEFRAG > $THP_DEFRAG_PATH" 2>/dev/null; then
      if [[ -w "$THP_DEFRAG_PATH" ]]; then
        echo "$MEMPRESS_THP_DEFRAG" > "$THP_DEFRAG_PATH"
      else
        skip "cannot set THP defrag=$MEMPRESS_THP_DEFRAG (need sudo)"
      fi
    fi
  fi
  if [[ -n "$MEMPRESS_COMPACTION_PROACTIVENESS" ]]; then
    COMPACT_PRO_RESTORE=$(sysctl -n vm.compaction_proactiveness 2>/dev/null || echo "")
    sudo -n sysctl -w "vm.compaction_proactiveness=$MEMPRESS_COMPACTION_PROACTIVENESS" >/dev/null \
      || skip "cannot set vm.compaction_proactiveness"
  fi
  {
    echo "thp_defrag_requested=${MEMPRESS_THP_DEFRAG:-unchanged}"
    echo "thp_defrag_before=${THP_DEFRAG_RESTORE:-}"
    echo "thp_defrag_active=$(current_defrag)"
    echo "compaction_proactiveness_requested=${MEMPRESS_COMPACTION_PROACTIVENESS:-unchanged}"
    echo "compaction_proactiveness_before=${COMPACT_PRO_RESTORE:-}"
    echo "compaction_proactiveness_active=$(sysctl -n vm.compaction_proactiveness 2>/dev/null || echo n/a)"
  } > "$RUN_DIR/policy.txt"
}

if [[ "${1:-}" == "--prepare" ]]; then
  if [[ "$MEMPRESS_ENGINE" == auto || "$MEMPRESS_ENGINE" == c ]]; then
    if build_tool mem_pressure >/dev/null; then
      record_build mem_pressure "$RUN_DIR"
      echo "prepared build/mem_pressure"
    else
      echo "could not build mem_pressure (no C compiler or build failed)"
    fi
  fi
  exit 0
fi

# Raise RLIMIT_MEMLOCK so the cushion mlock can succeed (needs sudo).
raise_memlock() {
  if sudo -n prlimit --pid=$$ --memlock=unlimited:unlimited 2>/dev/null; then
    return 0
  fi
  sudo -n bash -c "ulimit -l unlimited" 2>/dev/null || true
  ulimit -l unlimited 2>/dev/null || true
}

trap restore_policy EXIT
raise_memlock
apply_policy

bin="$HARNESS_DIR/build/mem_pressure"

snap_vmstat() {
  local tag=$1
  {
    echo "tag=$tag"
    echo "time=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    grep -E '^(compact_|pgscan|pgsteal|oom_kill|thp_|pgfault|pgmajfault|nr_free)' /proc/vmstat || true
    echo "MemAvailable_kB=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    echo "buddyinfo:"
    cat /proc/buddyinfo 2>/dev/null || true
  } > "$RUN_DIR/vmstat_${tag}.txt"
}

if [[ "$MEMPRESS_ENGINE" == auto || "$MEMPRESS_ENGINE" == c ]] && [[ -x "$bin" ]]; then
  printf 'build/mem_pressure -m %s -r %s -f %s -c %s -n %s\n' \
    "$MEMPRESS_MODE" "$MEMPRESS_RESERVE_MIB" "$MEMPRESS_FILL_PCT" "$MEMPRESS_CHUNK_MIB" "$MEMPRESS_ROUNDS" \
    > "$RUN_DIR/command.txt"
  snap_vmstat before
  set +e
  "$bin" -m "$MEMPRESS_MODE" -r "$MEMPRESS_RESERVE_MIB" -f "$MEMPRESS_FILL_PCT" \
    -c "$MEMPRESS_CHUNK_MIB" -n "$MEMPRESS_ROUNDS" \
    -o "$RUN_DIR/workload.metrics"
  rc=$?
  set -e
  snap_vmstat after
  {
    echo "wl_thp_defrag=$(current_defrag)"
    echo "wl_compaction_proactiveness=$(sysctl -n vm.compaction_proactiveness 2>/dev/null || echo n/a)"
    echo "wl_exit_rc=$rc"
  } >> "$RUN_DIR/workload.metrics"
  if [[ $rc -eq 7 ]]; then
    echo "OOM observed during mem_pressure (exit 7)" > "$RUN_DIR/oom_note.txt"
  fi
  # Non-zero other than skip/OOM still records metrics; harness treats as ok if metrics exist.
  exit 0
fi
if [[ "$MEMPRESS_ENGINE" == c ]]; then
  skip "MEMPRESS_ENGINE=c but build/mem_pressure is missing"
fi

# python3 fallback — smaller and slower; for harness smoke only.
if [[ "$MEMPRESS_ENGINE" == auto || "$MEMPRESS_ENGINE" == python3 ]] && command -v python3 >/dev/null 2>&1; then
  printf 'python3 mem_pressure fallback\n' > "$RUN_DIR/command.txt"
  snap_vmstat before
  python3 - "$MEMPRESS_RESERVE_MIB" "$MEMPRESS_FILL_PCT" "$MEMPRESS_CHUNK_MIB" \
    "$MEMPRESS_ROUNDS" "$RUN_DIR/workload.metrics" <<'PY'
import mmap, os, sys, time, resource
reserve, fill_pct, chunk_mib, rounds, out = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
page = 4096
MADV_HUGEPAGE, MADV_NOHUGEPAGE, MADV_DONTNEED = 14, 15, 4

def mem_avail_kb():
    for line in open("/proc/meminfo"):
        if line.startswith("MemAvailable:"):
            return int(line.split()[1])
    return 0

def vm(name):
    for line in open("/proc/vmstat"):
        k,v = line.split()
        if k == name:
            return int(v)
    return 0

keys = ["compact_stall","pgscan_direct","oom_kill","thp_fault_alloc","thp_fault_fallback"]
before = {k: vm(k) for k in keys}
avail0 = mem_avail_kb()
fill_mib = max(256, ((avail0//1024) - reserve) * fill_pct // 100)
fill_bytes = fill_mib * 1024 * 1024
chunk_bytes = chunk_mib * 1024 * 1024
buf = mmap.mmap(-1, fill_bytes, flags=mmap.MAP_PRIVATE|mmap.MAP_ANONYMOUS, prot=mmap.PROT_READ|mmap.PROT_WRITE)
try:
    buf.madvise(MADV_NOHUGEPAGE)
except Exception:
    pass
for off in range(0, fill_bytes, page):
    buf[off] = 1
for off in range(0, fill_bytes, 2*page):
    try:
        buf.madvise(MADV_DONTNEED, off, page)
    except Exception:
        pass
t0 = time.perf_counter_ns()
f0 = resource.getrusage(resource.RUSAGE_SELF).ru_minflt
cs = 0
for i in range(rounds):
    c = mmap.mmap(-1, chunk_bytes, flags=mmap.MAP_PRIVATE|mmap.MAP_ANONYMOUS, prot=mmap.PROT_READ|mmap.PROT_WRITE)
    try:
        c.madvise(MADV_HUGEPAGE)
    except Exception:
        pass
    for off in range(0, chunk_bytes, page):
        c[off] = off & 0xff
        cs = (cs + c[off]) & 0xffffffffffffffff
    c.close()
t1 = time.perf_counter_ns()
f1 = resource.getrusage(resource.RUSAGE_SELF).ru_minflt
after = {k: vm(k) for k in keys}
buf.close()
with open(out, "w") as f:
    f.write("wl_engine=python3-fallback\n")
    f.write(f"wl_fill_mib={fill_mib}\n")
    f.write(f"wl_alloc_fault_ns={t1-t0}\n")
    f.write(f"wl_alloc_minflt={max(0,f1-f0)}\n")
    f.write(f"wl_checksum={cs}\n")
    for k in keys:
        f.write(f"wl_{k}_delta={after[k]-before[k]}\n")
print(f"mem_pressure.py fill={fill_mib} fault_ns={t1-t0}")
PY
  snap_vmstat after
  {
    echo "wl_thp_defrag=$(current_defrag)"
    echo "wl_compaction_proactiveness=$(sysctl -n vm.compaction_proactiveness 2>/dev/null || echo n/a)"
  } >> "$RUN_DIR/workload.metrics"
  exit 0
fi

skip "no mem_pressure engine: need a C compiler or python3"
