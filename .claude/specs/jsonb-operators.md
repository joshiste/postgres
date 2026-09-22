# JSONB operators, functions, and index support

Companion to `jsonb.md` (type internals) and `gin.md` (the index AM). This note covers how
SQL-level jsonb operators map to C, what the planner knows about them, and how the two GIN
opclasses encode jsonb.

## Operator to function map

All jsonb operators are declared in one block in `src/include/catalog/pg_operator.dat`.

| Operator | Operands | C function | Selectivity |
|---|---|---|---|
| `->`, `->>` | jsonb, text | `jsonb_object_field`, `jsonb_object_field_text` | none |
| `->`, `->>` | jsonb, int4 | `jsonb_array_element`, `jsonb_array_element_text` | none |
| `#>`, `#>>` | jsonb, text[] | `jsonb_extract_path`, `jsonb_extract_path_text` | none |
| `@>`, `<@` | jsonb, jsonb | `jsonb_contains`, `jsonb_contained` | `matchingsel` |
| `?`, `?|`, `?&` | jsonb, text / text[] | `jsonb_exists`, `jsonb_exists_any`, `jsonb_exists_all` | `matchingsel` |
| `@?`, `@@` | jsonb, jsonpath | `jsonb_path_exists_opr`, `jsonb_path_match_opr` | `matchingsel` |
| `\|\|` | jsonb, jsonb | `jsonb_concat` | none |
| `-` | jsonb, text / text[] / int4 | `jsonb_delete`, `jsonb_delete_array`, `jsonb_delete_idx` | none |
| `#-` | jsonb, text[] | `jsonb_delete_path` | none |
| `=` `<>` `<` `>` `<=` `>=` | jsonb, jsonb | `jsonb_eq` ... via `jsonb_cmp` | scalar selfuncs |

The three `-` variants share the SQL name `jsonb_delete` but are distinct C symbols.
`=` is marked mergeable and hashable, so jsonb participates in merge joins, hash joins, hash
aggregation and hash partitioning (via `jsonb_hash` and `jsonb_hash_extended`).

## Where the C code lives

- `src/backend/utils/adt/jsonb_op.c`: existence, containment, the six comparison operators,
  `jsonb_cmp`, `jsonb_hash`. Existence uses `findJsonbValueFromContainer` with both the
  object and array flags, which is why string array elements satisfy `?` as if they were keys.
  Containment is a thin wrapper over `JsonbDeepContains` after checking both roots have the
  same object/array kind.
- `src/backend/utils/adt/jsonfuncs.c`: path extraction (`get_jsonb_path_all`,
  `jsonb_get_element`), all mutation (`jsonb_set`, `jsonb_set_lax`, `jsonb_insert`, the
  deletes, `jsonb_concat`), and the record/set-returning functions (`jsonb_each`,
  `jsonb_array_elements`, `jsonb_populate_record`, `jsonb_to_record`, ...). Mutation is built on
  one recursive engine, `setPath` dispatching to `setPathObject` and `setPathArray`, driven by
  an `op_type` bitmask (`JB_PATH_CREATE`, `JB_PATH_DELETE`, `JB_PATH_REPLACE`,
  `JB_PATH_INSERT_BEFORE`/`_AFTER`, `JB_PATH_FILL_GAPS`, `JB_PATH_CONSISTENT_POSITION`).
- `src/backend/utils/adt/jsonb.c`: I/O, `jsonb_typeof`, `to_jsonb` and the datum conversion
  (`json_categorize_type`, `datum_to_jsonb`, `to_jsonb_is_immutable`), builders
  (`jsonb_build_object`, `jsonb_build_array`, `jsonb_object`) and the aggregates
  (`jsonb_agg`, `jsonb_object_agg` and their `_strict`/`_unique` variants).
- `src/backend/utils/adt/jsonb_util.c`: `compareJsonbContainers` (total order),
  `JsonbDeepContains` (containment semantics), `JsonbHashScalarValue`.
