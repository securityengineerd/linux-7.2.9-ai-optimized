# Build helper for compiled workload engines. Sourced by workloads/*.sh.
# Builds workloads/src/NAME.c into build/NAME once, outside perf stat.
# The binary is reused across boots so stock and patched runs use the same
# bytes. It is rebuilt only when the source hash changes.

# build_tool NAME -> prints the binary path on success, returns 1 otherwise.
build_tool() {
  local name=$1
  local src="$HARNESS_DIR/workloads/src/${name}.c"
  local outdir="$HARNESS_DIR/build"
  local bin="$outdir/${name}"
  local stamp="$outdir/${name}.srcsha"
  local cc="" want have
  [[ -f "$src" ]] || return 1
  for c in "${CC:-}" cc gcc clang; do
    if [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1; then
      cc=$c
      break
    fi
  done
  want=$(sha256sum "$src" | awk '{print $1}')
  have=$(cat "$stamp" 2>/dev/null || true)
  if [[ -x "$bin" && "$want" == "$have" ]]; then
    printf '%s\n' "$bin"
    return 0
  fi
  [[ -n "$cc" ]] || return 1
  mkdir -p "$outdir"
  if ! "$cc" -O2 -Wall -pthread -o "$bin.tmp" "$src" >&2; then
    rm -f "$bin.tmp"
    return 1
  fi
  mv -f "$bin.tmp" "$bin"
  printf '%s\n' "$want" > "$stamp"
  {
    echo "source=$src"
    echo "source_sha256=$want"
    echo "compiler=$cc"
    "$cc" --version 2>/dev/null | head -n 1
    echo "built=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } > "$outdir/${name}.buildinfo"
  printf '%s\n' "$bin"
}

# record_build NAME RUN_DIR: copy build info and binary hash into the run.
record_build() {
  local name=$1 dir=$2 bin="$HARNESS_DIR/build/$1"
  {
    cat "$HARNESS_DIR/build/${name}.buildinfo" 2>/dev/null || echo "buildinfo missing"
    if [[ -x "$bin" ]]; then
      echo "binary_sha256=$(sha256sum "$bin" | awk '{print $1}')"
    fi
  } > "$dir/build_info.txt"
}
