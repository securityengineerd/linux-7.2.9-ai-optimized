#!/usr/bin/env bash
# kernel-measure: folio_split
# Task 8: force reclaim / deferred-split of large anonymous folios so
# thp_split_page / thp_deferred_split_page / thp_swpout(_fallback) move.
# Idle boxes show all split counters at 0.
#
# Policy hook (restored on exit; needs passwordless sudo):
#   FOLIOSPLIT_SHRINK_UNDERUSED=0|1  -> transparent_hugepage/shrink_underused
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
HARNESS_DIR=${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=lib/build_tool.sh
source "$HARNESS_DIR/lib/build_tool.sh"
DURATION=${DURATION:-25}
RUN_DIR=${RUN_DIR:-.}
FOLIOSPLIT_ENGINE=${FOLIOSPLIT_ENGINE:-auto}
FOLIOSPLIT_MODE=${FOLIOSPLIT_MODE:-partial}
FOLIOSPLIT_RESERVE_MIB=${FOLIOSPLIT_RESERVE_MIB:-1024}
FOLIOSPLIT_THP_MIB=${FOLIOSPLIT_THP_MIB:-2048}
FOLIOSPLIT_HOG_MIB=${FOLIOSPLIT_HOG_MIB:-0}
FOLIOSPLIT_PUNCH_EVERY_N=${FOLIOSPLIT_PUNCH_EVERY_N:-2}
FOLIOSPLIT_SHRINK_UNDERUSED=${FOLIOSPLIT_SHRINK_UNDERUSED:-}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

SHRINK_PATH=/sys/kernel/mm/transparent_hugepage/shrink_underused
SHRINK_RESTORE=""

restore_policy() {
  if [[ -n "$SHRINK_RESTORE" && -e "$SHRINK_PATH" ]]; then
    sudo -n sh -c "echo $SHRINK_RESTORE > $SHRINK_PATH" 2>/dev/null || \
      echo "$SHRINK_RESTORE" > "$SHRINK_PATH" 2>/dev/null || true
  fi
}

current_shrink() {
  cat "$SHRINK_PATH" 2>/dev/null | tr -d ' \n' || echo unknown
}

apply_policy() {
  if [[ -n "$FOLIOSPLIT_SHRINK_UNDERUSED" ]]; then
    [[ -e "$SHRINK_PATH" ]] || skip "shrink_underused sysfs missing"
    SHRINK_RESTORE=$(current_shrink)
    if ! sudo -n sh -c "echo $FOLIOSPLIT_SHRINK_UNDERUSED > $SHRINK_PATH" 2>/dev/null; then
      if [[ -w "$SHRINK_PATH" ]]; then
        echo "$FOLIOSPLIT_SHRINK_UNDERUSED" > "$SHRINK_PATH"
      else
        skip "cannot set shrink_underused=$FOLIOSPLIT_SHRINK_UNDERUSED (need sudo)"
      fi
    fi
  fi
  {
    echo "shrink_underused_requested=${FOLIOSPLIT_SHRINK_UNDERUSED:-unchanged}"
    echo "shrink_underused_before=${SHRINK_RESTORE:-}"
    echo "shrink_underused_active=$(current_shrink)"
    echo "thp_enabled=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"
    echo "thp_defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || echo n/a)"
    echo "swap=$(cat /proc/swaps 2>/dev/null | tr '\n' ';' || true)"
  } > "$RUN_DIR/policy.txt"
}

if [[ "${1:-}" == "--prepare" ]]; then
  if [[ "$FOLIOSPLIT_ENGINE" == auto || "$FOLIOSPLIT_ENGINE" == c ]]; then
    if build_tool folio_split >/dev/null; then
      record_build folio_split "$RUN_DIR"
      echo "prepared build/folio_split"
    else
      echo "could not build folio_split (no C compiler or build failed)"
    fi
  fi
  exit 0
fi

raise_memlock() {
  if sudo -n prlimit --pid=$$ --memlock=unlimited:unlimited 2>/dev/null; then
    return 0
  fi
  ulimit -l unlimited 2>/dev/null || true
}

trap restore_policy EXIT
raise_memlock
apply_policy

bin="$HARNESS_DIR/build/folio_split"

snap_vmstat() {
  local tag=$1
  {
    echo "tag=$tag"
    echo "time=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    grep -E '^(thp_split|thp_deferred|thp_swpout|thp_fault|pgscan|pgsteal|pswp|oom_kill|pgfault|pgmajfault|nr_anon_transparent)' /proc/vmstat || true
    echo "MemAvailable_kB=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    echo "SwapFree_kB=$(awk '/SwapFree:/ {print $2}' /proc/meminfo)"
    echo "shrink_underused=$(current_shrink)"
    if [[ -d /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/stats ]]; then
      echo "hugepages-2048kB/stats:"
      for f in /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/stats/*; do
        echo "  $(basename "$f")=$(cat "$f" 2>/dev/null || echo n/a)"
      done
    fi
  } > "$RUN_DIR/vmstat_${tag}.txt"
}

if [[ "$FOLIOSPLIT_ENGINE" == auto || "$FOLIOSPLIT_ENGINE" == c ]] && [[ -x "$bin" ]]; then
  args=(-m "$FOLIOSPLIT_MODE" -r "$FOLIOSPLIT_RESERVE_MIB" -t "$FOLIOSPLIT_THP_MIB" -p "$FOLIOSPLIT_PUNCH_EVERY_N")
  if [[ "$FOLIOSPLIT_HOG_MIB" != "0" ]]; then
    args+=(-h "$FOLIOSPLIT_HOG_MIB")
  fi
  printf 'build/folio_split %s\n' "${args[*]}" > "$RUN_DIR/command.txt"
  snap_vmstat before
  set +e
  "$bin" "${args[@]}" -o "$RUN_DIR/workload.metrics"
  rc=$?
  set -e
  snap_vmstat after
  {
    echo "wl_shrink_underused=$(current_shrink)"
    echo "wl_exit_rc=$rc"
  } >> "$RUN_DIR/workload.metrics"
  if [[ $rc -eq 7 ]]; then
    echo "OOM observed during folio_split (exit 7)" > "$RUN_DIR/oom_note.txt"
  fi
  exit 0
fi
if [[ "$FOLIOSPLIT_ENGINE" == c ]]; then
  skip "FOLIOSPLIT_ENGINE=c but build/folio_split is missing"
fi

skip "no folio_split engine: need a C compiler to build workloads/src/folio_split.c"
