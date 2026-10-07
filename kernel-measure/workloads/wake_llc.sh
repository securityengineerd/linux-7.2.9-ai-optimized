#!/usr/bin/env bash
# kernel-measure: prepare
# Task 1 wake storm: many short-lived wakes landing on every CPU so
# select_idle_sibling / select_idle_cpu runs on nearly every wakeup.
#
# Engines (WAKE_LLC_ENGINE=auto tries them in this order):
#   c          build/wake_storm from workloads/src/wake_storm.c. Two phases:
#              "idle" (storm only) then "busy" (storm + nproc/2 spinners).
#              Reports wake-to-run latency percentiles, CPU-change and
#              on-waker-CPU rates into workload.metrics.
#   stress-ng  stress-ng --switch $(nproc) --timeout ${DURATION}s
#              No per-wake latency; perf + schedstat only.
# Compare only runs with the same engine and arguments.
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
WAKE_LLC_ENGINE=${WAKE_LLC_ENGINE:-auto}
WAKE_LLC_MESSENGERS=${WAKE_LLC_MESSENGERS:-2}
WAKE_LLC_WORKERS=${WAKE_LLC_WORKERS:-0}
WAKE_LLC_SPINNERS=${WAKE_LLC_SPINNERS:--1}
WAKE_LLC_PERIOD_US=${WAKE_LLC_PERIOD_US:-1000}
WAKE_LLC_BUSY_US=${WAKE_LLC_BUSY_US:-20}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

if [[ "${1:-}" == "--prepare" ]]; then
  # Runs outside perf stat. Building here keeps compiler cycles out of the run.
  if [[ "$WAKE_LLC_ENGINE" == auto || "$WAKE_LLC_ENGINE" == c ]]; then
    if build_tool wake_storm >/dev/null; then
      record_build wake_storm "$RUN_DIR"
      echo "prepared build/wake_storm"
    else
      echo "could not build wake_storm (no C compiler or build failed)"
    fi
  fi
  exit 0
fi

bin="$HARNESS_DIR/build/wake_storm"
if [[ "$WAKE_LLC_ENGINE" == auto || "$WAKE_LLC_ENGINE" == c ]] && [[ -x "$bin" ]]; then
  cmd=("$bin" -d "$DURATION" -m "$WAKE_LLC_MESSENGERS" -w "$WAKE_LLC_WORKERS" -s "$WAKE_LLC_SPINNERS"
       -p "$WAKE_LLC_PERIOD_US" -b "$WAKE_LLC_BUSY_US" -o "$RUN_DIR/workload.metrics")
  printf 'build/wake_storm -d %s -m %s -w %s -s %s -p %s -b %s (nproc=%s)\n' "$DURATION" "$WAKE_LLC_MESSENGERS" \
    "$WAKE_LLC_WORKERS" "$WAKE_LLC_SPINNERS" "$WAKE_LLC_PERIOD_US" "$WAKE_LLC_BUSY_US" "$(nproc)" > "$RUN_DIR/command.txt"
  exec "${cmd[@]}"
fi
if [[ "$WAKE_LLC_ENGINE" == c ]]; then
  skip "WAKE_LLC_ENGINE=c but build/wake_storm is missing (no C compiler?)"
fi

if [[ "$WAKE_LLC_ENGINE" == auto || "$WAKE_LLC_ENGINE" == stress-ng ]] && command -v stress-ng >/dev/null 2>&1; then
  n=$(nproc)
  cmd=(stress-ng --switch "$n" --timeout "${DURATION}s")
  if stress-ng --help 2>&1 | grep -q -- '--metrics-brief'; then
    cmd+=(--metrics-brief)
  fi
  printf '%s ' "${cmd[@]}" > "$RUN_DIR/command.txt"
  printf '\n' >> "$RUN_DIR/command.txt"
  echo "wl_engine=stress-ng-switch" > "$RUN_DIR/workload.metrics"
  "${cmd[@]}"
  exit 0
fi

skip "no wake_llc engine: need a C compiler (build/wake_storm) or stress-ng"
