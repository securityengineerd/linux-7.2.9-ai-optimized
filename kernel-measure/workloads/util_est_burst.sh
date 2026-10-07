#!/usr/bin/env bash
# kernel-measure: prepare
# Task 11 util_est burst: on/off CPU tasks so PELT util_avg decays during
# sleep while util_est EWMA holds a higher estimate for wake placement.
#
# Engines (UTIL_EST_ENGINE=auto tries them in this order):
#   c          build/util_est_burst from workloads/src/util_est_burst.c
#   stress-ng  stress-ng --cpu + --timer mix (no burst/migrate wl_* metrics)
# Compare only runs with the same engine and arguments.
# Records sched UTIL_EST feature state into workload.metrics when readable.
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
UTIL_EST_ENGINE=${UTIL_EST_ENGINE:-auto}
UTIL_EST_NBURST=${UTIL_EST_NBURST:-0}
UTIL_EST_NHOG=${UTIL_EST_NHOG:--1}
UTIL_EST_ON_US=${UTIL_EST_ON_US:-5000}
UTIL_EST_OFF_US=${UTIL_EST_OFF_US:-80000}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

record_util_est_feat() {
  local f="/sys/kernel/debug/sched/features" feat="unknown"
  if [[ -r "$f" ]]; then
    if grep -qw UTIL_EST "$f" 2>/dev/null; then
      feat=on
    elif grep -qw NO_UTIL_EST "$f" 2>/dev/null; then
      feat=off
    fi
  elif sudo -n test -r "$f" 2>/dev/null; then
    local txt
    txt=$(sudo -n cat "$f" 2>/dev/null || true)
    if echo "$txt" | grep -qw UTIL_EST; then
      feat=on
    elif echo "$txt" | grep -qw NO_UTIL_EST; then
      feat=off
    fi
  fi
  echo "wl_sched_feat_util_est=$feat" >> "$RUN_DIR/workload.metrics"
}

if [[ "${1:-}" == "--prepare" ]]; then
  if [[ "$UTIL_EST_ENGINE" == auto || "$UTIL_EST_ENGINE" == c ]]; then
    if build_tool util_est_burst >/dev/null; then
      record_build util_est_burst "$RUN_DIR"
      echo "prepared build/util_est_burst"
    else
      echo "could not build util_est_burst (no C compiler or build failed)"
    fi
  fi
  exit 0
fi

nproc_n=$(nproc)
nburst=$UTIL_EST_NBURST
nhog=$UTIL_EST_NHOG
if [[ "$nburst" -eq 0 ]]; then
  nburst=$nproc_n
fi
if [[ "$nhog" -eq -1 ]]; then
  nhog=$((nproc_n / 3))
  if [[ "$nhog" -lt 1 ]]; then
    nhog=1
  fi
fi

bin="$HARNESS_DIR/build/util_est_burst"
if [[ "$UTIL_EST_ENGINE" == auto || "$UTIL_EST_ENGINE" == c ]] && [[ -x "$bin" ]]; then
  : > "$RUN_DIR/workload.metrics"
  record_util_est_feat
  printf 'build/util_est_burst -d %s -b %s -h %s -o %s -f %s (nproc=%s)\n' \
    "$DURATION" "$nburst" "$nhog" "$UTIL_EST_ON_US" "$UTIL_EST_OFF_US" "$nproc_n" \
    > "$RUN_DIR/command.txt"
  # binary writes metrics with -O; append after so feat line stays
  tmpm="$RUN_DIR/workload.metrics.burst"
  "$bin" -d "$DURATION" -b "$nburst" -h "$nhog" -o "$UTIL_EST_ON_US" -f "$UTIL_EST_OFF_US" -O "$tmpm"
  # merge: feat first, then burst metrics (skip duplicate keys from burst if any)
  {
    cat "$RUN_DIR/workload.metrics"
    cat "$tmpm"
  } > "$RUN_DIR/workload.metrics.merged"
  mv -f "$RUN_DIR/workload.metrics.merged" "$RUN_DIR/workload.metrics"
  rm -f "$tmpm"
  exit 0
fi
if [[ "$UTIL_EST_ENGINE" == c ]]; then
  skip "UTIL_EST_ENGINE=c but build/util_est_burst is missing (no C compiler?)"
fi

if [[ "$UTIL_EST_ENGINE" == auto || "$UTIL_EST_ENGINE" == stress-ng ]] && command -v stress-ng >/dev/null 2>&1; then
  n=$nproc_n
  cmd=(stress-ng --cpu "$n" --timeout "${DURATION}s")
  if stress-ng --help 2>&1 | grep -q -- '--metrics-brief'; then
    cmd+=(--metrics-brief)
  fi
  printf '%s ' "${cmd[@]}" > "$RUN_DIR/command.txt"
  printf '\n' >> "$RUN_DIR/command.txt"
  echo "wl_engine=stress-ng-cpu" > "$RUN_DIR/workload.metrics"
  record_util_est_feat
  "${cmd[@]}"
  exit 0
fi

skip "no util_est_burst engine: need a C compiler (build/util_est_burst) or stress-ng"
