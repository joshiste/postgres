-- Detoasting a scan column once per row when several expressions reference it.
--
-- detoast_attr() runs an injection point whenever it fetches an out-of-line
-- value or decompresses an inline one, so with the points attached in notice
-- mode the number of NOTICE lines after a statement is the number of detoasts
-- it performed.

CREATE TABLE sd (id int PRIMARY KEY, doc jsonb, small jsonb, txt text, ctxt text);
-- doc and txt out of line and uncompressed; ctxt compressed but inline
ALTER TABLE sd ALTER COLUMN doc SET STORAGE EXTERNAL,
               ALTER COLUMN txt SET STORAGE EXTERNAL,
               ALTER COLUMN ctxt SET COMPRESSION pglz;
INSERT INTO sd
SELECT 1,
       '{"a": 1, "b": 2, "c": 3}'::jsonb
         || (SELECT jsonb_object_agg('k' || i, md5(i::text) || repeat(md5((i * 3)::text), 8))
             FROM generate_series(1, 200) i),
       '{"a": 1, "b": 2}',
       'abc' || repeat(md5('x'), 200),
       repeat('x', 50000);
VACUUM ANALYZE sd;
SELECT pg_column_size(doc) > 8192 AS doc_external,
       pg_column_toast_chunk_id(doc) IS NOT NULL AS doc_has_chunks,
       pg_column_toast_chunk_id(ctxt) IS NULL AS ctxt_inline,
       pg_column_compression(ctxt) AS ctxt_compression
FROM sd;

CREATE EXTENSION injection_points;
SELECT injection_points_set_local();
SELECT injection_points_attach('detoast-attr-external', 'notice');
SELECT injection_points_attach('detoast-attr-compressed', 'notice');

-- one reference: one detoast
SELECT doc->'a' FROM sd;
-- two references in the target list: one detoast
SELECT doc->'a', doc->'b' FROM sd;
-- eight mixed operators: one detoast
SELECT doc->'a', doc->>'b', doc ? 'c', doc @> '{"a": 1}', doc->'b', doc->>'c', doc ? 'a', doc @> '{"c": 3}' FROM sd;
-- references in WHERE and in the target list: one detoast
SELECT doc->'a' FROM sd WHERE doc ? 'b' AND doc @> '{"c": 3}';
-- lazy: the first predicate fails, so the row is detoasted once and never again
SELECT id FROM sd WHERE doc ? 'zzz' AND doc @> '{"c": 3}';
-- a chained operator counts once for the inner Var
SELECT doc->'a'->'x', doc->'a'->'y' FROM sd;
-- EXPLAIN shows what the scan detoasts in place
EXPLAIN (VERBOSE, COSTS OFF) SELECT doc->'a', doc->'b' FROM sd WHERE doc ? 'c';

-- representation readers veto the optimization: two detoasts, stored sizes reported
SELECT pg_column_size(doc) > 8192 AS stored_size, pg_column_compression(doc) IS NULL AS uncompressed,
       doc->'a', doc->'b' FROM sd;
-- slice and size readers do not count as detoasting references: no detoast at all
SELECT octet_length(txt), substr(txt, 1, 3), starts_with(txt, 'abc'), left(txt, 3) FROM sd;
-- a compressed inline value is decompressed once for two full readers
SELECT length(md5(ctxt)), ctxt = ctxt FROM sd;

-- a bare Var projected under a Sort must keep the toast pointer: two detoasts
WITH s AS MATERIALIZED (SELECT doc->'a' AS a, doc->'b' AS b, doc AS d FROM sd ORDER BY id)
SELECT a, b FROM s;
-- the same expressions without the bare Var under the Sort: one detoast
WITH s AS MATERIALIZED (SELECT doc->'a' AS a, doc->'b' AS b FROM sd ORDER BY id)
SELECT a, b FROM s;
-- a CTE scan over a materialized toast pointer: one detoast
WITH d AS MATERIALIZED (SELECT doc FROM sd) SELECT doc->'a', doc->'b' FROM d;
-- a scan inside a correlated subplan: one detoast
SELECT (SELECT q.doc->'a' || q.doc->'b' FROM sd q WHERE q.id = p.id) FROM sd p;
-- through LockRows: one detoast
SELECT doc->'a', doc->'b' FROM sd FOR UPDATE;
-- an UPDATE whose WHERE references the column twice keeps the toast pointer
CREATE TEMP TABLE before AS SELECT pg_column_toast_chunk_id(doc) AS chunk FROM sd;
UPDATE sd SET small = small WHERE doc ? 'a' AND doc @> '{"b": 2}';
SELECT pg_column_toast_chunk_id(doc) = (SELECT chunk FROM before) AS pointer_kept FROM sd;
-- parallel workers detoast once as well; locally attached injection points are
-- not seen by worker processes, so compare buffer counts instead: the second
-- reference must not fetch the document's toast chunks again (dozens of
-- blocks; a fresh worker's catalog reads make the counts vary by a few)
CREATE FUNCTION shared_blocks(q text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE j jsonb;
BEGIN
    EXECUTE q;                                  -- warm the cache
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF, FORMAT JSON) ' || q INTO j;
    RETURN (j->0->'Plan'->>'Shared Hit Blocks')::bigint + (j->0->'Plan'->>'Shared Read Blocks')::bigint;
