-- Detoasting a column once per row when several expressions reference it.
--
-- The detoasted copy is kept beside the slot (tts_detoasted); tts_values keeps
-- the stored datum.  Only argument positions of functions and operators read
-- the copy, so anything that stores rows, passes the column on whole, or
-- inspects its stored form sees the toast pointer without needing a rule for
-- it.  The cases below pin the number of detoasts per query shape and, where
-- a pointer must survive, that it does.
--
-- No statement here forces JIT: sanitizer builds crash inside LLVM on any
-- forced JIT compilation.  Run the whole file with jit_above_cost = 0 (and
-- the inline/optimize costs) via PG_TEST_INITDB_EXTRA_OPTS to cover the
-- JIT-compiled form of the new expression steps.
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
-- the points are attached in this backend only, so nothing may run in a
-- parallel worker (some CI runs default to debug_parallel_query = regress)
SET debug_parallel_query = off;
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
-- EXPLAIN shows what the scan detoasts once per row
EXPLAIN (VERBOSE, COSTS OFF) SELECT doc->'a', doc->'b' FROM sd WHERE doc ? 'c';

-- functions that inspect the stored form get the stored datum while the
-- other references share: one detoast, stored sizes reported
SELECT pg_column_size(doc) > 8192 AS stored_size, pg_column_compression(doc) IS NULL AS uncompressed,
       doc->'a', doc->'b' FROM sd;
-- slice and size readers do not count as detoasting references: no detoast at all
SELECT octet_length(txt), substr(txt, 1, 3), starts_with(txt, 'abc'), left(txt, 3) FROM sd;
-- a compressed inline value is decompressed once for two full readers
SELECT length(md5(ctxt)), ctxt = ctxt FROM sd;

-- a bare Var projected under a Sort stores the toast pointer, and the
-- expressions still share: one detoast
WITH s AS MATERIALIZED (SELECT doc->'a' AS a, doc->'b' AS b, doc AS d FROM sd ORDER BY id)
SELECT a, b, pg_column_toast_chunk_id(d) IS NOT NULL AS pointer_kept FROM s;
-- a CTE scan over a materialized toast pointer: one detoast
WITH d AS MATERIALIZED (SELECT doc FROM sd) SELECT doc->'a', doc->'b' FROM d;
-- a scan inside a correlated subplan: one detoast
SELECT (SELECT q.doc->'a' || q.doc->'b' FROM sd q WHERE q.id = p.id) FROM sd p;
-- through LockRows: one detoast
SELECT doc->'a', doc->'b' FROM sd FOR UPDATE;
-- an UPDATE whose WHERE references the column twice detoasts once and keeps
-- the toast pointer in the new tuple
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
SET debug_parallel_query = off;
DROP FUNCTION shared_blocks(text);
-- joins: the expressions are evaluated at the join and the copy is kept
-- beside the child's slot; hash join (probe side), nested loop (both sides)
-- and both sides of a merge join detoast once
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
EXPLAIN (VERBOSE, COSTS OFF) SELECT p.doc->'a', p.doc->'b', q.doc->'a', q.doc->'b' FROM sd p JOIN sd2 q ON p.id = q.id;
SELECT p.doc->'a', p.doc->'b', q.doc->'a', q.doc->'b' FROM sd p JOIN sd2 q ON p.id = q.id;
RESET enable_hashjoin; RESET enable_nestloop;
-- a projecting child carries its copy along with the stored datum, so a
-- join reading the child's slot directly finds it: one detoast for the
-- scan's quals and the join's expressions together
SET enable_hashjoin = off; SET enable_mergejoin = off;
EXPLAIN (VERBOSE, COSTS OFF) SELECT p.doc->'a', p.doc->'b' FROM sd p JOIN sd2 q ON p.id = q.id WHERE p.doc ? 'a' AND p.doc @> '{"b": 2}';
SELECT p.doc->'a', p.doc->'b' FROM sd p JOIN sd2 q ON p.id = q.id WHERE p.doc ? 'a' AND p.doc @> '{"b": 2}';
RESET enable_hashjoin; RESET enable_mergejoin;
-- a hash join key on the probe side is hashed and then compared from one
-- copy; the hashed side is hashed once when the table is built and compared
-- per match from the stored tuple, and the scan's quals share among
-- themselves (four detoasts: scan quals, table build, probe key, match)
SET enable_nestloop = off; SET enable_mergejoin = off;
EXPLAIN (VERBOSE, COSTS OFF) SELECT count(*) FROM sd p JOIN sd2 q ON p.doc = q.doc WHERE p.doc ? 'a' AND p.doc @> '{"b": 2}';
SELECT count(*) FROM sd p JOIN sd2 q ON p.doc = q.doc WHERE p.doc ? 'a' AND p.doc @> '{"b": 2}';
RESET enable_nestloop; RESET enable_mergejoin;
-- a merge join key that a join filter references again is compared from the
-- same copy: one detoast per side
SET enable_nestloop = off; SET enable_hashjoin = off;
EXPLAIN (VERBOSE, COSTS OFF) SELECT count(*) FROM sd p JOIN sd2 q ON p.doc = q.doc AND p.doc ? (q.doc->>'k1');
SELECT count(*) FROM sd p JOIN sd2 q ON p.doc = q.doc AND p.doc ? (q.doc->>'k1');
RESET enable_nestloop; RESET enable_hashjoin;
-- an ancestor reading a column the join projects bare sees the stored form
-- (the bare column comes last in the target list, after the expressions
-- that detoast it)
SELECT pg_column_toast_chunk_id(d) IS NOT NULL AS pointer_kept, x
FROM (SELECT (p.doc->>'a')::int + (p.doc->>'b')::int + (q.doc->>'a')::int AS x, p.doc AS d
      FROM sd p JOIN sd2 q ON p.id = q.id OFFSET 0) s;
