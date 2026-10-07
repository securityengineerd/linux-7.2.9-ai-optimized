#!/bin/sh
set -e
cd /home/kernelmaster/kernel-measure
echo "uname=$(uname -r)" | tee /tmp/t5-stock-meta.txt
test "$(uname -r)" = "7.2.9-baseline" || { echo "ERROR: expected 7.2.9-baseline, got $(uname -r)"; exit 1; }
: > /tmp/t5-stock-measure.log
# prepare once outside the loop
bash workloads/hot_read.sh --prepare 2>&1 | tee -a /tmp/t5-stock-measure.log
for i in 1 2 3; do
  echo "=== stock collect $i $(date -u +%Y%m%dT%H%M%SZ) ===" | tee -a /tmp/t5-stock-measure.log
  ./collect.sh --task 5 --schedstats 2>&1 | tee -a /tmp/t5-stock-measure.log
done
first=$(ls -dt runs/*-task5 2>/dev/null | head -3 | sort | head -1)
ln -sfn "$(basename "$first")" runs/BASELINE-task5
echo "BASELINE-task5 -> $(readlink runs/BASELINE-task5)" | tee -a /tmp/t5-stock-measure.log
ls -dt runs/*-task5 | head -5 | tee -a /tmp/t5-stock-measure.log
echo DONE | tee -a /tmp/t5-stock-measure.log
