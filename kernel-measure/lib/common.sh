# Shared helpers. Sourced by the harness scripts; not executed directly.
if [[ -z ${HARNESS_DIR:-} ]]; then
  echo "error: HARNESS_DIR is not set" >&2
  return 1 2>/dev/null || exit 1
fi

WORKLOAD_IDS=(general containers database storage networking virtualization wake_llc migrate_load cgroup_cpu io_uring_submit tcp_recv_zc hot_read anon_fault mem_pressure folio_split util_est_burst softirq_storm folio_wait)
TASKS_CONF=${TASKS_CONF:-$HARNESS_DIR/tasks.conf}
# Per-workload default duration budget. Above this collect.sh warns.
DURATION_BUDGET=30

die() {
  echo "error: $*" >&2
  exit 1
}

require_linux() {
  local os
  os=$(uname -s 2>/dev/null || echo unknown)
  if [[ "$os" != "Linux" ]]; then
    echo "error: this harness must run on Linux, on the machine booted into the kernel under test." >&2
    echo "detected uname -s: ${os}" >&2
    echo "It does not measure a kernel from macOS. Copy this directory to the Linux test host and run it there." >&2
    exit 1
  fi
}

load_config() {
  local file=${1:-$HARNESS_DIR/workloads.conf}
  [[ -f "$file" ]] || die "config not found: $file"
  # Assignments in the config are exported to workload scripts.
  set -a
  # shellcheck disable=SC1090
  source "$file"
  GENERAL_DURATION=${GENERAL_DURATION:-10}
  CONTAINER_DURATION=${CONTAINER_DURATION:-10}
  DATABASE_DURATION=${DATABASE_DURATION:-10}
  STORAGE_DURATION=${STORAGE_DURATION:-8}
  NETWORK_DURATION=${NETWORK_DURATION:-8}
  GENERAL_CPU_WORKERS=${GENERAL_CPU_WORKERS:-2}
  GENERAL_FORK_WORKERS=${GENERAL_FORK_WORKERS:-2}
  CONTAINER_MAX_RUNS=${CONTAINER_MAX_RUNS:-3}
  CONTAINER_IMAGE_CANDIDATES=${CONTAINER_IMAGE_CANDIDATES:-alpine:latest busybox:latest}
  DATABASE_ENGINE=${DATABASE_ENGINE:-auto}
  SQLITE_ROWS=${SQLITE_ROWS:-2000}
  SYSBENCH_THREADS=${SYSBENCH_THREADS:-2}
  STORAGE_MB=${STORAGE_MB:-32}
  STORAGE_PARENT=${STORAGE_PARENT:-}
  NETWORK_MIB=${NETWORK_MIB:-32}
  VIRT_LAUNCH=${VIRT_LAUNCH:-never}
  OUTER_TIMEOUT_GRACE=${OUTER_TIMEOUT_GRACE:-15}
  TRACE_COPY_MAX_BYTES=${TRACE_COPY_MAX_BYTES:-33554432}
  WAKE_LLC_DURATION=${WAKE_LLC_DURATION:-20}
  WAKE_LLC_ENGINE=${WAKE_LLC_ENGINE:-auto}
  WAKE_LLC_MESSENGERS=${WAKE_LLC_MESSENGERS:-2}
  WAKE_LLC_WORKERS=${WAKE_LLC_WORKERS:-0}
  WAKE_LLC_SPINNERS=${WAKE_LLC_SPINNERS:--1}
  WAKE_LLC_PERIOD_US=${WAKE_LLC_PERIOD_US:-1000}
  WAKE_LLC_BUSY_US=${WAKE_LLC_BUSY_US:-20}
  MIGRATE_DURATION=${MIGRATE_DURATION:-18}
  MIGRATE_ENGINE=${MIGRATE_ENGINE:-auto}
  MIGRATE_WORKERS=${MIGRATE_WORKERS:-0}
  MIGRATE_BUF_KB=${MIGRATE_BUF_KB:-256}
  MIGRATE_STORM_MS=${MIGRATE_STORM_MS:-10}
  CGCPU_DURATION=${CGCPU_DURATION:-24}
  CGCPU_ROOT=${CGCPU_ROOT:-/sys/fs/cgroup/kmeas.slice}
  CGCPU_DEPTHS=${CGCPU_DEPTHS:-"1 3 6"}
  CGCPU_WEIGHTS=${CGCPU_WEIGHTS:-"100 200 400"}
  CGCPU_MAX=${CGCPU_MAX:-"20000 100000"}
  CGCPU_HOGS_PER_SIB=${CGCPU_HOGS_PER_SIB:-0}
  CGCPU_SETTLE_MS=${CGCPU_SETTLE_MS:-200}
  IOURING_DURATION=${IOURING_DURATION:-12}
  IOURING_ENGINE=${IOURING_ENGINE:-auto}
  IOURING_BATCH=${IOURING_BATCH:-32}
  IOURING_ENTRIES=${IOURING_ENTRIES:-256}
  IOURING_MB=${IOURING_MB:-32}
  TCPRECV_DURATION=${TCPRECV_DURATION:-10}
  TCPRECV_ENGINE=${TCPRECV_ENGINE:-auto}
  TCPRECV_CHUNK_KB=${TCPRECV_CHUNK_KB:-64}
  TCPRECV_IFACE=${TCPRECV_IFACE:-enp3s0f0}
  HOTREAD_DURATION=${HOTREAD_DURATION:-12}
  HOTREAD_ENGINE=${HOTREAD_ENGINE:-auto}
  HOTREAD_FILE_MB=${HOTREAD_FILE_MB:-64}
  HOTREAD_CHUNK_KB=${HOTREAD_CHUNK_KB:-128}
  HOTREAD_TARGET_MIB=${HOTREAD_TARGET_MIB:-0}
  HOTREAD_PARENT=${HOTREAD_PARENT:-}
  ANONFAULT_DURATION=${ANONFAULT_DURATION:-8}
  ANONFAULT_ENGINE=${ANONFAULT_ENGINE:-auto}
  ANONFAULT_SIZE_MIB=${ANONFAULT_SIZE_MIB:-1024}
  ANONFAULT_STRIDE=${ANONFAULT_STRIDE:-4096}
  ANONFAULT_RETOUCH=${ANONFAULT_RETOUCH:-1}
  ANONFAULT_ENABLE_MTHP=${ANONFAULT_ENABLE_MTHP:-0}
  MEMPRESS_DURATION=${MEMPRESS_DURATION:-20}
  FOLIOSPLIT_DURATION=${FOLIOSPLIT_DURATION:-25}
  FOLIOSPLIT_ENGINE=${FOLIOSPLIT_ENGINE:-auto}
  FOLIOSPLIT_MODE=${FOLIOSPLIT_MODE:-partial}
  FOLIOSPLIT_RESERVE_MIB=${FOLIOSPLIT_RESERVE_MIB:-1024}
  FOLIOSPLIT_THP_MIB=${FOLIOSPLIT_THP_MIB:-2048}
  FOLIOSPLIT_HOG_MIB=${FOLIOSPLIT_HOG_MIB:-0}
  FOLIOSPLIT_PUNCH_EVERY_N=${FOLIOSPLIT_PUNCH_EVERY_N:-2}
  FOLIOSPLIT_SHRINK_UNDERUSED=${FOLIOSPLIT_SHRINK_UNDERUSED:-}
  UTIL_EST_DURATION=${UTIL_EST_DURATION:-15}
  UTIL_EST_ENGINE=${UTIL_EST_ENGINE:-auto}
  UTIL_EST_NBURST=${UTIL_EST_NBURST:-0}
  UTIL_EST_NHOG=${UTIL_EST_NHOG:--1}
  UTIL_EST_ON_US=${UTIL_EST_ON_US:-5000}
  UTIL_EST_OFF_US=${UTIL_EST_OFF_US:-80000}
  SOFTIRQ_DURATION=${SOFTIRQ_DURATION:-15}
  SOFTIRQ_ENGINE=${SOFTIRQ_ENGINE:-auto}
  SOFTIRQ_NTIMER=${SOFTIRQ_NTIMER:-4}
  SOFTIRQ_NNET=${SOFTIRQ_NNET:-4}
  SOFTIRQ_NRCU=${SOFTIRQ_NRCU:-2}
  FOLIOWAIT_DURATION=${FOLIOWAIT_DURATION:-15}
  FOLIOWAIT_ENGINE=${FOLIOWAIT_ENGINE:-auto}
  FOLIOWAIT_MODE=${FOLIOWAIT_MODE:-writeback}
  FOLIOWAIT_THREADS=${FOLIOWAIT_THREADS:-0}
  FOLIOWAIT_NFILES=${FOLIOWAIT_NFILES:-512}
  FOLIOWAIT_FILE_KB=${FOLIOWAIT_FILE_KB:-64}
  FOLIOWAIT_CHUNK_KB=${FOLIOWAIT_CHUNK_KB:-4}
  FOLIOWAIT_PARENT=${FOLIOWAIT_PARENT:-}
  SCHEDSTATS_ENABLE=${SCHEDSTATS_ENABLE:-0}
  set +a
}

