-- Guard suite for shared detoasting of toasted Vars.
--
-- Every case runs a query several times and records
--   toast_blks   blocks fetched from the toast tables and toast indexes of the
--                probe tables during the run (transaction-local counters,
--                pg_stat_get_xact_blocks_fetched; leader process only)
--   shared_blks  shared buffer hits+reads from EXPLAIN (ANALYZE, BUFFERS),
--                which includes parallel workers
--   rows         rows the top plan node produced (semantic checks)
--
-- The 1 MB document is stored EXTERNAL (uncompressed), so one full detoast costs
-- a fixed 133 toast heap blocks; toast_blks / 133 is the number of detoasts.
--
-- Each case carries the value master must produce (mode=master, the default) and
-- the value a correct shared-detoast implementation must produce (mode=patched).
-- A NULL target means "must not change". Cases marked "same" in target are the
-- regression guards; cases with a lower target are the wins. Cases 20-21 are
-- Phase 4 (joins) targets and are expected to still show master values after
-- Phase 1; run with -v phase=1 to score them as "same". Case 17 (HashAgg
-- directly above a scan that therefore has no projection) is a Phase 5 target:
-- the eflags permission rule cannot see that hash aggregation stores only the
-- grouping column. Case 23: one detoast saves 133 heap + 3 toast index blocks
-- in the EXPLAIN buffer counts.
--
-- Not covered here, deferred to the injection-point test module: holdable
-- cursors (need transaction control), Memoize (needs a repeating outer side),
-- and any JIT case on a build without --with-llvm. Case 23 measures workers via
-- shared_blks only (leader-local toast counters do not see worker fetches); case 27
-- uses the compressed column, where one detoast costs 10 toast blocks.

\set ON_ERROR_STOP on
\pset footer off
\if :{?mode} \else \set mode master \endif
\if :{?phase} \else \set phase 9 \endif

SET client_min_messages = warning;
SET jit = off;
SET max_parallel_workers_per_gather = 0;

DROP TABLE IF EXISTS dt_probe, dt_probe2;
DROP FUNCTION IF EXISTS probe(text, text, int);
DROP FUNCTION IF EXISTS dt_plpgsql_two_ops();

CREATE TABLE dt_probe (id int PRIMARY KEY, doc jsonb, small jsonb, txt text, docz jsonb);
CREATE TABLE dt_probe2 (id int PRIMARY KEY, doc jsonb);
ALTER TABLE dt_probe ALTER COLUMN doc SET STORAGE EXTERNAL,
                     ALTER COLUMN txt SET STORAGE EXTERNAL,
                     ALTER COLUMN docz SET COMPRESSION pglz;   -- build-independent size
ALTER TABLE dt_probe2 ALTER COLUMN doc SET STORAGE EXTERNAL;

INSERT INTO dt_probe
SELECT 1,
       '{"a": 1, "b": 2, "c": 3, "d": 4}'::jsonb
         || (SELECT jsonb_object_agg('pad' || i, md5(i::text) || repeat(md5((i * 7)::text), 40))
             FROM generate_series(1, 800) i),
       '{"a": 1, "b": 2, "c": 3, "d": 4}',
       'abc' || repeat(md5('x'), 6000),
       NULL;
UPDATE dt_probe SET docz = doc;          -- docz keeps EXTENDED storage: compressed out of line
INSERT INTO dt_probe2 SELECT 1, doc FROM dt_probe;
VACUUM ANALYZE dt_probe;
VACUUM ANALYZE dt_probe2;

CREATE FUNCTION dt_plpgsql_two_ops() RETURNS int LANGUAGE plpgsql AS $$
DECLARE a int; b int;
BEGIN
    SELECT (doc->>'a')::int, (doc->>'b')::int INTO a, b FROM dt_probe;
    RETURN a + b;
END $$;

SELECT reltoastrelid::regclass AS toastrel FROM pg_class WHERE oid = 'dt_probe'::regclass \gset
SELECT pg_column_toast_chunk_id(doc) AS chunk_before,
       pg_column_size(doc) AS doc_colsize, pg_column_size(docz) AS docz_colsize FROM dt_probe \gset

SELECT version() AS server,
       pg_jit_available()                              AS jit_available,
       pg_column_size(doc)                             AS doc_toast_bytes,
       pg_column_size(docz)                            AS docz_toast_bytes,
       pg_column_compression(docz)                     AS docz_compression,
       octet_length(doc::text)                         AS doc_text_bytes,
       octet_length(txt)                               AS txt_bytes,
       pg_size_pretty(pg_relation_size(:'toastrel'))   AS toast_heap_size,
       (SELECT count(*) FROM :toastrel)                AS toast_chunks
