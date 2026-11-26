-- Equality under a nondeterministic collation compares the whole values
-- rather than their sizes first, so it is not treated as reading only the
-- size: it makes the copy for the readers after it.

SELECT getdatabaseencoding() <> 'UTF8' OR
       (SELECT count(*) FROM pg_collation WHERE collprovider = 'i' AND collname <> 'unicode') = 0
       AS skip_test \gset
\if :skip_test
\quit
\endif

CREATE COLLATION ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
CREATE TABLE sdi (id int, txt text COLLATE ci);
ALTER TABLE sdi ALTER COLUMN txt SET STORAGE EXTERNAL;
INSERT INTO sdi VALUES (1, 'abc' || repeat(md5('x'), 200));

SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS injection_points;
RESET client_min_messages;
SET debug_parallel_query = off;
SELECT injection_points_attach('detoast-attr-external', 'notice');

-- one detoast; a fixed value of another size does not let equality skip it
SELECT txt = 'ABC' AS eq, length(txt), position('a6' in txt) > 0 FROM sdi;

SELECT injection_points_detach('detoast-attr-external');
DROP TABLE sdi;
DROP COLLATION ci;