-- an outer column passed down as a nestloop parameter goes down as the
-- stored pointer (Memoize keeps it as a cache key) while the outer quals
-- share; both with a parent that stores rows and with one that does not
CREATE INDEX sd2_doc_hash ON sd2 USING hash (doc);
SET enable_hashjoin = off; SET enable_mergejoin = off; SET enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT count(*) FROM sd o JOIN sd2 q ON q.doc = o.doc WHERE o.doc ? 'a' AND o.doc @> '{"b": 2}';
SELECT count(*) FROM sd o JOIN sd2 q ON q.doc = o.doc WHERE o.doc ? 'a' AND o.doc @> '{"b": 2}';
SELECT (q.doc->>'a')::int FROM sd o JOIN sd2 q ON q.doc = o.doc WHERE o.doc ? 'a' AND o.doc @> '{"b": 2}';
RESET enable_hashjoin; RESET enable_mergejoin; RESET enable_seqscan;
DROP TABLE sd2;
-- a scan without projection under a parent that stores its rows (Sort,
-- hashed Agg) detoasts once; the parent copies the tuple, not the copy
WITH s AS MATERIALIZED (SELECT * FROM sd WHERE doc ? 'a' AND doc @> '{"b": 2}' ORDER BY id)
SELECT count(*) FROM s;
SET enable_sort = off;
EXPLAIN (VERBOSE, COSTS OFF) SELECT count(*) FROM sd WHERE doc ? 'a' AND doc @> '{"b": 2}' GROUP BY id;
SELECT count(*) FROM sd WHERE doc ? 'a' AND doc @> '{"b": 2}' GROUP BY id;
-- a hashed grouping column is copied out of the slot as the stored pointer
-- (its hash is computed from the stored datum, hence one more detoast)
SELECT count(*) FROM sd WHERE doc ? 'a' AND doc @> '{"b": 2}' GROUP BY doc;
-- an aggregated column the hashed Agg would spill by value is the stored
-- pointer too: the scan shares its two references, the aggregate argument
-- detoasts on its own
EXPLAIN (VERBOSE, COSTS OFF) SELECT id, sum((doc->>'a')::int) FROM sd WHERE doc ? 'a' AND doc @> '{"b": 2}' GROUP BY id;
SELECT id, sum((doc->>'a')::int) FROM sd WHERE doc ? 'a' AND doc @> '{"b": 2}' GROUP BY id;
RESET enable_sort;
-- aggregate arguments referencing the same input column detoast it once
EXPLAIN (VERBOSE, COSTS OFF) SELECT sum((doc->>'a')::int), sum((doc->>'b')::int) FROM sd;
SELECT sum((doc->>'a')::int), sum((doc->>'b')::int) FROM sd;
-- an aggregate taking the column whole gets the stored pointer, the others
-- still share: one detoast
SELECT sum((doc->>'a')::int), sum((doc->>'b')::int), count(doc) FROM sd;
-- a function inspecting the stored form in an ancestor sees it (bare column
-- last, see above): one detoast, pointer kept
SELECT pg_column_toast_chunk_id(d) IS NOT NULL AS pointer_kept, a, b
FROM (SELECT doc->'a' AS a, doc->'b' AS b, doc AS d FROM sd OFFSET 0) s;
-- the same through an Append
CREATE TABLE sdp (id int, doc jsonb) PARTITION BY RANGE (id);
CREATE TABLE sdp1 PARTITION OF sdp FOR VALUES FROM (0) TO (10);
CREATE TABLE sdp2 PARTITION OF sdp FOR VALUES FROM (10) TO (20);
ALTER TABLE sdp ALTER COLUMN doc SET STORAGE EXTERNAL;
INSERT INTO sdp SELECT i, doc FROM sd, (VALUES (1), (12)) v(i);
VACUUM ANALYZE sdp;
SELECT pg_column_toast_chunk_id(d) IS NOT NULL AS pointer_kept, a, b
FROM (SELECT doc->'a' AS a, doc->'b' AS b, doc AS d FROM sdp OFFSET 0) s;
-- partition scans under a storing parent: one detoast per row
EXPLAIN (VERBOSE, COSTS OFF) SELECT * FROM sdp WHERE doc ? 'a' AND doc @> '{"b": 2}' ORDER BY id;
WITH s AS MATERIALIZED (SELECT * FROM sdp WHERE doc ? 'a' AND doc @> '{"b": 2}' ORDER BY id)
SELECT count(*) FROM s;
DROP TABLE sdp;
-- a column handed to a correlated subplan as a parameter goes down as the
-- stored pointer: one detoast for the two quals, pointer kept inside
SELECT (SELECT pg_column_toast_chunk_id(p.doc) IS NOT NULL) AS pointer_kept
FROM sd p WHERE p.doc ? 'a' AND p.doc @> '{"b": 2}';
-- a receiver that keeps the rows (here SPI, via a set-returning function) gets
-- toast pointers, not full values, and the scan still shares
CREATE FUNCTION sd_rows() RETURNS TABLE (d jsonb, a jsonb, b jsonb) LANGUAGE plpgsql AS $$
BEGIN RETURN QUERY SELECT doc, doc->'a', doc->'b' FROM sd; END $$;
SELECT pg_column_toast_chunk_id(d) IS NOT NULL AS pointer_kept, a, b FROM sd_rows();
DROP FUNCTION sd_rows();
-- an aggregate that keeps its argument keeps the stored pointer
SELECT count(DISTINCT doc) FROM sd WHERE doc ? 'a' AND doc @> '{"b": 2}';
-- a column handed on whole through RelabelType, CASE, COALESCE, GREATEST or
-- NULLIF is projected like a plain Var: the pointer is kept and the other
-- references share
SELECT pg_column_toast_chunk_id(t) IS NOT NULL AS pointer_kept
FROM (SELECT txt COLLATE "C" AS t FROM sd WHERE txt LIKE 'abc%' AND txt LIKE '%a6' OFFSET 0) s;
SELECT pg_column_toast_chunk_id(d) IS NOT NULL AS pointer_kept
FROM (SELECT CASE WHEN id > 0 THEN doc END AS d FROM sd WHERE doc ? 'a' AND doc ? 'b' OFFSET 0) s;
SELECT pg_column_toast_chunk_id(d) IS NOT NULL AS pointer_kept, pg_column_toast_chunk_id(n) IS NOT NULL AS pointer_kept2
FROM (SELECT GREATEST(doc, '{}') AS d, NULLIF(doc, '{}') AS n FROM sd WHERE doc ? 'a' AND doc ? 'b' OFFSET 0) s;
-- and under a Sort the pointer, not the copy, is stored
SELECT a, b, pg_column_toast_chunk_id(d) IS NOT NULL AS pointer_kept
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
-- shapes not covered above: several rows including a NULL, EXTENDED storage
-- (out of line and compressed), bytea, outer joins, other storing statements,
-- subscripting and jsonpath, kept aggregate arguments, window functions,
-- grouping sets, a scrollable cursor, set operations and a bitmap heap scan
CREATE TABLE sd3 (id int PRIMARY KEY, doc jsonb, blob bytea);
ALTER TABLE sd3 ALTER COLUMN doc SET STORAGE EXTENDED,
                ALTER COLUMN doc SET COMPRESSION pglz,
                ALTER COLUMN blob SET STORAGE EXTERNAL;