- `src/backend/utils/adt/jsonpath_exec.c`: `jsonb_path_exists`, `jsonb_path_match`,
  `jsonb_path_query`, `jsonb_path_query_array`, `jsonb_path_query_first`, each with a
  `_tz` twin and, for the first two, an `_opr` variant used by `@?`/`@@`. The operator forms
  hardcode `silent = true` so a jsonpath error can never surface from an index recheck. The
  `_tz` variants exist only so timezone-dependent datetime comparisons can be marked stable
  while the base functions stay immutable.
- `src/backend/utils/adt/jsonbsubs.c`: subscripting. `jsonb_subscript_handler` returns a
  `SubscriptRoutines` whose fetch is strict and leakproof (missing key yields NULL) and whose
  store is not leakproof (bad assignment errors). Reads go through `jsonb_get_element`;
  `UPDATE ... SET col['a']['b'] = ...` goes through `setPath` with create, fill-gaps and
  consistent-position flags so intermediate objects are created and arrays padded.

## Planner integration is minimal

- jsonb has no `typanalyze` and no `jsonb_selfuncs.c`. ANALYZE collects only whole-document
  MCV/histogram via `jsonb_cmp`. Every `@>`, `?`, `?|`, `?&`, `@?`, `@@` predicate is
  estimated with `matchingsel`, a flat `DEFAULT_MATCHING_SEL` constant, and joins on those
  operators with `matchingjoinsel`, another constant.
- No jsonb function overrides `procost`; `||`, `@>` and the jsonpath operators cost one
  `cpu_operator_cost` despite walking whole documents. `jsonb_path_query` has a fixed
  `prorows` estimate.
- Most constructors and the `_tz` jsonpath functions are stable rather than immutable, because
  they depend on output functions and session settings. `to_jsonb_is_immutable` lets DDL
  decide whether a particular `to_jsonb` call may appear in an index expression.

## Operator classes

Declared across `pg_opclass.dat`, `pg_opfamily.dat`, `pg_amop.dat`, `pg_amproc.dat`:

- btree `jsonb_ops`: strategies 1-5 over `jsonb_cmp`. Useful only for whole-document
  equality and ordering. The order is object > array > bool > number > string > null, with
  larger containers first, keys compared in storage order (shorter keys first), and an
  historical quirk that an empty top-level array sorts below null.
- hash `jsonb_ops`: `jsonb_hash`, `jsonb_hash_extended`.
- GIN `jsonb_ops` (default, key type text): `@>`, `?`, `?|`, `?&`, `@?`, `@@`.
- GIN `jsonb_path_ops` (key type int4): `@>`, `@?`, `@@` only.

`<@` is in neither GIN family. Neither GIN opclass supplies a `comparePartial` support
function, so there is no prefix or range matching on jsonb GIN keys. There is no GiST,
SP-GiST or BRIN opclass for jsonb in core.

Strategy numbers are defined in `src/include/utils/jsonb.h`: `JsonbContainsStrategyNumber`,
`JsonbExistsStrategyNumber`, `JsonbExistsAnyStrategyNumber`, `JsonbExistsAllStrategyNumber`,
`JsonbJsonpathExistsStrategyNumber`, `JsonbJsonpathPredicateStrategyNumber`.

## GIN key encoding (`src/backend/utils/adt/jsonb_gin.c`)

### jsonb_ops

`gin_extract_jsonb` walks the document with the iterator and emits one text key per object
key, per scalar value and per array element. `make_scalar_key` builds each key as a one-byte
flag followed by a text body:

- `JGINFLAG_KEY` for object keys and for string array elements (deliberately conflated so `?`
  works on arrays),
- `JGINFLAG_STR` for string values, `JGINFLAG_NUM` for numerics (normalized via
  `numeric_normalize` so `25` and `25.0` produce the same key), `JGINFLAG_BOOL`, `JGINFLAG_NULL`.

Bodies longer than `JGIN_MAXLENGTH` are replaced by an 8-hex-digit `hash_any` digest and
`JGINFLAG_HASHED` is set. Keys compare with `gin_compare_jsonb`, which always uses the C
collation. `gin_extract_jsonb_query` maps strategies to entry sets: containment reuses
`gin_extract_jsonb` on the query document; `?` builds one key-flavored entry; `?|`/`?&`
deconstruct the text array; jsonpath goes through `extract_jsp_query`.

