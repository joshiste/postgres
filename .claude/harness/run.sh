#!/bin/sh
# Run the shared-detoast guard suite against a throwaway cluster.
#   [PGPORT=port] [KEEP=1] [MODE=master|patched] [PHASE=n] run.sh [PGBIN]
# PGBIN = directory holding initdb/pg_ctl/psql (default: $PG_BIN or /usr/local/pgsql/bin).
# MODE=patched scores each case against its shared-detoast target; PHASE limits
# which targets apply (join cases are Phase 4). KEEP=1 leaves the cluster behind.
# Exit status is non-zero when any case fails.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PGBIN=${1:-${PG_BIN:-/usr/local/pgsql/bin}}
PORT=${PGPORT:-54329}
MODE=${MODE:-master}
PHASE=${PHASE:-9}
RUN=$(mktemp -d "${TMPDIR:-/tmp}/detoast-guard.XXXXXX"); DATA=$RUN/data
cleanup() {
    if [ -n "${KEEP:-}" ]; then echo "kept $RUN"; return; fi
    "$PGBIN/pg_ctl" -D "$DATA" stop -m immediate -s >/dev/null 2>&1 || true
    rm -rf "$RUN"
}
trap cleanup EXIT INT TERM

echo "server: $("$PGBIN/postgres" --version)   bin: $PGBIN"
"$PGBIN/initdb" -D "$DATA" -A trust -U postgres --no-sync >"$RUN/initdb.log" 2>&1
"$PGBIN/pg_ctl" -D "$DATA" -l "$RUN/server.log" -s -w start \
    -o "-c listen_addresses=127.0.0.1 -c port=$PORT -c unix_socket_directories='' -c shared_buffers=256MB -c fsync=off -c max_worker_processes=8"
"$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -X -q \
    -v mode="$MODE" -v phase="$PHASE" -f "$HERE/detoast_guard.sql"
