#!/bin/sh
set -e
cd /home/kernelmaster/kernel-measure
echo "uname=$(uname -r)" | tee /tmp/t11-stock-meta.txt
test "$(uname -r)" = "7.2.9-baseline" || { echo "ERROR: expected 7.2.9-baseline, got $(uname -r)"; exit 1; }
: > /tmp/t11-stock-measure.log

# Ensure debugfs + UTIL_EST ON for stock arm
sudo -n mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
sudo -n sh -c 'echo UTIL_EST > /sys/kernel/debug/sched/features'
{
  echo "=== sched features (UTIL*) at measure start ==="
  sudo -n cat /sys/kernel/debug/sched/features | tr ' ' '\n' | grep -E 'UTIL|SIS_'
  echo "=== topology ==="
  lscpu | grep -E 'Model name|CPU\(s\)|Socket|NUMA|L3'
} | tee -a /tmp/t11-stock-measure.log /tmp/t11-stock-meta.txt

bash workloads/util_est_burst.sh --prepare 2>&1 | tee -a /tmp/t11-stock-measure.log
bash workloads/wake_llc.sh --prepare 2>&1 | tee -a /tmp/t11-stock-measure.log || true

echo "=== STOCK UTIL_EST=ON (3x) ===" | tee -a /tmp/t11-stock-measure.log
for i in 1 2 3; do
  echo "=== stock ON collect $i $(date -u +%Y%m%dT%H%M%SZ) ===" | tee -a /tmp/t11-stock-measure.log
  ./collect.sh --task 11 --schedstats 2>&1 | tee -a /tmp/t11-stock-measure.log
done
first=$(ls -dt runs/*-task11 2>/dev/null | head -3 | sort | head -1)
ln -sfn "$(basename "$first")" runs/BASELINE-task11
echo "BASELINE-task11 -> $(readlink runs/BASELINE-task11)" | tee -a /tmp/t11-stock-measure.log

# Snapshot the three ON run names
ls -dt runs/*-task11 | head -3 | tee /tmp/t11-on-runs.txt | tee -a /tmp/t11-stock-measure.log

echo "=== STOCK UTIL_EST=OFF (3x) same kernel ===" | tee -a /tmp/t11-stock-measure.log
sudo -n sh -c 'echo NO_UTIL_EST > /sys/kernel/debug/sched/features'
sudo -n cat /sys/kernel/debug/sched/features | tr ' ' '\n' | grep UTIL | tee -a /tmp/t11-stock-measure.log
for i in 1 2 3; do
  echo "=== stock OFF collect $i $(date -u +%Y%m%dT%H%M%SZ) ===" | tee -a /tmp/t11-stock-measure.log
  ./collect.sh --task 11 --schedstats 2>&1 | tee -a /tmp/t11-stock-measure.log
done
# Point NOUTIL-task11 at earliest of the latest 3 (OFF) runs — the ones not in ON list
# Safer: take the 3 newest after OFF loop
off_runs=$(ls -dt runs/*-task11 | head -3)
first_off=$(echo "$off_runs" | sort | head -1)
ln -sfn "$(basename "$first_off")" runs/NOUTIL-task11
echo "NOUTIL-task11 -> $(readlink runs/NOUTIL-task11)" | tee -a /tmp/t11-stock-measure.log
echo "$off_runs" | tee /tmp/t11-off-runs.txt | tee -a /tmp/t11-stock-measure.log

# Restore UTIL_EST ON
sudo -n sh -c 'echo UTIL_EST > /sys/kernel/debug/sched/features'
sudo -n cat /sys/kernel/debug/sched/features | tr ' ' '\n' | grep UTIL | tee -a /tmp/t11-stock-measure.log

ln -sfn "$(basename "$(ls -dt runs/*-task11 | head -1)")" runs/LAST_TASK11
ls -dt runs/*-task11 | head -8 | tee -a /tmp/t11-stock-measure.log
echo DONE | tee -a /tmp/t11-stock-measure.log
