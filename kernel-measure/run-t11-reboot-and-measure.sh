#!/bin/sh
# One-shot: if not on baseline, set next boot to baseline and reboot.
# After reboot on baseline, run stock measure, then set next boot to t9 and reboot.
set -e
LOG=/tmp/t11-reboot-measure.log
META=/tmp/t11-reboot-meta.txt
ENTRY_BASE='Advanced options for Ubuntu>Ubuntu, with Linux 7.2.9-baseline'
ENTRY_T9='Advanced options for Ubuntu>Ubuntu, with Linux 7.2.9-t9'
MARKER=/tmp/t11-measure-pending

uname_r=$(uname -r)
echo "start uname=$uname_r $(date -u +%Y%m%dT%H%M%SZ)" | tee -a "$LOG" "$META"

if [ "$uname_r" = "7.2.9-baseline" ]; then
  if [ -f "$MARKER" ]; then
    echo "on baseline with marker; running measure" | tee -a "$LOG"
    /home/kernelmaster/kernel-measure/run-t11-stock-measure.sh
    rm -f "$MARKER"
    echo "measure done; scheduling reboot to t9" | tee -a "$LOG"
    sudo -n grub-editenv /boot/grub/grubenv set next_entry="$ENTRY_T9"
    sudo -n grub-editenv list | tee -a "$LOG" "$META"
    sudo -n reboot
    exit 0
  fi
  echo "on baseline but no marker; creating marker and measuring" | tee -a "$LOG"
  touch "$MARKER"
  /home/kernelmaster/kernel-measure/run-t11-stock-measure.sh
  rm -f "$MARKER"
  echo "measure done; scheduling reboot to t9" | tee -a "$LOG"
  sudo -n grub-editenv /boot/grub/grubenv set next_entry="$ENTRY_T9"
  sudo -n reboot
  exit 0
fi

# Not on baseline: arm next boot and reboot
echo "not baseline; arming next_entry=baseline and rebooting" | tee -a "$LOG"
touch "$MARKER"
# Persist marker across reboot in home
cp -f "$MARKER" /home/kernelmaster/t11-measure-pending
sudo -n grub-editenv /boot/grub/grubenv set next_entry="$ENTRY_BASE"
sudo -n grub-editenv list | tee -a "$LOG" "$META"
# Install a oneshot user cron/@reboot style via systemd user? Use /etc/rc.local alternative:
# Put a script that runs at boot via crontab @reboot
crontab -l 2>/dev/null | grep -v t11-after-boot > /tmp/t11-cron || true
echo "@reboot /home/kernelmaster/kernel-measure/run-t11-after-boot.sh" >> /tmp/t11-cron
crontab /tmp/t11-cron
crontab -l | tee -a "$LOG"
sudo -n reboot
