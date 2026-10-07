#!/bin/sh
# Measure Task 12 DEFER arm on 7.2.9-baseline with
#   threadirqs rcu_nocbs=0-11 rcutree.use_softirq=0
set -e
cd /home/kernelmaster/kernel-measure
echo "uname=$(uname -r)" | tee /tmp/t12-defer-meta.txt
test "$(uname -r)" = "7.2.9-baseline" || { echo "ERROR: expected 7.2.9-baseline, got $(uname -r)"; exit 1; }
: > /tmp/t12-defer-measure.log

cmdline=$(cat /proc/cmdline)
echo "cmdline=$cmdline" | tee -a /tmp/t12-defer-measure.log /tmp/t12-defer-meta.txt
echo "$cmdline" | grep -qw threadirqs || { echo "ERROR: threadirqs missing from cmdline"; exit 1; }
echo "$cmdline" | grep -q 'rcu_nocbs=0-11' || { echo "ERROR: rcu_nocbs=0-11 missing"; exit 1; }
echo "$cmdline" | grep -q 'rcutree.use_softirq=0' || { echo "ERROR: rcutree.use_softirq=0 missing"; exit 1; }

{
  echo "=== rcutree.use_softirq ==="
  cat /sys/module/rcutree/parameters/use_softirq 2>/dev/null || true
  echo "=== rcuo count ==="
  ps -eLo comm | grep -c '^rcuo' || true
  echo "=== irq threads sample ==="
  ps -eLo comm | grep -E '^irq/|^ksoftirqd' | head -20
} | tee -a /tmp/t12-defer-measure.log /tmp/t12-defer-meta.txt

bash workloads/softirq_storm.sh --prepare 2>&1 | tee -a /tmp/t12-defer-measure.log

echo "=== DEFER (3x) ===" | tee -a /tmp/t12-defer-measure.log
for i in 1 2 3; do
  echo "=== defer collect $i $(date -u +%Y%m%dT%H%M%SZ) ===" | tee -a /tmp/t12-defer-measure.log
  ./collect.sh --task 12 --schedstats 2>&1 | tee -a /tmp/t12-defer-measure.log
done

ls -dt runs/*-task12 | head -3 | tee /tmp/t12-defer-runs.txt | tee -a /tmp/t12-defer-measure.log
first=$(ls -dt runs/*-task12 | head -3 | sort | head -1)
ln -sfn "$(basename "$first")" runs/DEFER-task12
{
  echo "# DEFER arm Task 12 — threadirqs rcu_nocbs=0-11 rcutree.use_softirq=0"
  echo "# recorded $(date -u +%Y-%m-%dT%H:%M:%SZ) uname=$(uname -r)"
  cat /tmp/t12-defer-runs.txt
} > runs/DEFER-task12-SETS.txt
echo "DEFER-task12 -> $(readlink runs/DEFER-task12)" | tee -a /tmp/t12-defer-measure.log
echo DONE_DEFER | tee -a /tmp/t12-defer-measure.log
