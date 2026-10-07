#!/bin/sh
set -e
cd /home/kernelmaster/kernel-measure
echo "uname=$(uname -r)" | tee /tmp/t6-stock-meta.txt
test "$(uname -r)" = "7.2.9-baseline" || { echo "ERROR: expected 7.2.9-baseline, got $(uname -r)"; exit 1; }
: > /tmp/t6-stock-measure.log
# Record THP policy
{
  echo "=== THP policy at measure start ==="
  cat /sys/kernel/mm/transparent_hugepage/enabled
  for d in /sys/kernel/mm/transparent_hugepage/hugepages-*; do
    echo -n "$(basename $d) enabled: "
    cat "$d/enabled" 2>/dev/null || true
  done
} | tee -a /tmp/t6-stock-measure.log /tmp/t6-stock-meta.txt
bash workloads/anon_fault.sh --prepare 2>&1 | tee -a /tmp/t6-stock-measure.log
for i in 1 2 3; do
  echo "=== stock collect $i $(date -u +%Y%m%dT%H%M%SZ) ===" | tee -a /tmp/t6-stock-measure.log
  ./collect.sh --task 6 --schedstats 2>&1 | tee -a /tmp/t6-stock-measure.log
done
# Point BASELINE-task6 at the earliest of the last 3 task6 runs
first=$(ls -dt runs/*-task6 2>/dev/null | head -3 | sort | head -1)
ln -sfn "$(basename "$first")" runs/BASELINE-task6
ln -sfn "$(basename "$(ls -dt runs/*-task6 | head -1)")" runs/LAST_TASK6
echo "BASELINE-task6 -> $(readlink runs/BASELINE-task6)" | tee -a /tmp/t6-stock-measure.log
ls -dt runs/*-task6 | head -5 | tee -a /tmp/t6-stock-measure.log
echo DONE | tee -a /tmp/t6-stock-measure.log
