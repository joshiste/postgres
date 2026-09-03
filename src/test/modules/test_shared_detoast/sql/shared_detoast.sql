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
-- (parallel workers are covered elsewhere: injection points attached locally are
-- not seen by worker processes)
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
DROP TABLE sd2;
-- an inline column never detoasts
SELECT small->'a', small->'b' FROM sd;
-- switching the feature off restores one detoast per reference
SET shared_detoast = off;
SELECT doc->'a', doc->'b' FROM sd;
RESET shared_detoast;

SELECT injection_points_detach('detoast-attr-external');
SELECT injection_points_detach('detoast-attr-compressed');
DROP TABLE sd;
