#!/usr/bin/env bash
# kernel-measure: prepare
# Task 4: localhost TCP receive — classic recv vs best available zero-copy.
#
# Engines (TCPRECV_ENGINE=auto tries them in this order):
#   c    build/tcp_recv_zc from workloads/src/tcp_recv_zc.c
#        Classic recv() hammer on 127.0.0.1; probes MSG_SOCK_DEVMEM and
#        io_uring IORING_REGISTER_ZCRX_IFQ on TCPRECV_IFACE (+ lo).
#        Reports wl_bytes_per_sec, wl_zc_available, probe errnos.
#   iperf3  fallback regression screen only (no ZC probe).
# Compare only runs with the same engine and arguments.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
HARNESS_DIR=${HARNESS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck source=lib/build_tool.sh
source "$HARNESS_DIR/lib/build_tool.sh"
DURATION=${DURATION:-10}
RUN_DIR=${RUN_DIR:-.}
TCPRECV_ENGINE=${TCPRECV_ENGINE:-auto}
TCPRECV_CHUNK_KB=${TCPRECV_CHUNK_KB:-64}
TCPRECV_IFACE=${TCPRECV_IFACE:-enp3s0f0}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

if [[ "${1:-}" == "--prepare" ]]; then
  if [[ "$TCPRECV_ENGINE" == auto || "$TCPRECV_ENGINE" == c ]]; then
    if build_tool tcp_recv_zc >/dev/null; then
      record_build tcp_recv_zc "$RUN_DIR"
      echo "prepared build/tcp_recv_zc"
    else
      echo "could not build tcp_recv_zc (no C compiler or build failed)"
    fi
  fi
  exit 0
fi

bin="$HARNESS_DIR/build/tcp_recv_zc"
if [[ "$TCPRECV_ENGINE" == auto || "$TCPRECV_ENGINE" == c ]] && [[ -x "$bin" ]]; then
  # Optional elevated ZC probe (CAP_NET_ADMIN required for zcrx register).
  # Non-fatal; classic path does not need root.
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    {
      echo "iface=$TCPRECV_IFACE"
      echo "ethtool_tcp_data_split:"
      sudo -n ethtool -g "$TCPRECV_IFACE" 2>&1 | grep -iE 'split|HDS|Ring' || true
      echo "ethtool_set_tcp_data_split:"
      sudo -n ethtool -G "$TCPRECV_IFACE" tcp-data-split on 2>&1 || true
      echo "driver:"
      ethtool -i "$TCPRECV_IFACE" 2>&1 || true
    } > "$RUN_DIR/zc_hw_probe.txt" 2>&1 || true
  fi
  cmd=("$bin" -d "$DURATION" -c "$TCPRECV_CHUNK_KB" -i "$TCPRECV_IFACE"
       -o "$RUN_DIR/workload.metrics")
  printf 'build/tcp_recv_zc -d %s -c %s -i %s\n' "$DURATION" \
    "$TCPRECV_CHUNK_KB" "$TCPRECV_IFACE" > "$RUN_DIR/command.txt"
  exec "${cmd[@]}"
fi
if [[ "$TCPRECV_ENGINE" == c ]]; then
  skip "TCPRECV_ENGINE=c but build/tcp_recv_zc is missing (no C compiler?)"
fi

if [[ "$TCPRECV_ENGINE" == auto || "$TCPRECV_ENGINE" == iperf3 ]] && command -v iperf3 >/dev/null 2>&1; then
  printf '%s\n' "iperf3 localhost fallback (no ZC probe)" > "$RUN_DIR/command.txt"
  echo "wl_engine=iperf3-fallback" > "$RUN_DIR/workload.metrics"
  echo "wl_zc_available=0" >> "$RUN_DIR/workload.metrics"
  echo "wl_note=iperf3_fallback_no_zc_probe" >> "$RUN_DIR/workload.metrics"
  srv_pid=""
  cleanup() {
    if [[ -n ${srv_pid:-} ]]; then
      kill "$srv_pid" 2>/dev/null || true
      wait "$srv_pid" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT
  iperf3 -s -1 --bind 127.0.0.1 >"$RUN_DIR/iperf3-server.log" 2>&1 &
  srv_pid=$!
  sleep 0.2
  iperf3 -c 127.0.0.1 -t "$DURATION" >"$RUN_DIR/iperf3-client.log" 2>&1
  cleanup
  exit 0
fi

skip "no tcp_recv_zc engine: need a C compiler (build/tcp_recv_zc) or iperf3"
