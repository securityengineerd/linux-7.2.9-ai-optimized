#!/bin/sh
# State machine for Task 12 A/B across reboots.
# States in /home/kernelmaster/t12-state:
#   need_stock_boot | do_stock | need_defer_boot | do_defer | need_restore | done
set -e
STATE_FILE=/home/kernelmaster/t12-state
LOG=/tmp/t12-orchestrate.log
META=/tmp/t12-orchestrate-meta.txt
ENTRY_BASE='Advanced options for Ubuntu>Ubuntu, with Linux 7.2.9-baseline'
ENTRY_T9='Advanced options for Ubuntu>Ubuntu, with Linux 7.2.9-t9'
GRUB_DEFAULT=/etc/default/grub
GRUB_BAK=/home/kernelmaster/t12-grub.default.bak
DEFER_PARAMS='threadirqs rcu_nocbs=0-11 rcutree.use_softirq=0'

uname_r=$(uname -r)
echo "orchestrate start uname=$uname_r state=$(cat $STATE_FILE 2>/dev/null || echo none) $(date -u +%Y%m%dT%H%M%SZ)" | tee -a "$LOG" "$META"

state=$(cat "$STATE_FILE" 2>/dev/null || echo need_stock_boot)

install_cron() {
  crontab -l 2>/dev/null | grep -v t12-orchestrate > /tmp/t12-cron || true
  echo "@reboot sleep 45; /home/kernelmaster/kernel-measure/run-t12-orchestrate.sh >> /tmp/t12-orchestrate.log 2>&1" >> /tmp/t12-cron
  crontab /tmp/t12-cron
}

clear_cron() {
  crontab -l 2>/dev/null | grep -v t12-orchestrate > /tmp/t12-cron || true
  crontab /tmp/t12-cron 2>/dev/null || true
}

restore_grub_cmdline() {
  if [ -f "$GRUB_BAK" ]; then
    sudo -n cp -f "$GRUB_BAK" "$GRUB_DEFAULT"
    sudo -n update-grub
    echo "grub restored from bak" | tee -a "$LOG"
  fi
}

apply_defer_cmdline() {
  if [ ! -f "$GRUB_BAK" ]; then
    sudo -n cp -f "$GRUB_DEFAULT" "$GRUB_BAK"
  fi
  # Ensure DEFER params are in GRUB_CMDLINE_LINUX
  sudo -n cp -f "$GRUB_BAK" "$GRUB_DEFAULT"
  # Append defer params if not present
  if ! grep -q 'rcu_nocbs=0-11' "$GRUB_DEFAULT"; then
    sudo -n sed -i "s/^GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1 ${DEFER_PARAMS}\"/" "$GRUB_DEFAULT"
  fi
  sudo -n update-grub
  echo "grub defer cmdline applied:" | tee -a "$LOG"
  grep GRUB_CMDLINE_LINUX "$GRUB_DEFAULT" | tee -a "$LOG"
}

case "$state" in
  need_stock_boot)
    echo "arming baseline stock boot" | tee -a "$LOG"
    restore_grub_cmdline || true
    # Ensure bak exists of clean grub
    if [ ! -f "$GRUB_BAK" ]; then
      sudo -n cp -f "$GRUB_DEFAULT" "$GRUB_BAK"
    else
      sudo -n cp -f "$GRUB_BAK" "$GRUB_DEFAULT"
      sudo -n update-grub
    fi
    echo do_stock > "$STATE_FILE"
    install_cron
    sudo -n grub-editenv /boot/grub/grubenv set next_entry="$ENTRY_BASE"
    sudo -n grub-editenv list | tee -a "$LOG"
    sudo -n reboot
    ;;
  do_stock)
    if [ "$uname_r" != "7.2.9-baseline" ]; then
      echo "ERROR: do_stock but uname=$uname_r" | tee -a "$LOG"
      exit 1
    fi
    # Confirm no defer params
    if grep -Ewq 'threadirqs|rcu_nocbs' /proc/cmdline; then
      echo "ERROR: stock boot still has defer params: $(cat /proc/cmdline)" | tee -a "$LOG"
      exit 1
    fi
    /home/kernelmaster/kernel-measure/run-t12-stock-measure.sh
    apply_defer_cmdline
    echo do_defer > "$STATE_FILE"
    install_cron
    sudo -n grub-editenv /boot/grub/grubenv set next_entry="$ENTRY_BASE"
    sudo -n reboot
    ;;
  need_defer_boot)
    # Legacy alias: apply defer cmdline and continue as do_defer after reboot
    apply_defer_cmdline
    echo do_defer > "$STATE_FILE"
    install_cron
    sudo -n grub-editenv /boot/grub/grubenv set next_entry="$ENTRY_BASE"
    sudo -n reboot
    ;;
  do_defer)
    if [ "$uname_r" != "7.2.9-baseline" ]; then
      echo "ERROR: do_defer but uname=$uname_r" | tee -a "$LOG"
      exit 1
    fi
    /home/kernelmaster/kernel-measure/run-t12-defer-measure.sh
    echo need_restore > "$STATE_FILE"
    restore_grub_cmdline
    install_cron
    sudo -n grub-editenv /boot/grub/grubenv set next_entry="$ENTRY_T9"
    sudo -n reboot
    ;;
  need_restore)
    # After restore reboot we should be on t9 without defer params
    restore_grub_cmdline || true
    clear_cron
    echo done > "$STATE_FILE"
    {
      echo "DONE Task12 orchestrate $(date -u +%Y%m%dT%H%M%SZ)"
      echo "uname=$(uname -r)"
      echo "cmdline=$(cat /proc/cmdline)"
    } | tee -a "$LOG" "$META"
    ;;
  done)
    echo "already done" | tee -a "$LOG"
    clear_cron
    ;;
  *)
    echo "unknown state=$state" | tee -a "$LOG"
    exit 1
    ;;
esac
