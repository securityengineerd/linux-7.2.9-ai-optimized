#!/usr/bin/env bash
# Short storage mix on a temp file. fio if present, else dd. Always deletes the file.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
DURATION=${DURATION:-8}
STORAGE_MB=${STORAGE_MB:-32}
RUN_DIR=${RUN_DIR:-.}
mkdir -p "$RUN_DIR"
if [[ ! "$STORAGE_MB" =~ ^[0-9]+$ ]] || (( STORAGE_MB <= 0 )); then
  echo "error: STORAGE_MB must be a positive integer" >&2
  exit 1
fi
parent=${STORAGE_PARENT:-${TMPDIR:-/tmp}}
workdir=$(mktemp -d "${parent}/kernel-measure-storage.XXXXXX")
file="$workdir/benchfile"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT
trap 'exit 143' INT TERM

note() { echo "$*" | tee -a "$RUN_DIR/storage_notes.txt" >&2; }

if command -v fio >/dev/null 2>&1; then
  run_fio() {
    local direct=$1
    fio --name=kernel-measure \
      --filename="$file" \
      --rw=randrw --rwmixread=50 \
      --bs=4k \
      --size="${STORAGE_MB}M" \
      --runtime="$DURATION" \
      --time_based=1 \
      --iodepth=1 \
      --numjobs=1 \
      --direct="$direct" \
      --group_reporting \
      --output="$RUN_DIR/fio.txt"
  }
  printf '%s\n' "fio --name=kernel-measure --filename=$file --rw=randrw --bs=4k --size=${STORAGE_MB}M --runtime=${DURATION} --time_based=1 --direct=1" > "$RUN_DIR/command.txt"
  if run_fio 1; then
    echo direct > "$RUN_DIR/storage_mode.txt"
    exit 0
  fi
  note "fio --direct=1 failed; retrying buffered IO"
  rm -f "$file"
  printf '%s\n' "fio --name=kernel-measure --filename=$file --rw=randrw --bs=4k --size=${STORAGE_MB}M --runtime=${DURATION} --time_based=1 --direct=0" > "$RUN_DIR/command.txt"
  run_fio 0
  echo buffered > "$RUN_DIR/storage_mode.txt"
  exit 0
fi

note "fio not installed; using dd fallback"
dd_write() {
  local mode=$1
  local -a args=(if=/dev/zero "of=$file" bs=1M "count=$STORAGE_MB" conv=fsync)
  if [[ "$mode" == direct ]]; then
    args+=(oflag=direct)
  fi
  if dd "${args[@]}" status=none 2>>"$RUN_DIR/storage_notes.txt"; then
    return 0
  fi
  dd "${args[@]}"
}

printf '%s\n' "dd if=/dev/zero of=$file bs=1M count=${STORAGE_MB} oflag=direct conv=fsync && dd if=$file of=/dev/null bs=1M iflag=direct" > "$RUN_DIR/command.txt"
if dd_write direct; then
  if ! dd if="$file" of=/dev/null bs=1M iflag=direct status=none 2>>"$RUN_DIR/storage_notes.txt"; then
    dd if="$file" of=/dev/null bs=1M status=none || dd if="$file" of=/dev/null bs=1M
  fi
  echo direct > "$RUN_DIR/storage_mode.txt"
else
  note "dd oflag=direct failed; retrying buffered IO"
  rm -f "$file"
  printf '%s\n' "dd if=/dev/zero of=$file bs=1M count=${STORAGE_MB} conv=fsync && dd if=$file of=/dev/null bs=1M" > "$RUN_DIR/command.txt"
  dd_write buffered
  if ! dd if="$file" of=/dev/null bs=1M status=none; then
    dd if="$file" of=/dev/null bs=1M
  fi
  echo buffered > "$RUN_DIR/storage_mode.txt"
fi