END $$;
SET debug_parallel_query = on;
SELECT abs(shared_blocks($$SELECT doc->'a', doc->'b' FROM sd$$) - shared_blocks($$SELECT doc->'a' FROM sd$$)) < 10 AS no_extra_toast_fetches;
RESET debug_parallel_query;
DROP FUNCTION shared_blocks(text);
-- joins: the expressions are evaluated at the join, the value lives in the
-- child's slot; hash join (probe side), nested loop (both sides) and the outer
-- side of a merge join detoast once, the inner side of a merge join is left alone
CREATE TABLE sd2 (id int PRIMARY KEY, doc jsonb);
ALTER TABLE sd2 ALTER COLUMN doc SET STORAGE EXTERNAL;
INSERT INTO sd2 SELECT id, doc FROM sd;
SET enable_nestloop = off; SET enable_mergejoin = off;
EXPLAIN (VERBOSE, COSTS OFF) SELECT p.doc->'a', p.doc->'b' FROM sd p JOIN sd2 q ON p.id = q.id;
SELECT p.doc->'a', p.doc->'b' FROM sd p JOIN sd2 q ON p.id = q.id;
SELECT p.doc->'a', p.doc->'b', q.doc->'a', q.doc->'b' FROM sd p JOIN sd2 q ON p.id = q.id;
RESET enable_nestloop; RESET enable_mergejoin;
SET enable_hashjoin = off; SET enable_mergejoin = off;
SELECT p.doc->'a', p.doc->'b', q.doc->'a', q.doc->'b' FROM sd p JOIN sd2 q ON p.id = q.id;
RESET enable_hashjoin; RESET enable_mergejoin;
SET enable_hashjoin = off; SET enable_nestloop = off;
EXPLAIN (COSTS OFF) SELECT p.doc->'a', p.doc->'b', q.doc->'a', q.doc->'b' FROM sd p JOIN sd2 q ON p.id = q.id;
SELECT p.doc->'a', p.doc->'b', q.doc->'a', q.doc->'b' FROM sd p JOIN sd2 q ON p.id = q.id;
RESET enable_hashjoin; RESET enable_nestloop;
-- a join key is never detoasted in place, even when referenced again
SET enable_nestloop = off; SET enable_mergejoin = off;
SELECT count(*) FROM sd p JOIN sd2 q ON p.doc = q.doc WHERE p.doc ? 'a' AND p.doc @> '{"b": 2}';
RESET enable_nestloop; RESET enable_mergejoin;
-- an ancestor reading a column the join projects bare still sees the stored
-- form, even though the join itself detoasts that column for its expressions
SELECT pg_column_toast_chunk_id(d) IS NOT NULL AS pointer_kept, x
FROM (SELECT p.doc AS d, (p.doc->>'a')::int + (p.doc->>'b')::int + (q.doc->>'a')::int AS x
      FROM sd p JOIN sd2 q ON p.id = q.id OFFSET 0) s;