INSERT INTO sd3
SELECT i, CASE WHEN i = 2 THEN NULL ELSE
       ('{"a": ' || i || ', "b": 2}')::jsonb
         || (SELECT jsonb_object_agg('k' || j, repeat(md5((i * j)::text), 8)) FROM generate_series(1, 200) j) END,
       CASE WHEN i = 2 THEN NULL ELSE decode(repeat(md5(i::text), 600), 'hex') END
FROM generate_series(1, 3) i;
VACUUM ANALYZE sd3;
SELECT id, pg_column_compression(doc) AS compression, pg_column_toast_chunk_id(doc) IS NOT NULL AS out_of_line FROM sd3 ORDER BY id;
-- out of line and compressed (one fetch, decompressed by the same call), three
-- rows with one NULL: one detoast per non-null row
SELECT id, doc->'a', doc->'b', doc ? 'k1' FROM sd3 ORDER BY id;
-- bytea: two references, one detoast per row
SELECT id, length(blob) > 0, position('\x00'::bytea IN blob) FROM sd3 ORDER BY id;
-- subscripting and jsonpath count as detoasting references
SELECT doc['a'], doc['b'], jsonb_path_query_first(doc, '$.a'), doc @? '$.b' FROM sd3 WHERE id = 1;
-- left join: the null-extended side arrives as a null-filled slot
SET enable_nestloop = off; SET enable_mergejoin = off;
SELECT s.id, q.doc->'a', q.doc->'b' FROM sd s LEFT JOIN sd3 q ON q.id = s.id + 5 ORDER BY s.id;
SELECT s.id, q.doc->'a', q.doc->'b' FROM sd s LEFT JOIN sd3 q ON q.id = s.id ORDER BY s.id;
RESET enable_nestloop; RESET enable_mergejoin;
-- statements that store the column store the pointer while the WHERE
-- references share: one detoast per row for INSERT ... SELECT and for
-- CREATE TABLE AS
CREATE TABLE sd4 (LIKE sd3);
INSERT INTO sd4 SELECT id, doc, blob FROM sd3 WHERE doc ? 'a' AND doc ? 'b';
SELECT pg_column_toast_chunk_id(doc) IS NOT NULL AS pointer_kept, id FROM sd4 ORDER BY id;
CREATE TABLE sd5 AS SELECT id, doc FROM sd3 WHERE doc ? 'a' AND doc ? 'b';
SELECT pg_column_toast_chunk_id(doc) IS NOT NULL AS pointer_kept, id FROM sd5 ORDER BY id;
-- an aggregate that keeps its argument whole gets the stored pointer
SELECT jsonb_agg(doc ORDER BY id) IS NOT NULL FROM sd3 WHERE doc ? 'a' AND doc ? 'b';
-- window functions: the output expressions are evaluated by the WindowAgg on
-- rows read back from its tuplestore and share there; the scan's single
-- qual reference detoasts on its own (two detoasts per row)
EXPLAIN (VERBOSE, COSTS OFF) SELECT doc->'a', doc->'b', count(*) OVER () FROM sd3 WHERE doc ? 'k1';
SELECT doc->'a', doc->'b', count(*) OVER () FROM sd3 WHERE doc ? 'k1' ORDER BY 1;
-- grouping sets: the scan below shares like under any other parent
SELECT count(*) FROM sd3 WHERE doc ? 'a' AND doc ? 'b' GROUP BY GROUPING SETS ((id), ());
-- a scrollable cursor rescans and reads backward: one detoast per fetched row
BEGIN;
DECLARE sc SCROLL CURSOR FOR SELECT id, doc->'a', doc->'b' FROM sd3 ORDER BY id;
FETCH ALL FROM sc;
FETCH BACKWARD 2 FROM sc;
CLOSE sc;
COMMIT;
-- set operations: each input projects its expressions, so each scan shares
SELECT count(*) FROM (SELECT doc->'a', doc->'b' FROM sd3 WHERE doc ? 'a' UNION SELECT doc->'a', doc->'b' FROM sd3 WHERE doc ? 'b') u;
-- bitmap heap scan
CREATE INDEX sd3_docidx ON sd3 USING hash (id);
SET enable_seqscan = off; SET enable_indexscan = off;
EXPLAIN (VERBOSE, COSTS OFF) SELECT doc->'a', doc->'b' FROM sd3 WHERE id = 1;
SELECT doc->'a', doc->'b' FROM sd3 WHERE id = 1;
RESET enable_seqscan; RESET enable_indexscan;
DROP TABLE sd3, sd4, sd5;
-- an inline column never detoasts
SELECT small->'a', small->'b' FROM sd;
-- switching the feature off restores one detoast per reference and skips the
-- planning work: no Pre-detoast line
SET shared_detoast = off;
SELECT doc->'a', doc->'b' FROM sd;
EXPLAIN (VERBOSE, COSTS OFF) SELECT doc->'a', doc->'b' FROM sd;
RESET shared_detoast;

SELECT injection_points_detach('detoast-attr-external');
SELECT injection_points_detach('detoast-attr-compressed');
DROP TABLE sd;
