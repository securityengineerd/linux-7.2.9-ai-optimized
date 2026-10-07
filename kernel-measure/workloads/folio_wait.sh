#!/usr/bin/env bash
# kernel-measure: folio_wait (Task 15)
# Concurrent writeback / page-lock waits across many unrelated folios so the
# hashed folio_wait_table (256 buckets) sees collision pressure.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
HARNESS_DIR=${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=lib/build_tool.sh
source "$HARNESS_DIR/lib/build_tool.sh"
DURATION=${DURATION:-15}
RUN_DIR=${RUN_DIR:-.}
FOLIOWAIT_ENGINE=${FOLIOWAIT_ENGINE:-auto}
FOLIOWAIT_MODE=${FOLIOWAIT_MODE:-writeback}
FOLIOWAIT_THREADS=${FOLIOWAIT_THREADS:-0}
FOLIOWAIT_NFILES=${FOLIOWAIT_NFILES:-512}
FOLIOWAIT_FILE_KB=${FOLIOWAIT_FILE_KB:-64}
FOLIOWAIT_CHUNK_KB=${FOLIOWAIT_CHUNK_KB:-4}
# Prefer non-tmpfs so writeback actually hits a block device.
FOLIOWAIT_PARENT=${FOLIOWAIT_PARENT:-}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

pick_parent() {
  local cand
  if [[ -n "$FOLIOWAIT_PARENT" ]]; then
    printf '%s\n' "$FOLIOWAIT_PARENT"
    return
  fi
  for cand in "$HARNESS_DIR/runs" "$HOME" /var/tmp /tmp; do
    [[ -d "$cand" && -w "$cand" ]] || continue
    # Prefer non-tmpfs
    if findmnt -T "$cand" -o FSTYPE -n 2>/dev/null | grep -qiE 'tmpfs|ramfs'; then
      continue
    fi
    printf '%s\n' "$cand"
    return
  done
  printf '%s\n' "${TMPDIR:-/tmp}"
}

snapshot_vmstat() {
  local tag=$1
  grep -E '^(nr_dirty|nr_writeback|nr_writeback_temp|pgpgout|nr_dirty_threshold) ' /proc/vmstat \
    > "$RUN_DIR/vmstat_folio.${tag}.txt" || true
}

if [[ "${1:-}" == "--prepare" ]]; then
  if [[ "$FOLIOWAIT_ENGINE" == auto || "$FOLIOWAIT_ENGINE" == c ]]; then
    if build_tool folio_wait >/dev/null; then
      record_build folio_wait "$RUN_DIR"
      echo "prepared build/folio_wait"
    else
      echo "could not build folio_wait (no C compiler or build failed)"
    fi
  fi
  exit 0
fi

bin="$HARNESS_DIR/build/folio_wait"
: > "$RUN_DIR/workload.metrics"

parent=$(pick_parent)
workdir="$parent/folio_wait.$$"
mkdir -p "$workdir"
echo "parent=$parent" > "$RUN_DIR/folio_wait_parent.txt"
findmnt -T "$parent" -o TARGET,FSTYPE,SOURCE -n > "$RUN_DIR/folio_wait_fs.txt" 2>/dev/null || true
echo "wl_folio_wait_parent_fstype=$(findmnt -T "$parent" -o FSTYPE -n 2>/dev/null || echo unknown)" >> "$RUN_DIR/workload.metrics"
echo "wl_page_lock_unfairness=$(cat /proc/sys/vm/page_lock_unfairness 2>/dev/null || echo n/a)" >> "$RUN_DIR/workload.metrics"

snapshot_vmstat before

rc=0
cleanup() {
  rm -rf "$workdir" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$FOLIOWAIT_ENGINE" == auto || "$FOLIOWAIT_ENGINE" == c ]] && [[ -x "$bin" ]]; then
  cmd="$bin -d $DURATION -t $FOLIOWAIT_THREADS -f $FOLIOWAIT_NFILES -s $FOLIOWAIT_FILE_KB -c $FOLIOWAIT_CHUNK_KB -m $FOLIOWAIT_MODE -p $workdir"
  printf '%s\n' "$cmd" > "$RUN_DIR/command.txt"
  set +e
  # shellcheck disable=SC2086
  $bin -d "$DURATION" -t "$FOLIOWAIT_THREADS" -f "$FOLIOWAIT_NFILES" \
    -s "$FOLIOWAIT_FILE_KB" -c "$FOLIOWAIT_CHUNK_KB" -m "$FOLIOWAIT_MODE" \
    -p "$workdir" \
    > "$RUN_DIR/folio_wait.out" 2>"$RUN_DIR/folio_wait.err"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    grep '^wl_' "$RUN_DIR/folio_wait.out" >> "$RUN_DIR/workload.metrics" || true
  fi
elif command -v fio >/dev/null 2>&1; then
  printf '%s\n' "fio randrw+fsync fallback (C engine missing)" > "$RUN_DIR/command.txt"
  set +e
  fio --name=folio_wait --directory="$workdir" --rw=randwrite --bs=4k \
    --size=64k --nrfiles="$FOLIOWAIT_NFILES" --numjobs="${FOLIOWAIT_THREADS:-4}" \
    --iodepth=1 --fsync=1 --runtime="$DURATION" --time_based=1 --group_reporting \
    > "$RUN_DIR/fio.out" 2>"$RUN_DIR/fio.err"
  rc=$?
  set -e
  echo "wl_folio_wait_engine=fio" >> "$RUN_DIR/workload.metrics"
else
  skip "neither folio_wait binary nor fio available"
fi

snapshot_vmstat after

python3 - "$RUN_DIR" <<'PY'
import sys
rd = sys.argv[1]
def load(tag):
    d = {}
    try:
        with open(f"{rd}/vmstat_folio.{tag}.txt") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    d[parts[0]] = int(parts[1])
    except FileNotFoundError:
        pass
    return d
b, a = load("before"), load("after")
keys = ["nr_dirty", "nr_writeback", "nr_writeback_temp", "pgpgout", "nr_dirty_threshold"]
lines = []
for k in keys:
    lines.append(f"wl_vm_{k}_before={b.get(k, 0)}")
    lines.append(f"wl_vm_{k}_after={a.get(k, 0)}")
    lines.append(f"wl_vm_{k}_delta={a.get(k, 0) - b.get(k, 0)}")
with open(f"{rd}/workload.metrics", "a") as f:
    f.write("\n".join(lines) + "\n")
print("vmstat folio deltas recorded")
PY

ops=$(grep '^wl_folio_wait_ops_per_sec=' "$RUN_DIR/workload.metrics" | cut -d= -f2 || true)
echo "folio_wait_ops_per_sec=${ops:-?}" >&2
exit "$rc"
