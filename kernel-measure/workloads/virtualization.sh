#!/usr/bin/env bash
# Presence check only. Never launches a VM.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
RUN_DIR=${RUN_DIR:-.}
VIRT_LAUNCH=${VIRT_LAUNCH:-never}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  printf '%s\n' "$2" > "$RUN_DIR/command.txt"
  echo "SKIP: $1" >&2
  exit 2
}

shopt -s nullglob
bins=()
IFS=':' read -ra dirs <<< "${PATH}"
for d in "${dirs[@]}"; do
  [[ -d "$d" ]] || continue
  for b in "$d"/qemu-system-*; do
    [[ -x "$b" && -f "$b" ]] || continue
    bins+=("$b")
  done
done

if ((${#bins[@]} == 0)); then
  skip "qemu-system is not installed" "qemu-system not installed; VM not launched"
fi

bin=${bins[0]}
ver=$("$bin" --version 2>&1 | head -n 1 || true)
skip "qemu-system is present (${ver:-$bin}) but this harness does not launch a VM (VIRT_LAUNCH=${VIRT_LAUNCH})" "$bin --version (VM not launched)"
