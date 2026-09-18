#!/bin/bash
# Count user-space instructions of one backend while it runs ITER iterations of a
# plan-cached statement inside a plpgsql loop (ExecutorStart/Run/End per iteration,
# no planning after the plan cache settles). Deterministic enough to compare builds.
#   perfbench.sh PGBIN [ITER] [ROUNDS]
set -eu
PGBIN=$1; ITER=${2:-200000}; ROUNDS=${3:-3}
PORT=${PGPORT:-54341}
RUN=$(mktemp -d ~/pg/perfrun.XXXXXX); DATA=$RUN/data
cleanup() { "$PGBIN/pg_ctl" -D "$DATA" stop -m immediate -s >/dev/null 2>&1 || true; rm -rf "$RUN"; }
trap cleanup EXIT INT TERM
"$PGBIN/initdb" -D "$DATA" -A trust -U postgres --no-sync >"$RUN/initdb.log" 2>&1
"$PGBIN/pg_ctl" -D "$DATA" -l "$RUN/server.log" -s -w start \
    -o "-c listen_addresses=127.0.0.1 -c port=$PORT -c unix_socket_directories='' -c shared_buffers=256MB -c fsync=off -c jit=off -c max_parallel_workers_per_gather=0 ${EXTRA_OPTS:-}"
PSQL="$PGBIN/psql -h 127.0.0.1 -p $PORT -U postgres -d postgres -X -q -At"
$PSQL <<'SQL'
CREATE TABLE bench(id int PRIMARY KEY, txt text, big jsonb);
INSERT INTO bench SELECT i, 'v'||i, jsonb_build_object('a', i, 'b', i*2) FROM generate_series(1,1000) i;
ANALYZE bench;
CREATE OR REPLACE FUNCTION loop_noop(n int) RETURNS int LANGUAGE plpgsql AS $$
DECLARE r int := 0; x text; BEGIN
  FOR i IN 1..n LOOP
    SELECT txt INTO x FROM bench WHERE id = (i % 1000) + 1;   -- one reference, nothing to optimize
    r := r + length(x);
  END LOOP; RETURN r; END $$;
CREATE OR REPLACE FUNCTION loop_jsonb(n int) RETURNS int LANGUAGE plpgsql AS $$
DECLARE r int := 0; a int; b int; BEGIN
  FOR i IN 1..n LOOP
    SELECT (big->>'a')::int, (big->>'b')::int INTO a, b FROM bench WHERE id = (i % 1000) + 1;
    r := r + a + b;
  END LOOP; RETURN r; END $$;
DO $do$
DECLARE exprs text; body text; BEGIN
  -- 50 index scans, each with 20 jsonb extractions on the same column: amplifies
  -- per-node init work (decider walk) relative to a single tiny statement
  SELECT string_agg(format($$(big->>%L)::int$$, 'a'), ' + ') INTO exprs FROM generate_series(1,20);
  SELECT string_agg(format($$SELECT %s AS x FROM bench WHERE id = (i %% 1000) + %s$$, exprs, g), ' UNION ALL ')
    INTO body FROM generate_series(1,50) g;
  EXECUTE format($f$CREATE OR REPLACE FUNCTION loop_wide(n int) RETURNS bigint LANGUAGE plpgsql AS $b$
    DECLARE r bigint := 0; s bigint; BEGIN
      FOR i IN 1..n LOOP
        SELECT sum(x) INTO s FROM (%s) u;
        r := r + s;
      END LOOP; RETURN r; END $b$$f$, body);
END $do$;
SQL
echo "server: $($PGBIN/postgres --version)   iterations per round: $ITER"
printf "%-12s %-6s %16s %16s %14s\n" workload round instructions cycles "instr/iter"
for wl in loop_noop loop_jsonb loop_wide; do
  it=$ITER; [ $wl = loop_wide ] && it=$((ITER / 50))
  for round in $(seq 1 $ROUNDS); do
    mkfifo $RUN/in; exec 3<>$RUN/in
    $PSQL -f - <$RUN/in >$RUN/out 2>&1 &
    psqlpid=$!
    echo "SELECT pg_backend_pid();" >&3
    while ! [ -s $RUN/out ]; do sleep 0.05; done
    bpid=$(head -1 $RUN/out)
    # warm the plan cache (5 executions switch to a generic plan) before counting
    echo "SELECT $wl(10);" >&3
    while [ $(wc -l <$RUN/out) -lt 2 ]; do sleep 0.05; done
    perf stat -e instructions:u,cycles:u -x, -p $bpid -o $RUN/perf.out &
    perfpid=$!
    sleep 0.3
    echo "SELECT $wl($it);" >&3
    while [ $(wc -l <$RUN/out) -lt 3 ]; do sleep 0.1; done
    kill -INT $perfpid; wait $perfpid 2>/dev/null || true
    echo "\\q" >&3; wait $psqlpid 2>/dev/null || true
    exec 3>&-; rm -f $RUN/in
    ins=$(grep instructions $RUN/perf.out | cut -d, -f1)
    cyc=$(grep cycles $RUN/perf.out | cut -d, -f1)
    printf "%-12s %-6s %16s %16s %14s\n" $wl $round $ins $cyc $((ins / it))
    rm -f $RUN/out $RUN/perf.out
  done
done