-- an outer column passed down as a nestloop parameter keeps its pointer too,
-- since the inner side (Memoize) may keep the parameter as a cache key; both
-- with a parent that stores rows and with one that consumes them
CREATE INDEX sd2_doc_hash ON sd2 USING hash (doc);
SET enable_hashjoin = off; SET enable_mergejoin = off; SET enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT count(*) FROM sd o JOIN sd2 q ON q.doc = o.doc WHERE o.doc ? 'a' AND o.doc @> '{"b": 2}';
SELECT count(*) FROM sd o JOIN sd2 q ON q.doc = o.doc WHERE o.doc ? 'a' AND o.doc @> '{"b": 2}';
SELECT (q.doc->>'a')::int FROM sd o JOIN sd2 q ON q.doc = o.doc WHERE o.doc ? 'a' AND o.doc @> '{"b": 2}';
RESET enable_hashjoin; RESET enable_mergejoin; RESET enable_seqscan;
DROP TABLE sd2;
-- a scan without projection under a parent that copies the physical tuple
-- (Sort, hashed Agg over other columns) still detoasts once
WITH s AS MATERIALIZED (SELECT * FROM sd WHERE doc ? 'a' AND doc @> '{"b": 2}' ORDER BY id)
SELECT count(*) FROM s;
SET enable_sort = off;
EXPLAIN (VERBOSE, COSTS OFF) SELECT count(*) FROM sd WHERE doc ? 'a' AND doc @> '{"b": 2}' GROUP BY id;
SELECT count(*) FROM sd WHERE doc ? 'a' AND doc @> '{"b": 2}' GROUP BY id;
-- but a hashed grouping column is copied out of the slot, so it is left alone
SELECT count(*) FROM sd WHERE doc ? 'a' AND doc @> '{"b": 2}' GROUP BY doc;
RESET enable_sort;
-- aggregate arguments referencing the same input column detoast it once
EXPLAIN (VERBOSE, COSTS OFF) SELECT sum((doc->>'a')::int), sum((doc->>'b')::int) FROM sd;
SELECT sum((doc->>'a')::int), sum((doc->>'b')::int) FROM sd;
-- unless the column itself is an aggregate argument, whose state may keep it
SELECT sum((doc->>'a')::int), sum((doc->>'b')::int), count(doc) FROM sd;
-- a representation reader in an ancestor still sees the stored form: the
-- scan below keeps the toast pointer and detoasts per reference
SELECT pg_column_toast_chunk_id(d) IS NOT NULL AS pointer_kept, a, b
FROM (SELECT doc AS d, doc->'a' AS a, doc->'b' AS b FROM sd OFFSET 0) s;
-- a receiver that keeps the rows (here SPI, via a set-returning function) gets
-- toast pointers, not full values, so the scan detoasts per reference
CREATE FUNCTION sd_rows() RETURNS TABLE (d jsonb, a jsonb, b jsonb) LANGUAGE plpgsql AS $$
BEGIN RETURN QUERY SELECT doc, doc->'a', doc->'b' FROM sd; END $$;
SELECT pg_column_toast_chunk_id(d) IS NOT NULL AS pointer_kept, a, b FROM sd_rows();
DROP FUNCTION sd_rows();
-- an aggregate that keeps its argument leaves the scan below it alone too
SELECT count(DISTINCT doc) FROM sd WHERE doc ? 'a' AND doc @> '{"b": 2}';
-- a column handed on whole through RelabelType, CASE, COALESCE, GREATEST or
-- NULLIF is projected bare like a plain Var: an ancestor raw reader still sees
-- the pointer (two detoasts for the two LIKEs, none for the projection)
SELECT pg_column_toast_chunk_id(t) IS NOT NULL AS pointer_kept
FROM (SELECT txt COLLATE "C" AS t FROM sd WHERE txt LIKE 'abc%' AND txt LIKE '%a6' OFFSET 0) s;
SELECT pg_column_toast_chunk_id(d) IS NOT NULL AS pointer_kept
FROM (SELECT CASE WHEN id > 0 THEN doc END AS d FROM sd WHERE doc ? 'a' AND doc ? 'b' OFFSET 0) s;
-- and under a Sort the pointer, not the detoasted value, is stored: two
-- detoasts in the scan, none for the null test outside
SELECT a, b, d IS NOT NULL AS has_doc
FROM (SELECT doc->'a' AS a, doc->'b' AS b, COALESCE(doc, '{}') AS d FROM sd ORDER BY small->>'a') s;
-- a holdable cursor is persisted through a receiver that detoasts anyway: the
-- scan still detoasts once while the cursor is materialized at COMMIT
BEGIN;
DECLARE hc CURSOR WITH HOLD FOR SELECT doc->'a', doc->'b' FROM sd;
COMMIT;
FETCH ALL FROM hc;
CLOSE hc;
-- a PL/pgSQL FOR loop fetches through SPI: one detoast per row
DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT doc->'a' AS a, doc->'b' AS b FROM sd LOOP
        RAISE NOTICE 'row: % %', r.a, r.b;
    END LOOP;
END $$;
-- with JIT forced on (a no-op on builds without LLVM) the count is the same
SET jit = on; SET jit_above_cost = 0; SET jit_inline_above_cost = 0; SET jit_optimize_above_cost = 0;
SELECT doc->'a', doc->'b' FROM sd;
RESET jit; RESET jit_above_cost; RESET jit_inline_above_cost; RESET jit_optimize_above_cost;
-- an inline column never detoasts
SELECT small->'a', small->'b' FROM sd;
-- switching the feature off restores one detoast per reference
SET shared_detoast = off;
SELECT doc->'a', doc->'b' FROM sd;
RESET shared_detoast;

SELECT injection_points_detach('detoast-attr-external');
SELECT injection_points_detach('detoast-attr-compressed');
DROP TABLE sd;
