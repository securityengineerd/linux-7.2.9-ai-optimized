#!/usr/bin/env bash
# kernel-measure: softirq_storm (Task 12)
# TIMER + NET_RX + RCU callback pressure with wake-latency sampling.
# Captures /proc/softirqs, ksoftirqd runtime, RCU softirq use, cmdline knobs.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
HARNESS_DIR=${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=lib/build_tool.sh
source "$HARNESS_DIR/lib/build_tool.sh"
DURATION=${DURATION:-15}
RUN_DIR=${RUN_DIR:-.}
SOFTIRQ_ENGINE=${SOFTIRQ_ENGINE:-auto}
SOFTIRQ_NTIMER=${SOFTIRQ_NTIMER:-4}
SOFTIRQ_NNET=${SOFTIRQ_NNET:-4}
SOFTIRQ_NRCU=${SOFTIRQ_NRCU:-2}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

sum_softirqs() {
  # Print TOTAL TIMER NET_TX NET_RX RCU (column sums across CPUs)
  awk '
    NR==1 { next }
    {
      name=$1; gsub(/:/,"",name);
      s=0; for (i=2;i<=NF;i++) s+=$i;
      tot[name]=s; grand+=s;
    }
    END {
      printf "total=%d TIMER=%d NET_TX=%d NET_RX=%d RCU=%d TASKLET=%d HRTIMER=%d SCHED=%d\n",
        grand+0, tot["TIMER"]+0, tot["NET_TX"]+0, tot["NET_RX"]+0,
        tot["RCU"]+0, tot["TASKLET"]+0, tot["HRTIMER"]+0, tot["SCHED"]+0;
    }
  ' /proc/softirqs
}

ksoftirqd_cputime_ms() {
  # Sum utime+stime of all ksoftirqd/* threads (clock ticks -> ms)
  local hz ticks=0
  hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
  while read -r pid; do
    [[ -r /proc/$pid/stat ]] || continue
    # fields 14,15 = utime stime
    ticks=$((ticks + $(awk '{print $14+$15}' /proc/$pid/stat)))
  done < <(pgrep -d $'\n' -f '^ksoftirqd/' 2>/dev/null || true)
  # also match comm via /proc
  if [[ "$ticks" -eq 0 ]]; then
    for d in /proc/[0-9]*; do
      comm=$(cat "$d/comm" 2>/dev/null || true)
      case "$comm" in
        ksoftirqd/*)
          ticks=$((ticks + $(awk '{print $14+$15}' "$d/stat" 2>/dev/null || echo 0)))
          ;;
      esac
    done
  fi
  echo $((ticks * 1000 / hz))
}

rcuo_present() {
  local n=0
  for d in /proc/[0-9]*; do
    comm=$(cat "$d/comm" 2>/dev/null || true)
    case "$comm" in
      rcuo*|rcuog*|rcuop*) n=$((n+1)) ;;
    esac
  done
  echo "$n"
}

record_knobs() {
  local cmdline use_si force_th nocb
  cmdline=$(cat /proc/cmdline)
  use_si=$(cat /sys/module/rcutree/parameters/use_softirq 2>/dev/null || echo unknown)
  if echo "$cmdline" | grep -qw threadirqs; then
    force_th=on
  else
    force_th=off
  fi
  if echo "$cmdline" | grep -q 'rcu_nocbs'; then
    nocb=$(echo "$cmdline" | tr ' ' '\n' | grep '^rcu_nocbs' | head -1)
  else
    nocb=off
  fi
  {
    echo "wl_cmdline_threadirqs=$force_th"
    echo "wl_cmdline_rcu_nocbs=$nocb"
    echo "wl_rcutree_use_softirq=$use_si"
    echo "wl_rcuo_kthreads=$(rcuo_present)"
    echo "wl_netdev_budget=$(sysctl -n net.core.netdev_budget 2>/dev/null || echo n/a)"
    echo "wl_netdev_budget_usecs=$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null || echo n/a)"
  } >> "$RUN_DIR/workload.metrics"
  printf '%s\n' "$cmdline" > "$RUN_DIR/cmdline.txt"
  cat /sys/module/rcutree/parameters/use_softirq > "$RUN_DIR/rcutree_use_softirq.txt" 2>/dev/null || true
}

if [[ "${1:-}" == "--prepare" ]]; then
  if [[ "$SOFTIRQ_ENGINE" == auto || "$SOFTIRQ_ENGINE" == c ]]; then
    if build_tool softirq_storm >/dev/null; then
      record_build softirq_storm "$RUN_DIR"
      echo "prepared build/softirq_storm"
    else
      echo "could not build softirq_storm (no C compiler or build failed)"
    fi
  fi
  exit 0
fi

bin="$HARNESS_DIR/build/softirq_storm"
: > "$RUN_DIR/workload.metrics"
record_knobs

# Snapshot softirqs + ksoftirqd before
sum_softirqs > "$RUN_DIR/softirqs.before.txt"
before_ms=$(ksoftirqd_cputime_ms)
echo "$before_ms" > "$RUN_DIR/ksoftirqd_ms.before.txt"
cp /proc/softirqs "$RUN_DIR/proc_softirqs.before.txt"
dmesg -T 2>/dev/null | grep -i 'rcu stall\|rcu_sched.*stall\|soft lockup' | tail -20 > "$RUN_DIR/dmesg_stalls.before.txt" || true

rc=0
if [[ "$SOFTIRQ_ENGINE" == auto || "$SOFTIRQ_ENGINE" == c ]] && [[ -x "$bin" ]]; then
  printf '%s\n' "$bin -d $DURATION -t $SOFTIRQ_NTIMER -n $SOFTIRQ_NNET -r $SOFTIRQ_NRCU" > "$RUN_DIR/command.txt"
  set +e
  "$bin" -d "$DURATION" -t "$SOFTIRQ_NTIMER" -n "$SOFTIRQ_NNET" -r "$SOFTIRQ_NRCU" \
    > "$RUN_DIR/softirq_storm.out" 2>"$RUN_DIR/softirq_storm.err"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    # promote wl_* lines into workload.metrics
    grep '^wl_' "$RUN_DIR/softirq_storm.out" >> "$RUN_DIR/workload.metrics" || true
  fi
elif command -v stress-ng >/dev/null 2>&1; then
  printf '%s\n' "stress-ng --timer $SOFTIRQ_NTIMER --udp $SOFTIRQ_NNET --timeout ${DURATION}s (C engine missing)" > "$RUN_DIR/command.txt"
  set +e
  stress-ng --timer "$SOFTIRQ_NTIMER" --udp "$SOFTIRQ_NNET" --timeout "${DURATION}s" \
    > "$RUN_DIR/stress-ng.out" 2>"$RUN_DIR/stress-ng.err"
  rc=$?
  set -e
  echo "wl_softirq_storm_engine=stress-ng" >> "$RUN_DIR/workload.metrics"
else
  skip "neither softirq_storm binary nor stress-ng available"
fi

sum_softirqs > "$RUN_DIR/softirqs.after.txt"
after_ms=$(ksoftirqd_cputime_ms)
echo "$after_ms" > "$RUN_DIR/ksoftirqd_ms.after.txt"
cp /proc/softirqs "$RUN_DIR/proc_softirqs.after.txt"
dmesg -T 2>/dev/null | grep -i 'rcu stall\|rcu_sched.*stall\|soft lockup' | tail -20 > "$RUN_DIR/dmesg_stalls.after.txt" || true

# Deltas
python3 - "$RUN_DIR" "$before_ms" "$after_ms" <<'PY'
import sys, re
rd, bms, ams = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def parse(path):
    d={}
    with open(path) as f:
        line=f.read().strip()
    for part in line.split():
        if "=" in part:
            k,v=part.split("=",1)
            d[k]=int(v)
    return d
b=parse(rd+"/softirqs.before.txt")
a=parse(rd+"/softirqs.after.txt")
keys=["total","TIMER","NET_TX","NET_RX","RCU","TASKLET","HRTIMER","SCHED"]
out=[]
for k in keys:
    out.append(f"wl_softirq_{k.lower()}_delta={a.get(k,0)-b.get(k,0)}")
out.append(f"wl_ksoftirqd_ms_delta={ams-bms}")
# stall lines new?
def nlines(p):
    try:
        return sum(1 for _ in open(p))
    except Exception:
        return 0
stalls = nlines(rd+"/dmesg_stalls.after.txt") - nlines(rd+"/dmesg_stalls.before.txt")
if stalls < 0: stalls = nlines(rd+"/dmesg_stalls.after.txt")
out.append(f"wl_rcu_stall_lines_delta={stalls}")
with open(rd+"/workload.metrics","a") as f:
    f.write("\n".join(out)+"\n")
print("softirq deltas recorded")
PY

# Visibility gate helper for humans
total_delta=$(grep '^wl_softirq_total_delta=' "$RUN_DIR/workload.metrics" | cut -d= -f2)
echo "softirq_total_delta=${total_delta:-?}" >&2
exit "$rc"
