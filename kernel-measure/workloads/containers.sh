#!/usr/bin/env bash
# Container startup loop. Never pulls an image and never runs without a local match.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
DURATION=${DURATION:-10}
CONTAINER_MAX_RUNS=${CONTAINER_MAX_RUNS:-3}
CONTAINER_IMAGE_CANDIDATES=${CONTAINER_IMAGE_CANDIDATES:-alpine:latest busybox:latest}
RUN_DIR=${RUN_DIR:-.}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

with_timeout() {
  local sec=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$sec" "$@"
  else
    "$@"
  fi
}

have_docker=0
have_podman=0
if command -v docker >/dev/null 2>&1; then
  have_docker=1
fi
if command -v podman >/dev/null 2>&1; then
  have_podman=1
fi
if (( have_docker == 0 && have_podman == 0 )); then
  skip "neither docker nor podman is installed"
fi

runtime=""
unusable=""
for rt in docker podman; do
  if ! command -v "$rt" >/dev/null 2>&1; then
    continue
  fi
  if with_timeout 8 "$rt" info >/dev/null 2>&1; then
    runtime=$rt
    break
  fi
  unusable="${unusable}${rt} info failed or timed out; "
done
if [[ -z "$runtime" ]]; then
  skip "docker/podman not usable (${unusable:-daemon down or permission denied}); container not started"
fi

mapfile -t images < <(with_timeout 8 "$runtime" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
chosen=""
for cand in $CONTAINER_IMAGE_CANDIDATES; do
  if ((${#images[@]})); then
    for img in "${images[@]}"; do
      if [[ "$img" == "$cand" ]]; then
        chosen=$cand
        break
      fi
    done
  fi
  [[ -n "$chosen" ]] && break
done
if [[ -z "$chosen" ]]; then
  skip "no local image matches candidates (${CONTAINER_IMAGE_CANDIDATES}); refusing to pull"
fi

name="kmeas-$$"
cleanup() {
  "$runtime" rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 143' INT TERM

printf '%s\n' "$runtime run --rm --name $name --network none --entrypoint /bin/true $chosen" > "$RUN_DIR/command.txt"
end=$((SECONDS + DURATION))
count=0
entry=(--entrypoint /bin/true)
while (( SECONDS < end && count < CONTAINER_MAX_RUNS )); do
  if "$runtime" run --rm --name "$name" --network none "${entry[@]}" "$chosen"; then
    count=$((count + 1))
    continue
  fi
  if (( count == 0 )) && [[ "${entry[*]}" == "--entrypoint /bin/true" ]]; then
    entry=(--entrypoint true)
    printf '%s\n' "$runtime run --rm --name $name --network none --entrypoint true $chosen" > "$RUN_DIR/command.txt"
    continue
  fi
  exit 1
done
if (( count == 0 )); then
  echo "error: container runtime produced no successful runs" >&2
  exit 1
fi
echo "container_runs=${count}" > "$RUN_DIR/container_runs.txt"