FROM dt_probe \gx

CREATE FUNCTION probe(q text, settings text DEFAULT NULL, reps int DEFAULT 3,
                      OUT toast_blks bigint, OUT shared_blks bigint,
                      OUT rows bigint, OUT ms numeric)
RETURNS record LANGUAGE plpgsql AS $$
DECLARE
    rels oid[] := ARRAY(SELECT unnest(ARRAY[c.reltoastrelid, i.indexrelid])
                        FROM pg_class c JOIN pg_index i ON i.indrelid = c.reltoastrelid
                        WHERE c.oid IN ('dt_probe'::regclass, 'dt_probe2'::regclass));
    saved text[] := '{}';
    kv text[];
    s text;
    b0 bigint;
    t0 timestamptz;
    j jsonb;
BEGIN
    IF settings IS NOT NULL THEN
        FOREACH s IN ARRAY string_to_array(settings, ',') LOOP
            kv := string_to_array(s, '=');
            saved := saved || ARRAY[kv[1], current_setting(kv[1])];
            PERFORM set_config(kv[1], kv[2], true);
        END LOOP;
    END IF;
    EXECUTE q;                      -- warm caches and the plan
    FOR r IN 1..reps LOOP
        b0 := (SELECT sum(pg_stat_get_xact_blocks_fetched(o)) FROM unnest(rels) o);
        t0 := clock_timestamp();
        EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF, FORMAT JSON) ' || q
            INTO j;
        ms := least(coalesce(ms, 1e9),
                    round((extract(epoch FROM clock_timestamp() - t0) * 1000)::numeric, 3));
        toast_blks := (SELECT sum(pg_stat_get_xact_blocks_fetched(o)) FROM unnest(rels) o) - b0;
    END LOOP;
    shared_blks := (j->0->'Plan'->>'Shared Hit Blocks')::bigint
                 + (j->0->'Plan'->>'Shared Read Blocks')::bigint;
    rows := (j->0->'Plan'->>'Actual Rows')::numeric::bigint;
    FOR i IN 1..coalesce(array_length(saved, 1), 0) BY 2 LOOP
        PERFORM set_config(saved[i], saved[i + 1], true);
    END LOOP;
END $$;

\set nl 'enable_hashjoin=off,enable_mergejoin=off'
\set hj 'enable_nestloop=off,enable_mergejoin=off'
\set par 'debug_parallel_query=on,max_parallel_workers_per_gather=2'
\set jit 'jit=on,jit_above_cost=0,jit_inline_above_cost=0,jit_optimize_above_cost=0'