duration_for() {
  case "$1" in
    general) printf '%s\n' "$GENERAL_DURATION" ;;
    containers) printf '%s\n' "$CONTAINER_DURATION" ;;
    database) printf '%s\n' "$DATABASE_DURATION" ;;
    storage) printf '%s\n' "$STORAGE_DURATION" ;;
    networking) printf '%s\n' "$NETWORK_DURATION" ;;
    virtualization) printf '%s\n' 1 ;;
    wake_llc) printf '%s\n' "$WAKE_LLC_DURATION" ;;
    migrate_load) printf '%s\n' "$MIGRATE_DURATION" ;;
    cgroup_cpu) printf '%s\n' "$CGCPU_DURATION" ;;
    io_uring_submit) printf '%s\n' "$IOURING_DURATION" ;;
    tcp_recv_zc) printf '%s\n' "$TCPRECV_DURATION" ;;
    hot_read) printf '%s\n' "$HOTREAD_DURATION" ;;
    anon_fault) printf '%s\n' "$ANONFAULT_DURATION" ;;
    mem_pressure) printf '%s\n' "$MEMPRESS_DURATION" ;;
    folio_split) printf '%s\n' "$FOLIOSPLIT_DURATION" ;;
    util_est_burst) printf '%s\n' "$UTIL_EST_DURATION" ;;
    softirq_storm) printf '%s\n' "$SOFTIRQ_DURATION" ;;
    folio_wait) printf '%s\n' "$FOLIOWAIT_DURATION" ;;
    *) die "unknown workload: $1" ;;
  esac
}

