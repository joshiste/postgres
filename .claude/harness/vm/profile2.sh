#!/bin/bash
# per-symbol user-instruction profile of one backend running loop_wide (generic plans)
set -u
PGBIN=$1; TAG=$2; PORT=$3
export LC_ALL=C
RUN=$(mktemp -d ~/pg/prof.XXXXXX); DATA=$RUN/data
$PGBIN/initdb -D $DATA -A trust -U postgres --no-sync > /dev/null 2>&1
$PGBIN/pg_ctl -D $DATA -l $RUN/log -s -w start -o "-c listen_addresses=127.0.0.1 -c port=$PORT -c unix_socket_directories='' -c fsync=off -c jit=off -c max_parallel_workers_per_gather=0 -c plan_cache_mode=force_generic_plan"
PSQL="$PGBIN/psql -h 127.0.0.1 -p $PORT -U postgres -d postgres -X -q -At"
cat > $RUN/setup.sql <<'SQL'
CREATE TABLE bench(id int PRIMARY KEY, txt text, big jsonb);
INSERT INTO bench SELECT i, 'v'||i, jsonb_build_object('a', i, 'b', i*2) FROM generate_series(1,1000) i;
ANALYZE bench;
DO $do$
DECLARE exprs text; body text; BEGIN
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
$PSQL -f $RUN/setup.sql
mkfifo $RUN/in; exec 3<>$RUN/in
$PSQL -f - <$RUN/in >$RUN/out 2>&1 &
echo "SELECT pg_backend_pid();" >&3; while ! [ -s $RUN/out ]; do sleep 0.05; done; bpid=$(head -1 $RUN/out)
echo "SELECT loop_wide(10);" >&3; while [ $(wc -l <$RUN/out) -lt 2 ]; do sleep 0.05; done
perf record -q -e instructions:u -c 50000 -p $bpid -o $RUN/perf.data 2>/dev/null &
ppid=$!; sleep 0.3
echo "SELECT loop_wide(4000);" >&3; while [ $(wc -l <$RUN/out) -lt 3 ]; do sleep 0.2; done
kill -INT $ppid; wait $ppid 2>/dev/null
echo "\\q" >&3; exec 3>&-
perf report -i $RUN/perf.data --stdio --sort symbol -q -n 2>/dev/null | awk '{gsub(/%/,"",$1); printf "%s %s %s\n", $4, $2, $1}' | sort -k1,1 > ~/pg/profile2-$TAG.txt
$PGBIN/pg_ctl -D $DATA stop -m immediate -s; rm -rf $RUN
echo "profile $TAG: $(wc -l < ~/pg/profile2-$TAG.txt) symbols, $(awk '{s+=$2} END {print s}' ~/pg/profile2-$TAG.txt) samples"
