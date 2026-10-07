#!/usr/bin/env bash
# kernel-measure: prepare
# Task 5: hot page-cache reads — buffered pread vs mmap vs O_DIRECT.
#
# Engines (HOTREAD_ENGINE=auto tries them in this order):
#   c    build/hot_read from workloads/src/hot_read.c
#        Warms a file into the page cache, then reads the same byte budget
#        three ways. Reports wl_{buffered,mmap,odirect}_bytes_per_sec and
#        wl_*_vs_buffered_ns_ratio.
#   fio  fallback regression only (randread buffered vs direct; no mmap).
# Compare only runs with the same engine and arguments.
# Parent dir must support O_DIRECT (ext4/xfs). /tmp is often tmpfs — avoid it.
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
HOTREAD_ENGINE=${HOTREAD_ENGINE:-auto}
HOTREAD_FILE_MB=${HOTREAD_FILE_MB:-64}
HOTREAD_CHUNK_KB=${HOTREAD_CHUNK_KB:-128}
HOTREAD_TARGET_MIB=${HOTREAD_TARGET_MIB:-0}
HOTREAD_PARENT=${HOTREAD_PARENT:-}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

pick_parent() {
  local p candidates=()
  if [[ -n "$HOTREAD_PARENT" ]]; then
    candidates+=("$HOTREAD_PARENT")
  fi
  candidates+=("$HARNESS_DIR/runs" "$HOME" "/var/tmp" "/home/kernelmaster")
  for p in "${candidates[@]}"; do
    [[ -n "$p" && -d "$p" && -w "$p" ]] || continue
    # Reject tmpfs — O_DIRECT fails there.
    if findmnt -T "$p" -no FSTYPE 2>/dev/null | grep -qi '^tmpfs$'; then
      continue
    fi
    printf '%s\n' "$p"
    return 0
  done
  return 1
}

if [[ "${1:-}" == "--prepare" ]]; then
  if [[ "$HOTREAD_ENGINE" == auto || "$HOTREAD_ENGINE" == c ]]; then
    if build_tool hot_read >/dev/null; then
      record_build hot_read "$RUN_DIR"
      echo "prepared build/hot_read"
    else
      echo "could not build hot_read (no C compiler or build failed)"
    fi
  fi
  exit 0
fi

bin="$HARNESS_DIR/build/hot_read"
parent=$(pick_parent) || skip "no writable non-tmpfs parent for O_DIRECT file"

if [[ "$HOTREAD_ENGINE" == auto || "$HOTREAD_ENGINE" == c ]] && [[ -x "$bin" ]]; then
  cmd=("$bin" -d "$DURATION" -s "$HOTREAD_FILE_MB" -b "$HOTREAD_CHUNK_KB"
       -p "$parent" -o "$RUN_DIR/workload.metrics")
  if [[ "$HOTREAD_TARGET_MIB" =~ ^[1-9][0-9]*$ ]]; then
    cmd+=(-t "$HOTREAD_TARGET_MIB")
  fi
  {
    printf 'build/hot_read -d %s -s %s -b %s -p %s' "$DURATION" \
      "$HOTREAD_FILE_MB" "$HOTREAD_CHUNK_KB" "$parent"
    if [[ "$HOTREAD_TARGET_MIB" =~ ^[1-9][0-9]*$ ]]; then
      printf ' -t %s' "$HOTREAD_TARGET_MIB"
    fi
    printf '\n'
  } > "$RUN_DIR/command.txt"
  exec "${cmd[@]}"
fi
if [[ "$HOTREAD_ENGINE" == c ]]; then
  skip "HOTREAD_ENGINE=c but build/hot_read is missing (no C compiler?)"
fi

if [[ "$HOTREAD_ENGINE" == auto || "$HOTREAD_ENGINE" == fio ]] && command -v fio >/dev/null 2>&1; then
  workdir=$(mktemp -d "${parent}/kernel-measure-hotread.XXXXXX")
  file="$workdir/benchfile"
  cleanup() { rm -rf "$workdir"; }
  trap cleanup EXIT
  printf '%s\n' "fio buffered+direct randread fallback (no mmap path)" > "$RUN_DIR/command.txt"
  echo "wl_engine=fio-fallback" > "$RUN_DIR/workload.metrics"
  echo "wl_note=fio_fallback_no_mmap_path" >> "$RUN_DIR/workload.metrics"
  fio --name=hotread-buf --filename="$file" --rw=randread --bs=4k \
      --size="${HOTREAD_FILE_MB}M" --runtime="$DURATION" --time_based=1 \
      --iodepth=1 --direct=0 --numjobs=1 --group_reporting \
      --output="$RUN_DIR/fio-buffered.txt" || true
  fio --name=hotread-dio --filename="$file" --rw=randread --bs=4k \
      --size="${HOTREAD_FILE_MB}M" --runtime="$DURATION" --time_based=1 \
      --iodepth=1 --direct=1 --numjobs=1 --group_reporting \
      --output="$RUN_DIR/fio-direct.txt" || true
  exit 0
fi

skip "no hot_read engine: need a C compiler (build/hot_read) or fio"
