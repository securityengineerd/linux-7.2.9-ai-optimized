#!/usr/bin/env bash
# General-purpose CPU + fork mix. stress-ng if present, else python3, else bash.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
DURATION=${DURATION:-10}
GENERAL_CPU_WORKERS=${GENERAL_CPU_WORKERS:-2}
GENERAL_FORK_WORKERS=${GENERAL_FORK_WORKERS:-2}
RUN_DIR=${RUN_DIR:-.}
mkdir -p "$RUN_DIR"

if command -v stress-ng >/dev/null 2>&1; then
  help=$(stress-ng --help 2>&1 || true)
  cmd=(stress-ng --cpu "$GENERAL_CPU_WORKERS" --timeout "${DURATION}s")
  if grep -q -- '--fork' <<<"$help"; then
    cmd+=(--fork "$GENERAL_FORK_WORKERS")
  fi
  if grep -q -- '--metrics-brief' <<<"$help"; then
    cmd+=(--metrics-brief)
  fi
  printf '%q ' "${cmd[@]}" > "$RUN_DIR/command.txt"
  printf '\n' >> "$RUN_DIR/command.txt"
  "${cmd[@]}"
  exit 0
fi

if command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "python3 CPU+fork fallback (stress-ng not installed) duration=${DURATION}s" > "$RUN_DIR/command.txt"
  exec python3 - "$DURATION" <<'PY'
import os, sys, time
dur = float(sys.argv[1])
end = time.time() + dur
iters = 0
x = 0
while time.time() < end:
    x = 0
    for i in range(20000):
        x += i * i
    pid = os.fork()
    if pid == 0:
        os._exit(0)
    os.waitpid(pid, 0)
    iters += 1
print("fallback_iters=%s sink=%s" % (iters, x))
PY
fi

printf '%s\n' "bash CPU+fork fallback (stress-ng and python3 not installed) duration=${DURATION}s" > "$RUN_DIR/command.txt"
end=$((SECONDS + DURATION))
iters=0
while (( SECONDS < end )); do
  x=0
  for ((i = 0; i < 1000; i++)); do
    x=$((x + i))
  done
  (exit 0)
  iters=$((iters + 1))
done
echo "fallback_iters=${iters}"
