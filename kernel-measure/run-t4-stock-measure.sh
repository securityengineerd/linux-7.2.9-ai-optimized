#!/bin/sh
set -e
cd /home/kernelmaster/kernel-measure
echo "uname=$(uname -r)" | tee /tmp/t4-stock-meta.txt
test "$(uname -r)" = "7.2.9-baseline" || { echo "ERROR: expected 7.2.9-baseline, got $(uname -r)"; exit 1; }
: > /tmp/t4-stock-measure.log
for i in 1 2 3; do
  echo "=== stock collect $i ===" | tee -a /tmp/t4-stock-measure.log
  ./collect.sh --task 4 --schedstats 2>&1 | tee -a /tmp/t4-stock-measure.log
done
first=$(ls -dt runs/*-task4 2>/dev/null | head -3 | sort | head -1)
ln -sfn "$(basename "$first")" runs/BASELINE-task4
echo "BASELINE-task4 -> $(readlink runs/BASELINE-task4)" | tee -a /tmp/t4-stock-measure.log
ls -dt runs/*-task4 | head -5
echo DONE | tee -a /tmp/t4-stock-measure.log
