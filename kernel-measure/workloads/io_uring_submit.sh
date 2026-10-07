#!/usr/bin/env bash
# kernel-measure: prepare
# Task 9: single-issuer io_uring submission hammer (IORING_OP_NOP).
#
# Engines (IOURING_ENGINE=auto tries them in this order):
#   c    build/io_uring_submit from workloads/src/io_uring_submit.c
#        Ring flags: SINGLE_ISSUER | DEFER_TASKRUN | COOP_TASKRUN
#        (LOCKLESS_CQ path). Floods NOP SQEs; reports wl_nops_per_sec.
#   fio  fio --ioengine=io_uring --hipri=0 with high iodepth on a temp file.
#        Does NOT set SINGLE_ISSUER (fio lacks that flag); regression only.
# Compare only runs with the same engine and arguments.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
HARNESS_DIR=${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=lib/build_tool.sh
source "$HARNESS_DIR/lib/build_tool.sh"
DURATION=${DURATION:-12}
RUN_DIR=${RUN_DIR:-.}
IOURING_ENGINE=${IOURING_ENGINE:-auto}
IOURING_BATCH=${IOURING_BATCH:-32}
IOURING_ENTRIES=${IOURING_ENTRIES:-256}
IOURING_MB=${IOURING_MB:-32}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

if [[ "${1:-}" == "--prepare" ]]; then
  if [[ "$IOURING_ENGINE" == auto || "$IOURING_ENGINE" == c ]]; then
    if build_tool io_uring_submit >/dev/null; then
      record_build io_uring_submit "$RUN_DIR"
      echo "prepared build/io_uring_submit"
    else
      echo "could not build io_uring_submit (no C compiler or build failed)"
    fi
  fi
  exit 0
fi

bin="$HARNESS_DIR/build/io_uring_submit"
if [[ "$IOURING_ENGINE" == auto || "$IOURING_ENGINE" == c ]] && [[ -x "$bin" ]]; then
  cmd=("$bin" -d "$DURATION" -b "$IOURING_BATCH" -e "$IOURING_ENTRIES"
       -o "$RUN_DIR/workload.metrics")
  printf 'build/io_uring_submit -d %s -b %s -e %s\n' "$DURATION" \
    "$IOURING_BATCH" "$IOURING_ENTRIES" > "$RUN_DIR/command.txt"
  exec "${cmd[@]}"
fi
if [[ "$IOURING_ENGINE" == c ]]; then
  skip "IOURING_ENGINE=c but build/io_uring_submit is missing (no C compiler?)"
fi

if [[ "$IOURING_ENGINE" == auto || "$IOURING_ENGINE" == fio ]] && command -v fio >/dev/null 2>&1; then
  parent=${STORAGE_PARENT:-${TMPDIR:-/tmp}}
  workdir=$(mktemp -d "${parent}/kernel-measure-iouring.XXXXXX")
  file="$workdir/benchfile"
  cleanup() { rm -rf "$workdir"; }
  trap cleanup EXIT
  printf '%s\n' "fio --ioengine=io_uring --filename=$file --rw=randread --bs=4k --size=${IOURING_MB}M --runtime=${DURATION} --time_based=1 --iodepth=32 --direct=1" > "$RUN_DIR/command.txt"
  echo "wl_engine=fio-io_uring" > "$RUN_DIR/workload.metrics"
  echo "wl_note=fio_lacks_SINGLE_ISSUER_flag" >> "$RUN_DIR/workload.metrics"
  if fio --name=kernel-measure-iouring \
      --filename="$file" \
      --ioengine=io_uring \
      --rw=randread --bs=4k \
      --size="${IOURING_MB}M" \
      --runtime="$DURATION" \
      --time_based=1 \
      --iodepth=32 \
      --numjobs=1 \
      --direct=1 \
      --group_reporting \
      --output="$RUN_DIR/fio.txt"; then
    exit 0
  fi
  skip "fio io_uring engine failed"
fi

skip "no io_uring_submit engine: need a C compiler (build/io_uring_submit) or fio"