CREATE TEMP TABLE results AS
WITH cases(n, label, settings, q, m_toast, m_shared, m_rows, p_toast, p_shared, min_phase) AS (VALUES
 -- n  label                                          settings   query                                                                    master: toast shared rows | patched: toast shared | phase
 ( 1, 'scan: 1 op',                                   NULL,      $$SELECT doc->'a' FROM dt_probe$$,                                                 133, NULL, 1,   133, NULL, 1),
 ( 2, 'scan: 2 ops in tlist',                         NULL,      $$SELECT doc->'a', doc->'b' FROM dt_probe$$,                                       266, NULL, 1,   133, NULL, 1),
 ( 3, 'scan: 4 ops in tlist',                         NULL,      $$SELECT doc->'a', doc->'b', doc->'c', doc->'d' FROM dt_probe$$,                   532, NULL, 1,   133, NULL, 1),
 ( 4, 'scan: 8 mixed ops (->, ->>, ?, @>)',           NULL,      $$SELECT doc->'a', doc->'b', doc->>'c', doc->>'d', doc ? 'a', doc ? 'b',
                                                                   doc @> '{"c":3}', doc @> '{"d":4}' FROM dt_probe$$,                            1064, NULL, 1,   133, NULL, 1),
 ( 5, 'scan: 3 ops in WHERE',                         NULL,      $$SELECT id FROM dt_probe WHERE doc ? 'a' AND doc @> '{"b":2}' AND (doc->>'c')::int = 3$$,
                                                                                                                                                    399, NULL, 1,   133, NULL, 1),
 ( 6, 'scan: 2 tlist ops + 2 WHERE ops',              NULL,      $$SELECT doc->'a', doc->'b' FROM dt_probe WHERE doc ? 'c' AND doc @> '{"d":4}'$$,  532, NULL, 1,   133, NULL, 1),
 ( 7, 'scan: chained doc->a->x twice',                NULL,      $$SELECT doc->'a'->'x', doc->'a'->'y' FROM dt_probe$$,                              266, NULL, 1,   133, NULL, 1),
 ( 8, 'lazy: first WHERE predicate fails',            NULL,      $$SELECT id FROM dt_probe WHERE doc ? 'zzz' AND doc @> '{"b":2}'$$,               133, NULL, 0,   133, NULL, 1),
 ( 9, 'subquery OFFSET 0 passing doc through',        NULL,      $$SELECT d->'a', d->'b', d->'c', d->'d'
                                                                   FROM (SELECT doc AS d FROM dt_probe OFFSET 0) s$$,                              532, NULL, 1,   133, NULL, 1),
 (10, 'subquery OFFSET 0 with doc || {}',             NULL,      $$SELECT d->'a', d->'b', d->'c', d->'d'
                                                                   FROM (SELECT doc || '{}' AS d FROM dt_probe OFFSET 0) s$$,                      133, NULL, 1,   133, NULL, 1),
 (11, 'jsonb_to_record extracting 4 keys',            NULL,      $$SELECT r.* FROM dt_probe, LATERAL jsonb_to_record(doc) AS r(a int, b int, c int, d int)$$,
                                                                                                                                                    133, NULL, 1,   133, NULL, 1),
 (12, 'control: inline column, 4 ops',                NULL,      $$SELECT small->'a', small->'b', small->'c', small->'d' FROM dt_probe$$,             0, NULL, 1,     0, NULL, 1),
 (13, 'raw readers keep toast-pointer semantics',     NULL,      format($$SELECT doc->'a' FROM dt_probe WHERE pg_column_size(doc) = %s
                                                                   AND pg_column_compression(doc) IS NULL AND pg_column_toast_chunk_id(doc) IS NOT NULL$$, :doc_colsize),
                                                                                                                                                    133, NULL, 1,   133, NULL, 1),
 (14, 'text: length + substr + starts_with + left',   NULL,      $$SELECT length(txt), substr(txt, 1, 5), starts_with(txt, 'abc'), left(txt, 3) FROM dt_probe$$,
                                                                                                                                                     28, NULL, 1,  NULL, NULL, 1),
 (15, 'Sort above scan projecting bare doc + 2 ops',  NULL,      $$SELECT doc, doc->'a', doc->'b' FROM dt_probe ORDER BY id$$,                     266, NULL, 1,  NULL, NULL, 1),
 (16, 'Sort above scan, doc not projected',           NULL,      $$SELECT doc->'a', doc->'b' FROM dt_probe ORDER BY id$$,                          266, NULL, 1,   133, NULL, 1),
 (17, 'HashAgg directly above scan, 2 WHERE ops',     NULL,      $$SELECT count(*) FROM dt_probe WHERE doc ? 'a' AND doc @> '{"b":2}' GROUP BY id$$,
                                                                                                                                                    266, NULL, 1,   133, NULL, 5),
 (18, 'hash agg on bare doc',                         NULL,      $$SELECT count(*) FROM dt_probe GROUP BY doc$$,                                    133, NULL, 1,  NULL, NULL, 1),
 (19, 'CTE MATERIALIZED then 2 ops',                  NULL,      $$WITH d AS MATERIALIZED (SELECT doc FROM dt_probe) SELECT doc->'a', doc->'b' FROM d$$,
                                                                                                                                                    266, NULL, 1,   133, NULL, 1),
 (20, 'hash join, 2 ops on probe side',               :'hj',     $$SELECT p.doc->'a', p.doc->'b' FROM dt_probe p JOIN dt_probe2 q ON p.id = q.id$$, 266, NULL, 1,   133, NULL, 4),
 (21, 'nested loop, 2 ops on probe side',             :'nl',     $$SELECT p.doc->'a', p.doc->'b' FROM dt_probe p JOIN dt_probe2 q ON p.id = q.id$$, 266, NULL, 1,   133, NULL, 4),
 (22, 'lateral subquery pulled up',                   NULL,      $$SELECT s.a, s.b FROM dt_probe p, LATERAL (SELECT p.doc->'a' AS a, p.doc->'b' AS b) s$$,
                                                                                                                                                    266, NULL, 1,   133, NULL, 1),
 (23, 'parallel seq scan, workers evaluate 2 ops',    :'par',    $$SELECT doc->'a', doc->'b' FROM dt_probe$$,                                         0,  333, 1,     0,  197, 1),
 (24, 'UPDATE with 2 WHERE ops (pointer kept)',       NULL,      $$UPDATE dt_probe SET small = small WHERE doc ? 'a' AND doc @> '{"b":2}'$$,        266, NULL, 0,   133, NULL, 1),
 (25, 'PL/pgSQL function with 2 ops',                 NULL,      $$SELECT dt_plpgsql_two_ops()$$,                                                  266, NULL, 1,   133, NULL, 1),
 (26, 'JIT on: 4 ops (no-op without llvm)',           :'jit',    $$SELECT doc->'a', doc->'b', doc->'c', doc->'d' FROM dt_probe$$,                   532, NULL, 1,   133, NULL, 1),
 (27, 'raw readers on compressed column (docz)',      NULL,      format($$SELECT docz->'a', docz->'b' FROM dt_probe WHERE pg_column_size(docz) = %s
                                                                   AND pg_column_compression(docz) IS NOT NULL AND pg_column_toast_chunk_id(docz) IS NOT NULL$$, :docz_colsize),
                                                                                                                                                     20, NULL, 1,  NULL, NULL, 1),
 (28, 'GroupAgg via Sort above scan, 2 WHERE ops',    'enable_hashagg=off', $$SELECT count(*) FROM dt_probe WHERE doc ? 'a' AND doc @> '{"b":2}' GROUP BY id$$,
                                                                                                                                                    266, NULL, 1,   133, NULL, 1),
 (29, 'correlated subplan scan (rtoffset > 0), 2 ops', NULL,      $$SELECT (SELECT q.doc->'a' || q.doc->'b' FROM dt_probe2 q WHERE q.id = p.id) FROM dt_probe p$$,
                                                                                                                                                    266, NULL, 1,   133, NULL, 1),
 (30, 'FOR UPDATE through LockRows, 2 ops',            NULL,      $$SELECT doc->'a', doc->'b' FROM dt_probe FOR UPDATE$$,                           266, NULL, 1,   133, NULL, 1)
)
SELECT c.n, c.label, r.toast_blks, r.shared_blks, r.rows, r.ms,
       CASE WHEN :'mode' = 'patched' AND c.min_phase <= :phase THEN c.p_toast  ELSE c.m_toast  END::bigint AS exp_toast,
       CASE WHEN :'mode' = 'patched' AND c.min_phase <= :phase THEN c.p_shared ELSE c.m_shared END::bigint AS exp_shared,
       c.m_rows::bigint AS exp_rows,
       CASE WHEN c.p_toast IS NOT NULL AND c.p_toast <> c.m_toast THEN c.p_toast::text
            WHEN c.p_shared IS NOT NULL AND c.p_shared <> c.m_shared THEN 'shared ' || c.p_shared ELSE 'same' END AS patched_target
