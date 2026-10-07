#!/bin/sh
# Measure Task 12 STOCK arm on 7.2.9-baseline (no deferral knobs).
set -e
cd /home/kernelmaster/kernel-measure
echo "uname=$(uname -r)" | tee /tmp/t12-stock-meta.txt
test "$(uname -r)" = "7.2.9-baseline" || { echo "ERROR: expected 7.2.9-baseline, got $(uname -r)"; exit 1; }
: > /tmp/t12-stock-measure.log

{
  echo "=== cmdline ==="
  cat /proc/cmdline
  echo "=== rcutree.use_softirq ==="
  cat /sys/module/rcutree/parameters/use_softirq 2>/dev/null || true
  echo "=== rcuo count ==="
  ps -eLo comm | grep -c '^rcuo' || true
  echo "=== topology ==="
  lscpu | grep -E 'Model name|CPU\(s\)|Socket|NUMA|L3'
} | tee -a /tmp/t12-stock-measure.log /tmp/t12-stock-meta.txt

bash workloads/softirq_storm.sh --prepare 2>&1 | tee -a /tmp/t12-stock-measure.log

echo "=== STOCK (3x) ===" | tee -a /tmp/t12-stock-measure.log
for i in 1 2 3; do
  echo "=== stock collect $i $(date -u +%Y%m%dT%H%M%SZ) ===" | tee -a /tmp/t12-stock-measure.log
  ./collect.sh --task 12 --schedstats 2>&1 | tee -a /tmp/t12-stock-measure.log
done

# Record the three newest task12 runs as STOCK set
ls -dt runs/*-task12 | head -3 | tee /tmp/t12-stock-runs.txt | tee -a /tmp/t12-stock-measure.log
first=$(ls -dt runs/*-task12 | head -3 | sort | head -1)
ln -sfn "$(basename "$first")" runs/BASELINE-task12
{
  echo "# STOCK arm Task 12 — no threadirqs / no rcu_nocbs / use_softirq=Y"
  echo "# recorded $(date -u +%Y-%m-%dT%H:%M:%SZ) uname=$(uname -r)"
  cat /tmp/t12-stock-runs.txt
} > runs/BASELINE-task12-SETS.txt
echo "BASELINE-task12 -> $(readlink runs/BASELINE-task12)" | tee -a /tmp/t12-stock-measure.log
echo DONE_STOCK | tee -a /tmp/t12-stock-measure.log
