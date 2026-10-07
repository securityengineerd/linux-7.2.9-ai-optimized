#!/usr/bin/env bash
# kernel-measure: prepare
# Task 3 hierarchical cpu.weight / cpu.max workload.
#
# Builds a cgroup v2 tree under /sys/fs/cgroup/kmeas.slice/, runs oversubscribed
# CPU hogs in weighted sibling leaves at each requested depth, optionally caps
# one leaf with cpu.max, and reports weight-share error plus throttle stats.
#
# Requires: cgroup v2 with the cpu controller, passwordless sudo for cgroup ops.
# Hogs: stress-ng --cpu when available, else bash busy loops.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi

HARNESS_DIR=${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
DURATION=${DURATION:-24}
RUN_DIR=${RUN_DIR:-.}
CGCPU_ROOT=${CGCPU_ROOT:-/sys/fs/cgroup/kmeas.slice}
CGCPU_DEPTHS=${CGCPU_DEPTHS:-"1 3 6"}
CGCPU_WEIGHTS=${CGCPU_WEIGHTS:-"100 200 400"}
CGCPU_MAX=${CGCPU_MAX:-"20000 100000"}
CGCPU_HOGS_PER_SIB=${CGCPU_HOGS_PER_SIB:-0}
CGCPU_SETTLE_MS=${CGCPU_SETTLE_MS:-200}

mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

HOG_PIDS=()
CREATED_DIRS=()

cg_write() {
  local path=$1 data=$2
  printf '%s' "$data" | sudo tee "$path" >/dev/null
}

cg_mkdir() {
  local path=$1
  sudo mkdir -p "$path"
  CREATED_DIRS+=("$path")
}

cleanup() {
  local pid d
  if ((${#HOG_PIDS[@]})); then
    for pid in "${HOG_PIDS[@]}"; do
      kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.2
    for pid in "${HOG_PIDS[@]}"; do
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
  # Kill any leftover procs still in the tree, then remove dirs deepest-first.
  if [[ -d "$CGCPU_ROOT" ]]; then
    sudo bash -c '
      root="'"$CGCPU_ROOT"'"
      if [[ -f "$root/cgroup.kill" ]]; then
        echo 1 > "$root/cgroup.kill" 2>/dev/null || true
        sleep 0.1
      fi
      # Move any remaining procs to root cgroup so rmdir can succeed.
      if [[ -f "$root/cgroup.procs" ]]; then
        while read -r p; do
          [[ -n "$p" ]] || continue
          echo "$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
        done < <(find "$root" -name cgroup.procs -exec cat {} \; 2>/dev/null | sort -u)
      fi
      find "$root" -mindepth 1 -depth -type d -exec rmdir {} \; 2>/dev/null || true
      rmdir "$root" 2>/dev/null || true
    ' || true
  fi
}
trap cleanup EXIT
trap 'exit 143' INT TERM

have_cpu_controller() {
  local root=/sys/fs/cgroup
  [[ -f "$root/cgroup.controllers" ]] || return 1
  grep -qw cpu "$root/cgroup.controllers" || return 1
  # Ensure cpu is delegated to children at root (safe no-op if already set).
  if [[ -f "$root/cgroup.subtree_control" ]]; then
    if ! grep -qw cpu "$root/cgroup.subtree_control" 2>/dev/null; then
      if ! printf '+cpu\n' | sudo tee "$root/cgroup.subtree_control" >/dev/null 2>&1; then
        return 1
      fi
    fi
  fi
  return 0
}

read_usage_usec() {
  local cg=$1
  local v
  v=$(awk '/^usage_usec / { print $2; exit }' "$cg/cpu.stat" 2>/dev/null || echo 0)
  printf '%s\n' "${v:-0}"
}

read_throttle_pair() {
  # prints: nr_throttled throttled_usec
  local cg=$1
  local nr usec
  nr=$(awk '/^nr_throttled / { print $2; exit }' "$cg/cpu.stat" 2>/dev/null || echo 0)
  usec=$(awk '/^throttled_usec / { print $2; exit }' "$cg/cpu.stat" 2>/dev/null || echo 0)
  printf '%s %s\n' "${nr:-0}" "${usec:-0}"
}

start_hogs_in() {
  local cg=$1
  local n=$2
  local i
  # Run hogs as the harness user (not under sudo/setuid) so perf stat inherits
  # them. Only the cgroup.procs write needs root.
  for ((i = 0; i < n; i++)); do
    if command -v stress-ng >/dev/null 2>&1; then
      bash -c "
        printf '%s' \$\$ | sudo tee '$cg/cgroup.procs' >/dev/null || exit 1
        exec stress-ng --cpu 1 --timeout ${DURATION}s --quiet
      " &
      HOG_PIDS+=($!)
    else
      bash -c "
        printf '%s' \$\$ | sudo tee '$cg/cgroup.procs' >/dev/null || exit 1
        end=\$((SECONDS + $DURATION + 5))
        while (( SECONDS < end )); do :; done
      " &
      HOG_PIDS+=($!)
    fi
  done
}

kill_hogs() {
  local pid
  if ((${#HOG_PIDS[@]})); then
    for pid in "${HOG_PIDS[@]}"; do
      kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.15
    for pid in "${HOG_PIDS[@]}"; do
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
  HOG_PIDS=()
  # Sweep anything still under the tree into root.
  if [[ -d "$CGCPU_ROOT" ]]; then
    sudo bash -c '
      root="'"$CGCPU_ROOT"'"
      while read -r p; do
        [[ -n "$p" ]] || continue
        echo "$p" > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
      done < <(find "$root" -name cgroup.procs -exec cat {} \; 2>/dev/null | sort -u)
    ' || true
  fi
}

setup_root() {
  cg_mkdir "$CGCPU_ROOT"
  # Parent already has +cpu; enable on our root so children get cpu.*.
  if [[ -f "$CGCPU_ROOT/cgroup.subtree_control" ]]; then
    cg_write "$CGCPU_ROOT/cgroup.subtree_control" "+cpu" || true
  fi
  if [[ ! -f "$CGCPU_ROOT/cpu.weight" ]]; then
    skip "cpu controller files missing under ${CGCPU_ROOT} (cpu not delegated)"
  fi
}

# Build a chain of (depth-1) intermediates ending at a parent that will hold siblings.
# Returns the parent path on stdout.
make_chain() {
  local depth=$1
  local tag=$2
  local parent="$CGCPU_ROOT/$tag"
  local i path
  cg_mkdir "$parent"
  cg_write "$parent/cgroup.subtree_control" "+cpu"
  path=$parent
  if (( depth > 1 )); then
    for ((i = 1; i < depth; i++)); do
      path="$path/n$i"
      cg_mkdir "$path"
      # Intermediate nodes need +cpu so their children get weight/max.
      if (( i < depth - 1 )); then
        cg_write "$path/cgroup.subtree_control" "+cpu"
      else
        # Parent of siblings: enable cpu for sibling leaves.
        cg_write "$path/cgroup.subtree_control" "+cpu"
      fi
    done
  fi
  printf '%s\n' "$path"
}

weight_err_pct() {
  # args: weight1 usage1 weight2 usage2 ...
  # Mean absolute percentage error of actual share vs expected share, in percent.
  local -a w=() u=()
  local i n=0 sum_w=0 sum_u=0 err_sum=0 actual expected
  while (( $# >= 2 )); do
    w+=("$1"); u+=("$2")
    sum_w=$((sum_w + $1))
    sum_u=$((sum_u + $2))
    n=$((n + 1))
    shift 2
  done
  if (( n == 0 || sum_w <= 0 )); then
    echo "n/a"
    return
  fi
  if (( sum_u <= 0 )); then
    echo "100"
    return
  fi
  for ((i = 0; i < n; i++)); do
    expected=$(awk -v ww="${w[$i]}" -v sw="$sum_w" 'BEGIN { printf "%.10f", ww / sw }')
    actual=$(awk -v uu="${u[$i]}" -v su="$sum_u" 'BEGIN { printf "%.10f", uu / su }')
    err_sum=$(awk -v e="$err_sum" -v a="$actual" -v x="$expected" \
      'BEGIN { d = a - x; if (d < 0) d = -d; printf "%.10f", e + (d / x) }')
  done
  awk -v s="$err_sum" -v n="$n" 'BEGIN { printf "%.2f", (s / n) * 100 }'
}

run_depth() {
  local depth=$1
  local slice_sec=$2
  local tag="d${depth}"
  local parent leaf w i idx
  local -a weights=() leaves=() usages_before=() usages_after=()
  local max_quota max_period max_leaf
  local thr_nr=0 thr_usec=0 thr_nr2 thr_usec2
  local err hog_n nproc_n

  read -r -a weights <<<"$CGCPU_WEIGHTS"
  ((${#weights[@]} >= 2)) || skip "CGCPU_WEIGHTS needs at least two weights (got: ${CGCPU_WEIGHTS})"

  parent=$(make_chain "$depth" "$tag")

  idx=0
  for w in "${weights[@]}"; do
    leaf="$parent/w${w}_${idx}"
    cg_mkdir "$leaf"
    cg_write "$leaf/cpu.weight" "$w"
    leaves+=("$leaf")
    idx=$((idx + 1))
  done

  # Separate throttle leaf: do NOT put cpu.max on a weight sibling, or the
  # share-vs-weight error becomes meaningless. A dedicated leaf with default
  # weight + cpu.max exercises the throttle path for wl_nr_throttled /
  # wl_throttled_usec while weight siblings stay uncapped.
  max_quota=${CGCPU_MAX%% *}
  max_period=${CGCPU_MAX#* }
  max_period=${max_period%% *}
  max_leaf=""
  if [[ -n "$max_quota" && -n "$max_period" && "$max_quota" != "max" ]]; then
    max_leaf="$parent/throttle"
    cg_mkdir "$max_leaf"
    cg_write "$max_leaf/cpu.weight" "100"
    cg_write "$max_leaf/cpu.max" "${max_quota} ${max_period}"
  fi

  nproc_n=$(nproc)
  if [[ "$CGCPU_HOGS_PER_SIB" =~ ^[0-9]+$ ]] && (( CGCPU_HOGS_PER_SIB > 0 )); then
    hog_n=$CGCPU_HOGS_PER_SIB
  else
    # Oversubscribe: enough threads that siblings must share physical CPUs.
    hog_n=$(( (nproc_n * 2 + ${#weights[@]} - 1) / ${#weights[@]} ))
    (( hog_n < 2 )) && hog_n=2
  fi

  for leaf in "${leaves[@]}"; do
    usages_before+=("$(read_usage_usec "$leaf")")
  done
  if [[ -n "$max_leaf" ]]; then
    read -r thr_nr thr_usec <<<"$(read_throttle_pair "$max_leaf")"
  fi

  for leaf in "${leaves[@]}"; do
    start_hogs_in "$leaf" "$hog_n"
  done
  if [[ -n "$max_leaf" ]]; then
    # One hog is enough to hit the quota and accumulate throttle time.
    start_hogs_in "$max_leaf" 1
  fi

  sleep "$slice_sec"

  kill_hogs

  # Brief settle so cpu.stat catches final ticks.
  sleep "$(awk -v ms="$CGCPU_SETTLE_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"

  for leaf in "${leaves[@]}"; do
    usages_after+=("$(read_usage_usec "$leaf")")
  done
  if [[ -n "$max_leaf" ]]; then
    read -r thr_nr2 thr_usec2 <<<"$(read_throttle_pair "$max_leaf")"
    thr_nr=$((thr_nr2 - thr_nr))
    thr_usec=$((thr_usec2 - thr_usec))
    (( thr_nr < 0 )) && thr_nr=0
    (( thr_usec < 0 )) && thr_usec=0
  fi

  local -a pair_args=()
  local delta
  for ((i = 0; i < ${#weights[@]}; i++)); do
    delta=$(( usages_after[i] - usages_before[i] ))
    (( delta < 0 )) && delta=0
    pair_args+=("${weights[$i]}" "$delta")
    echo "wl_d${depth}_w${weights[$i]}_usage_usec=${delta}"
  done
  err=$(weight_err_pct "${pair_args[@]}")
  echo "wl_weight_err_pct_d${depth}=${err}"
  echo "wl_d${depth}_hogs_per_sib=${hog_n}"
  echo "wl_d${depth}_nr_throttled=${thr_nr}"
  echo "wl_d${depth}_throttled_usec=${thr_usec}"

  # Stash for caller via globals
  DEPTH_ERRS+=("$err")
  TOTAL_NR_THROTTLED=$((TOTAL_NR_THROTTLED + thr_nr))
  TOTAL_THROTTLED_USEC=$((TOTAL_THROTTLED_USEC + thr_usec))
}

# --- prepare ---------------------------------------------------------------
if [[ "${1:-}" == "--prepare" ]]; then
  if ! have_cpu_controller; then
    echo "cpu controller unavailable"
    exit 0
  fi
  if ! sudo -n true 2>/dev/null; then
    echo "passwordless sudo unavailable"
    exit 0
  fi
  echo "cgroup v2 cpu controller ready; root=${CGCPU_ROOT}"
  exit 0
fi

# --- main ------------------------------------------------------------------
if [[ ! -d /sys/fs/cgroup ]] || [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
  skip "cgroup v2 not mounted at /sys/fs/cgroup"
fi
if ! have_cpu_controller; then
  skip "cpu controller unavailable on cgroup v2 (not in cgroup.controllers / cannot enable)"
fi
if ! sudo -n true 2>/dev/null; then
  skip "passwordless sudo required to manage ${CGCPU_ROOT}"
fi

# Optional: ensure tracefs is mounted (do not fail the workload if this no-ops).
if [[ ! -d /sys/kernel/tracing/events ]] && [[ -d /sys/kernel ]]; then
  sudo mkdir -p /sys/kernel/tracing 2>/dev/null || true
  if [[ ! -d /sys/kernel/tracing/events ]]; then
    sudo mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
  fi
fi

read -r -a DEPTH_LIST <<<"$CGCPU_DEPTHS"
((${#DEPTH_LIST[@]} >= 1)) || skip "CGCPU_DEPTHS empty"

NUM_DEPTHS=${#DEPTH_LIST[@]}
# Leave a little slack for setup/teardown inside DURATION.
SLICE=$(( DURATION / NUM_DEPTHS ))
(( SLICE < 2 )) && SLICE=2

setup_root

METRICS_TMP=$(mktemp)
DEPTH_ERRS=()
TOTAL_NR_THROTTLED=0
TOTAL_THROTTLED_USEC=0

{
  echo "wl_engine=cgroup_cpu"
  printf 'wl_args=depth=%s weights=%s max=%s duration=%s slice=%s nproc=%s\n' \
    "$CGCPU_DEPTHS" "$CGCPU_WEIGHTS" "$CGCPU_MAX" "$DURATION" "$SLICE" "$(nproc)"
  echo "wl_cg_root=${CGCPU_ROOT}"
  echo "wl_depths=${CGCPU_DEPTHS// /,}"
} > "$METRICS_TMP"

for depth in "${DEPTH_LIST[@]}"; do
  if ! [[ "$depth" =~ ^[0-9]+$ ]] || (( depth < 1 )); then
    skip "invalid depth in CGCPU_DEPTHS: ${depth}"
  fi
  run_depth "$depth" "$SLICE" >> "$METRICS_TMP"
done

# Aggregate primary metrics for tasks.conf
max_err="0"
sum_err="0"
count_err=0
for e in "${DEPTH_ERRS[@]}"; do
  if [[ "$e" == "n/a" ]]; then
    continue
  fi
  count_err=$((count_err + 1))
  sum_err=$(awk -v s="$sum_err" -v e="$e" 'BEGIN { printf "%.10f", s + e }')
  max_err=$(awk -v a="$max_err" -v e="$e" 'BEGIN { printf "%.2f", (e+0 > a+0) ? e : a }')
done
if (( count_err > 0 )); then
  avg_err=$(awk -v s="$sum_err" -v n="$count_err" 'BEGIN { printf "%.2f", s / n }')
else
  avg_err="n/a"
  max_err="n/a"
fi

{
  echo "wl_weight_err_pct=${avg_err}"
  echo "wl_weight_err_pct_max=${max_err}"
  echo "wl_nr_throttled=${TOTAL_NR_THROTTLED}"
  echo "wl_throttled_usec=${TOTAL_THROTTLED_USEC}"
} >> "$METRICS_TMP"

cp "$METRICS_TMP" "$RUN_DIR/workload.metrics"
rm -f "$METRICS_TMP"

printf 'cgroup_cpu depths=%s weights=%s max=%s slice=%ss\n' \
  "$CGCPU_DEPTHS" "$CGCPU_WEIGHTS" "$CGCPU_MAX" "$SLICE" > "$RUN_DIR/command.txt"

# cleanup via trap
exit 0
