#!/usr/bin/env bash
# Run every workload once and point runs/BASELINE at that set.
set -euo pipefail
HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HARNESS_DIR/lib/common.sh"

RUNS_DIR="$HARNESS_DIR/runs"
FORCE=0
TASK_ID=""
extra=()

usage() {
  cat <<USAGE
Usage: baseline.sh [--task N] [--force] [--schedstats] [--config FILE] [--runs-dir DIR]

Runs collect.sh --all once. On success, writes runs/BASELINE as a relative
symlink to that set directory.

With --task N it runs collect.sh --task N instead and writes
runs/BASELINE-taskN. Run that on the STOCK kernel first; the patched boot is
collected later with collect.sh --task N and compared against it.

No implementation task starts until runs/BASELINE exists. This script does
not install or boot a kernel. It refuses to run unless uname -s is Linux.

  --task N     baseline only task N's workloads (runs/BASELINE-taskN)
  --force      replace an existing baseline symlink (old runs are kept)
  --schedstats passed through to collect.sh (enable sched_schedstats for the run)
  --config     passed through to collect.sh
  --runs-dir   passed through to collect.sh
  -h, --help   show this help and exit
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --task)
      [[ $# -ge 2 ]] || die "--task needs a task id"
      TASK_ID=$2
      shift 2
      ;;
    --schedstats)
      extra+=(--schedstats)
      shift
      ;;
    --config)
      [[ $# -ge 2 ]] || die "--config needs a path"
      extra+=(--config "$2")
      shift 2
      ;;
    --runs-dir)
      [[ $# -ge 2 ]] || die "--runs-dir needs a path"
      RUNS_DIR=$2
      extra+=(--runs-dir "$2")
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_linux
mkdir -p "$RUNS_DIR"
link="$RUNS_DIR/BASELINE"
mode_args=(--all)
if [[ -n "$TASK_ID" ]]; then
  task_line "$TASK_ID" >/dev/null || die "task ${TASK_ID} is not in ${TASKS_CONF}"
  link="$RUNS_DIR/BASELINE-task${TASK_ID}"
  mode_args=(--task "$TASK_ID")
fi
if [[ -L "$link" || -e "$link" ]]; then
  if [[ ! -L "$link" ]]; then
    die "$(basename "$link") exists and is not a symlink; refusing to replace it"
  fi
  if (( FORCE == 0 )); then
    echo "error: baseline already exists: $link -> $(readlink "$link")" >&2
    echo "refusing to replace it. Re-run with --force to move the pointer. Old run directories are kept." >&2
    exit 1
  fi
fi

set +e
if ((${#extra[@]})); then
  out=$("$HARNESS_DIR/collect.sh" "${mode_args[@]}" "${extra[@]}")
else
  out=$("$HARNESS_DIR/collect.sh" "${mode_args[@]}")
fi
rc=$?
set -e
printf '%s\n' "$out"
if [[ "$rc" -ne 0 ]]; then
  echo "error: collect ${mode_args[*]} failed (status ${rc}); $(basename "$link") was not updated" >&2
  exit "$rc"
fi

setdir=$(printf '%s\n' "$out" | grep -E '^RUN_SET=' | tail -n 1 | cut -d= -f2- || true)
if [[ -z "$setdir" || ! -d "$setdir" ]]; then
  last="$RUNS_DIR/LAST_SET"
  if [[ -n "$TASK_ID" ]]; then
    last="$RUNS_DIR/LAST_TASK${TASK_ID}"
  fi
  if [[ -f "$last" ]]; then
    setdir=$(cat "$last")
  fi
fi
if [[ -z "$setdir" || ! -d "$setdir" ]]; then
  die "collect succeeded but the set directory could not be found"
fi
if [[ "$(cd "$RUNS_DIR" && pwd)" != "$(cd "$(dirname "$setdir")" && pwd)" ]]; then
  die "set directory ${setdir} is not inside ${RUNS_DIR}"
fi
ln -sfn "$(basename "$setdir")" "$link"
echo "$(basename "$link") -> $(basename "$setdir") (kernel $(uname -r))"
