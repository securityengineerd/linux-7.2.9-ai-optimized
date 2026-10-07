#!/bin/sh
# @reboot helper: wait for network/disk, run measure on baseline, return to t9.
set -e
LOG=/tmp/t11-after-boot.log
exec >>"$LOG" 2>&1
echo "after-boot start $(date -u +%Y%m%dT%H%M%SZ) uname=$(uname -r)"
sleep 15
# Remove @reboot so we only fire once
crontab -l 2>/dev/null | grep -v t11-after-boot | crontab - || true
if [ "$(uname -r)" != "7.2.9-baseline" ]; then
  echo "ERROR: expected baseline after reboot, got $(uname -r)"
  rm -f /home/kernelmaster/t11-measure-pending
  exit 1
fi
/home/kernelmaster/kernel-measure/run-t11-stock-measure.sh
rm -f /home/kernelmaster/t11-measure-pending /tmp/t11-measure-pending
ENTRY_T9='Advanced options for Ubuntu>Ubuntu, with Linux 7.2.9-t9'
sudo -n grub-editenv /boot/grub/grubenv set next_entry="$ENTRY_T9"
# also restore saved_entry preference to t9
sudo -n grub-editenv /boot/grub/grubenv set saved_entry="$ENTRY_T9"
echo "rebooting to t9 $(date -u +%Y%m%dT%H%M%SZ)"
sudo -n reboot
