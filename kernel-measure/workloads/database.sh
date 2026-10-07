#!/usr/bin/env bash
# Database mix: sqlite3 write/read, else a sysbench threads stand-in. No server setup.
set -euo pipefail
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: Linux required, detected $(uname -s)" >&2
  exit 1
fi
DURATION=${DURATION:-10}
DATABASE_ENGINE=${DATABASE_ENGINE:-auto}
SQLITE_ROWS=${SQLITE_ROWS:-2000}
SYSBENCH_THREADS=${SYSBENCH_THREADS:-2}
RUN_DIR=${RUN_DIR:-.}
mkdir -p "$RUN_DIR"

skip() {
  printf '%s\n' "$1" > "$RUN_DIR/skip_reason.txt"
  echo "SKIP: $1" >&2
  exit 2
}

if [[ ! "$SQLITE_ROWS" =~ ^[0-9]+$ ]] || (( SQLITE_ROWS <= 0 )); then
  echo "error: SQLITE_ROWS must be a positive integer" >&2
  exit 1
fi

run_sqlite() {
  db=$(mktemp "${TMPDIR:-/tmp}/kernel-measure-sqlite.XXXXXX")
  cleanup() {
    if [[ -n ${db:-} ]]; then
      rm -f "$db"
    fi
  }
  trap cleanup EXIT
  trap 'exit 143' INT TERM
  printf '%s\n' "sqlite3 tempdb CREATE/INSERT ${SQLITE_ROWS} rows, UPDATE, SELECT, DELETE (synchronous=FULL)" > "$RUN_DIR/command.txt"
  if sqlite3 "$db" <<SQL
PRAGMA journal_mode=DELETE;
PRAGMA synchronous=FULL;
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
WITH RECURSIVE c(x) AS (
  SELECT 1
  UNION ALL
  SELECT x + 1 FROM c WHERE x < ${SQLITE_ROWS}
)
INSERT INTO t(v) SELECT 'v' || x FROM c;
SELECT count(*) FROM t;
UPDATE t SET v = v || 'u' WHERE id % 2 = 0;
SELECT count(*), coalesce(sum(length(v)), 0) FROM t;
DELETE FROM t WHERE id % 3 = 0;
SELECT count(*) FROM t;
SQL
  then
    return 0
  fi
  rm -f "$db"
  db=$(mktemp "${TMPDIR:-/tmp}/kernel-measure-sqlite.XXXXXX")
  echo "note: recursive CTE failed; using a row loop" >&2
  {
    echo "PRAGMA journal_mode=DELETE;"
    echo "PRAGMA synchronous=FULL;"
    echo "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);"
    echo "BEGIN;"
    local i
    for ((i = 1; i <= SQLITE_ROWS; i++)); do
      echo "INSERT INTO t(v) VALUES('v${i}');"
    done
    echo "COMMIT;"
    echo "SELECT count(*) FROM t;"
    echo "UPDATE t SET v = v || 'u' WHERE id % 2 = 0;"
    echo "SELECT count(*), coalesce(sum(length(v)), 0) FROM t;"
    echo "DELETE FROM t WHERE id % 3 = 0;"
    echo "SELECT count(*) FROM t;"
  } | sqlite3 "$db"
}

run_sysbench() {
  printf '%s\n' "sysbench threads --threads ${SYSBENCH_THREADS} --thread-yields 200 --time ${DURATION} run (stand-in: sysbench OLTP needs an external database server)" > "$RUN_DIR/command.txt"
  sysbench threads --threads "$SYSBENCH_THREADS" --thread-yields 200 --time "$DURATION" run
}

have_sqlite=0
have_sysbench=0
if command -v sqlite3 >/dev/null 2>&1; then
  have_sqlite=1
fi
if command -v sysbench >/dev/null 2>&1; then
  have_sysbench=1
fi

case "$DATABASE_ENGINE" in
  sqlite3)
    if (( have_sqlite == 0 )); then
      skip "DATABASE_ENGINE=sqlite3 but sqlite3 is not installed"
    fi
    run_sqlite
    ;;
  sysbench)
    if (( have_sysbench == 0 )); then
      skip "DATABASE_ENGINE=sysbench but sysbench is not installed"
    fi
    run_sysbench
    ;;
  auto)
    if (( have_sqlite == 1 )); then
      run_sqlite
    elif (( have_sysbench == 1 )); then
      run_sysbench
    else
      skip "neither sqlite3 nor sysbench is installed"
    fi
    ;;
  *)
    echo "error: unknown DATABASE_ENGINE=${DATABASE_ENGINE}" >&2
    exit 1
    ;;
esac
