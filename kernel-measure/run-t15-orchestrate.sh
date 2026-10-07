#!/bin/sh
# Task 15: boot baseline, 3x collect --task 15, restore 7.2.9-t9.
set -e
STATE_FILE=/home/kernelmaster/t15-state
LOG=/tmp/t15-orchestrate.log
META=/tmp/t15-orchestrate-meta.txt
ENTRY_BASE='Advanced options for Ubuntu>Ubuntu, with Linux 7.2.9-baseline'
ENTRY_T9='Advanced options for Ubuntu>Ubuntu, with Linux 7.2.9-t9'
KM=/home/kernelmaster/kernel-measure

uname_r=$(uname -r)
echo "orchestrate start uname=$uname_r state=$(cat $STATE_FILE 2>/dev/null || echo none) $(date -u +%Y%m%dT%H%M%SZ)" | tee -a "$LOG" "$META"

state=$(cat "$STATE_FILE" 2>/dev/null || echo need_baseline_boot)

install_cron() {
  crontab -l 2>/dev/null | grep -v t15-orchestrate > /tmp/t15-cron || true
  echo "@reboot sleep 45; /home/kernelmaster/kernel-measure/run-t15-orchestrate.sh >> /tmp/t15-orchestrate.log 2>&1" >> /tmp/t15-cron
  crontab /tmp/t15-cron
}

clear_cron() {
  crontab -l 2>/dev/null | grep -v t15-orchestrate > /tmp/t15-cron || true
  crontab /tmp/t15-cron 2>/dev/null || true
}

case "$state" in
  need_baseline_boot)
    echo "arming baseline boot" | tee -a "$LOG"
    sudo -n grub-reboot "$ENTRY_BASE"
    echo do_measure > "$STATE_FILE"
    install_cron
    sync
    sudo -n reboot
    ;;
  do_measure)
    echo "measuring on $uname_r" | tee -a "$LOG"
    if [ "$uname_r" != "7.2.9-baseline" ]; then
      echo "ERROR: expected baseline, got $uname_r" | tee -a "$LOG"
      echo need_restore > "$STATE_FILE"
      sudo -n grub-reboot "$ENTRY_T9"
      install_cron
      sudo -n reboot
      exit 1
    fi
    cd "$KM"
    # prepare binary
    DURATION=1 RUN_DIR=/tmp/t15-prep ./workloads/folio_wait.sh --prepare >> "$LOG" 2>&1 || true
    SETS=""
    i=1
    while [ "$i" -le 3 ]; do
      echo "=== collect task15 run $i $(date -u +%Y%m%dT%H%M%SZ) ===" | tee -a "$LOG"
      ./collect.sh --task 15 --schedstats >> "$LOG" 2>&1
      last=$(cat runs/LAST_TASK15)
      SETS="$SETS $last"
      echo "RUN $i -> $last" | tee -a "$LOG"
      i=$((i+1))
    done
    # Link BASELINE-task15 to first; write SETS file
    first=$(echo $SETS | awk '{print $1}')
    ln -sfn "$(basename "$first")" runs/BASELINE-task15
    echo "$SETS" > runs/BASELINE-task15-SETS.txt
    # Also one HIGH and one LOW collide contrast (single each, labeled)
    echo "=== HIGHCOLL contrast ===" | tee -a "$LOG"
    FOLIOWAIT_NFILES=1024 ./collect.sh --task 15 --schedstats >> "$LOG" 2>&1 || true
    high=$(cat runs/LAST_TASK15)
    ln -sfn "$(basename "$high")" runs/HIGHCOLL-task15
    echo "=== LOWCOLL contrast ===" | tee -a "$LOG"
    FOLIOWAIT_NFILES=12 ./collect.sh --task 15 --schedstats >> "$LOG" 2>&1 || true
    low=$(cat runs/LAST_TASK15)
    ln -sfn "$(basename "$low")" runs/LOWCOLL-task15
    printf '%s\n' "$SETS" > /tmp/t15-sets.txt
    echo "high=$high" >> /tmp/t15-sets.txt
    echo "low=$low" >> /tmp/t15-sets.txt
    echo need_restore > "$STATE_FILE"
    sudo -n grub-reboot "$ENTRY_T9"
    install_cron
    sync
    sudo -n reboot
    ;;
  need_restore)
    echo "restore check uname=$uname_r" | tee -a "$LOG"
    clear_cron
    if [ "$uname_r" = "7.2.9-t9" ]; then
      echo done > "$STATE_FILE"
      echo "DONE on t9 $(date -u +%Y%m%dT%H%M%SZ)" | tee -a "$LOG" "$META"
    else
      echo "not t9 yet, re-arm" | tee -a "$LOG"
      sudo -n grub-reboot "$ENTRY_T9"
      echo need_restore > "$STATE_FILE"
      install_cron
      sudo -n reboot
    fi
    ;;
  done)
    echo "already done" | tee -a "$LOG"
    clear_cron
    ;;
  *)
    echo "unknown state $state" | tee -a "$LOG"
    ;;
esac