valid_workload() {
  local w=$1 x
  for x in "${WORKLOAD_IDS[@]}"; do
    [[ "$x" == "$w" ]] && return 0
  done
  return 1
}

warn_duration() {
  local name=$1 dur=$2
  if [[ "$dur" =~ ^[0-9]+$ ]] && (( dur > DURATION_BUDGET )); then
    echo "warning: ${name} duration is ${dur}s, above the ${DURATION_BUDGET}s default budget" >&2
  fi
}

# tasks.conf lookups. Lines: id|name|measures|workloads|primary_metrics|pass_fail
task_line() {
  local id=$1
  [[ -f "$TASKS_CONF" ]] || die "task map not found: $TASKS_CONF"
  [[ "$id" =~ ^[0-9]+$ ]] || die "task id must be an integer (got ${id})"
  awk -F'|' -v id="$id" '$0 !~ /^[[:space:]]*#/ && NF >= 6 && $1 == id { print; found = 1; exit } END { exit found ? 0 : 1 }' "$TASKS_CONF"
}

task_field() {
  local id=$1 n=$2 line
  line=$(task_line "$id") || die "task ${id} is not in ${TASKS_CONF}"
  printf '%s\n' "$line" | cut -d'|' -f"$n"
}

task_name() { task_field "$1" 2; }
task_measures() { task_field "$1" 3; }
task_workloads() { task_field "$1" 4; }
task_metrics() { task_field "$1" 5; }
task_passfail() { task_field "$1" 6; }

list_tasks() {
  [[ -f "$TASKS_CONF" ]] || die "task map not found: $TASKS_CONF"
  awk -F'|' '$0 !~ /^[[:space:]]*#/ && NF >= 6 { printf "%-3s %-34s %s\n", $1, $2, $4 }' "$TASKS_CONF"
}
