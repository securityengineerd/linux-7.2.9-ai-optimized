#!/usr/bin/env bash
# Localhost network transfer. iperf3 if present, else python3. No off-host traffic.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
DURATION=${DURATION:-8}
NETWORK_MIB=${NETWORK_MIB:-32}
RUN_DIR=${RUN_DIR:-.}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

run_iperf() {
  srv_pid=""
  local port="" candidate rc=0
  cleanup() {
    if [[ -n ${srv_pid:-} ]]; then
      kill "$srv_pid" 2>/dev/null || true
      wait "$srv_pid" 2>/dev/null || true
      srv_pid=""
    fi
  }
  trap cleanup EXIT
  trap 'exit 143' INT TERM
  for candidate in 15201 15211 15221 15231 15241 15251; do
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":${candidate} "; then
      continue
    fi
    iperf3 -s -1 -p "$candidate" --bind 127.0.0.1 >"$RUN_DIR/iperf3-server.log" 2>&1 &
    srv_pid=$!
    sleep 0.2
    if kill -0 "$srv_pid" 2>/dev/null; then
      port=$candidate
      break
    fi
    wait "$srv_pid" 2>/dev/null || true
    srv_pid=""
  done
  if [[ -z "$port" ]]; then
    return 1
  fi
  printf '%s\n' "iperf3 -c 127.0.0.1 -p ${port} -t ${DURATION} (server: iperf3 -s -1 --bind 127.0.0.1)" > "$RUN_DIR/command.txt"
  iperf3 -c 127.0.0.1 -p "$port" -t "$DURATION" >"$RUN_DIR/iperf3-client.log" 2>&1 || rc=$?
  cleanup
  return "$rc"
}

run_python() {
  printf '%s\n' "python3 localhost TCP transfer duration=${DURATION}s (iperf3 missing or unusable)" > "$RUN_DIR/command.txt"
  python3 - "$DURATION" "$NETWORK_MIB" <<'PY'
import socket, sys, threading, time
dur = float(sys.argv[1])
chunk = b"x" * (min(int(sys.argv[2]), 4) * 1024 * 1024)
end = time.time() + dur
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(1)
port = srv.getsockname()[1]
got = {"n": 0}

def serve():
    conn, _ = srv.accept()
    conn.settimeout(0.5)
    deadline = end + 2
    while time.time() < deadline:
        try:
            data = conn.recv(1024 * 1024)
        except socket.timeout:
            continue
        if not data:
            break
        got["n"] += len(data)
    conn.close()

t = threading.Thread(target=serve)
t.start()
cli = socket.create_connection(("127.0.0.1", port), timeout=2)
sent = 0
while time.time() < end:
    cli.sendall(chunk)
    sent += len(chunk)
cli.shutdown(socket.SHUT_WR)
cli.close()
t.join(timeout=5)
srv.close()
print("sent_bytes=%s recv_bytes=%s port=%s" % (sent, got["n"], port))
if got["n"] <= 0:
    raise SystemExit(1)
PY
}

if command -v iperf3 >/dev/null 2>&1; then
  if run_iperf; then
    exit 0
  fi
  echo "note: iperf3 is installed but the localhost server did not stay up; trying python3" >&2
fi

if command -v python3 >/dev/null 2>&1; then
  run_python
  exit 0
fi

skip "neither iperf3 nor python3 is installed"