### jsonb_path_ops

`gin_extract_jsonb_path` keeps a `PathHashStack` and emits one uint32 hash per scalar value,
where the hash incorporates every object key on the path down to that value (array subscripts
do not perturb the hash). Because keys never appear as standalone entries, `?` operators are
unrepresentable, and a structure with no scalar leaves such as `{"a": {}}` yields no entries.
The comparator is plain `btint4cmp`.

### jsonpath decomposition

Both opclasses reduce `@?` and `@@` to the same machinery using the identities
`jb @? 'path'` is `jb @@ 'EXISTS(path)'` and `jb @@ 'expr'` is `jb @? '$ ? (expr)'`.
`extract_jsp_query` builds a tree of `JsonPathGinNode` (`JSP_GIN_AND`, `JSP_GIN_OR`,
`JSP_GIN_ENTRY`) by extracting clauses of the form `accessor_chain == constant`. The
opclass-specific part is a pair of callbacks in `JsonPathGinContext`: `add_path_item`
(jsonb_ops records `.key` items and tolerates `.*`, `.**`, `[*]`, `[n]`; jsonb_path_ops folds
`.key` into the running hash and rejects wildcards) and `extract_nodes`. Rules worth knowing:

- `EXISTS(path)` alone is not extracted (no statistics would make the entries useful); only
  equality-to-constant clauses inside it are.
- `!=`, `NOT EXISTS` and any OR with an unextractable arm produce no entries and force
  `GIN_SEARCH_MODE_ALL` (full index scan). An AND drops the unextractable arm.
- In lax mode a string constant may be either a key or a value (arrays auto-unwrap), so
  jsonb_ops emits an OR of both flavors, roughly doubling entries versus strict mode.

The tree is stored in `extra_data` and re-evaluated by `execute_jsp_gin_node` inside the
consistent functions, with proper three-valued logic for the tri-consistent variant.

## Every jsonb GIN match is rechecked

`gin_consistent_jsonb`, `gin_consistent_jsonb_path` and their tri-consistent twins set
`recheck = true` for every strategy; the tri-consistent functions never return `GIN_TRUE`.
Causes, each independently sufficient:

- hashed long keys can collide;
- jsonb_ops entries carry no nesting or position information, and `?` is defined as top-level
  existence only;
- object keys and string array elements share a flag;
- jsonb_path_ops discards structure by design;
- array containment has no cardinality shortcut (arrays may hold duplicates, only objects are
  deduplicated in `JsonbDeepContains`), and a raw scalar is contained in a top-level array.

So a jsonb GIN scan is always a Bitmap Index Scan feeding a Bitmap Heap Scan with a Recheck
Cond; index-only scans are impossible. `@> '{}'` and `?& '{}'` degrade to full index scans.

## Tests and docs

- `src/test/regress/sql/jsonb.sql` runs the same predicate set as a seqscan baseline, then
  under a `jsonb_ops` index, an expression index on `j->'array'` (pins the key/element
  conflation and the `?` versus `@>` asymmetry), a btree, and a `jsonb_path_ops` index built
  CONCURRENTLY. The `nestjsonb` block guards nested and top-level-array containment
  correctness under the lossy path index. Related: `jsonb_jsonpath.sql`, `jsonpath.sql`,
  `sqljson*.sql`.
- Docs: `doc/src/sgml/json.sgml` section `json-indexing` (opclass trade-offs, the rule that the
  operator must apply directly to the indexed column or expression), `doc/src/sgml/func/func-json.sgml`
  tables `functions-jsonb-op-table` and `functions-json-processing-table`, and the built-in
  opclass table in `doc/src/sgml/gin.sgml`.

## Extending

- A new jsonb operator needs a `pg_operator.dat` entry with a `pg_proc.dat` function, and if
  it should be indexable, an `pg_amop.dat` row in the right GIN family plus a new strategy
  number in `jsonb.h` and cases in the extract-query and consistent functions.
- Better cardinality estimation would need a `jsonb` `typanalyze` populating `pg_statistic`
  slots and a `jsonb_selfuncs.c`; nothing of the kind exists today.