FROM cases c, LATERAL probe(c.q, c.settings) r;

\echo
\echo 'mode:' :mode '  (toast_blks / 133 = detoasts of the 1 MB document; NULL expectation = informational)'
SELECT n, label, toast_blks, exp_toast, shared_blks, exp_shared, rows, exp_rows, patched_target,
       CASE WHEN (exp_toast IS NULL OR toast_blks = exp_toast)
             AND (exp_shared IS NULL OR shared_blks = exp_shared)
             AND rows = exp_rows THEN 'ok' ELSE 'FAIL' END AS status,
       ms
FROM results ORDER BY n;

SELECT pg_column_toast_chunk_id(doc) = :chunk_before AS toast_pointer_identity_kept_after_update FROM dt_probe;

SELECT count(*) FILTER (WHERE NOT ((exp_toast IS NULL OR toast_blks = exp_toast)
                                   AND (exp_shared IS NULL OR shared_blks = exp_shared)
                                   AND rows = exp_rows)) AS failures,
       bool_or(NOT ((exp_toast IS NULL OR toast_blks = exp_toast)
                    AND (exp_shared IS NULL OR shared_blks = exp_shared)
                    AND rows = exp_rows)) AS failed
FROM results \gset
SELECT NOT (pg_column_toast_chunk_id(doc) = :chunk_before) AS identity_lost FROM dt_probe \gset

DROP FUNCTION probe(text, text, int);
DROP FUNCTION dt_plpgsql_two_ops();
DROP TABLE dt_probe, dt_probe2;

\if :identity_lost
\echo 'FAIL: UPDATE rewrote the toast pointer of doc'
SELECT 1/0;
\endif
\echo 'failures:' :failures
\if :failed
\echo 'FAIL: guard cases deviate from expectation (mode' :mode ')'
SELECT 1/0;
\endif
