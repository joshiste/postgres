# JSONB internals

Covers the `jsonb` type's storage format, in-memory API, jsonpath, and the SQL/JSON
standard functions. Operators, opclasses and GIN encoding are in `jsonb-operators.md`.

## Files

- `src/include/utils/jsonb.h`: the single authoritative header. On-disk layout, `JEntry`
  encoding, `JsonbValue`, `JsonbPair`, `JsonbParseState`, `JsonbInState`, `JsonbIterator`,
  and the GIN flags and strategy numbers.
- `src/backend/utils/adt/jsonb.c`: I/O (`jsonb_in`, `jsonb_out`, `jsonb_recv`, `jsonb_send`),
  `JsonbToCString`, `to_jsonb` and datum conversion, builders and aggregates, casts.
- `src/backend/utils/adt/jsonb_util.c`: the engine. Search, comparison, containment,
  hashing, iteration, the push API, serialization.
- `src/backend/utils/adt/jsonfuncs.c`: accessors, `jsonb_set`/`jsonb_insert`/deletes via
  `setPath`, `populate_record` family, `strip_nulls`. Shared between `json` and `jsonb`.
- `src/backend/utils/adt/jsonbsubs.c`: subscripting (`jsonb_subscript_handler`).
- `src/backend/utils/adt/jsonpath.c`, `jsonpath_gram.y`, `jsonpath_scan.l`,
  `jsonpath_exec.c`, `src/include/utils/jsonpath.h`: the jsonpath type and interpreter.
  `jsonpath_exec.c` also hosts the JSON_TABLE runtime.
- `src/common/jsonapi.c`, `src/include/common/jsonapi.h`: the JSON parser shared by frontend
  and backend (recursive descent plus an incremental table-driven variant). `json.c` is the
  text `json` type built on it.
- `src/backend/parser/parse_expr.c` (`transformJson*`), `src/backend/parser/parse_jsontable.c`,
  `src/backend/executor/execExprInterp.c` (`ExecEvalJsonExprPath`, `ExecEvalJsonConstructor`),
  `src/include/nodes/primnodes.h` (`JsonExpr`, `JsonConstructorExpr`, `JsonTablePlan` nodes).

## On-disk format

A `Jsonb` is a varlena whose payload is a `JsonbContainer` tree. Each container is a
`uint32` header followed by an array of `JEntry` and then the children's variable-length
data. Header bits: `JB_CMASK` holds the count (elements, or pairs for objects), `JB_FSCALAR`,
`JB_FOBJECT`, `JB_FARRAY`. The root has no `JEntry` of its own, so the container header must
carry the object/array discriminator (`JB_ROOT_IS_OBJECT` and friends peek at it).

A `JEntry` is a `uint32`: 3 type bits (`JENTRY_ISSTRING`, `JENTRY_ISNUMERIC`,
`JENTRY_ISBOOL_FALSE`, `JENTRY_ISBOOL_TRUE`, `JENTRY_ISNULL`, `JENTRY_ISCONTAINER`), one
`JENTRY_HAS_OFF` bit, and 28 bits (`JENTRY_OFFLENMASK`) that hold either the child's length
or its end offset. Booleans and nulls carry no payload at all. Every `JB_OFFSET_STRIDE`-th
entry stores an offset and the rest store lengths, so random access costs at most one stride
of summation (`getJsonbOffset` walks backwards to the last stored offset) while the entry
array still compresses well under TOAST. The stride is a write-time heuristic only; readers
must key off `JENTRY_HAS_OFF`, so it can change without breaking on-disk data.

Objects store all keys first (sorted), then all values in matching order, so key search stays
cache-friendly. Keys are sorted by length first and then bytewise (`lengthCompareJsonbString`),
an internal collation unrelated to the database collation. Duplicate keys are removed at
build time by `uniqueifyJsonbObject`, last occurrence wins.

Numerics are stored as raw `Numeric` datums, 4-byte aligned; padding is placed at the start
of the node that needs it and folded into that node's length (`fillJsonbValue` undoes it with
`INTALIGN`). A top-level scalar is stored as a one-element array flagged
`JB_FSCALAR | JB_FARRAY`; `JsonbExtractScalar` unwraps it. Datetime values have no on-disk
form: `jbvDatetime` exists only in memory during jsonpath evaluation and serializes to a string.

Limits derive from the masks: `JSONB_MAX_ELEMS`, `JSONB_MAX_PAIRS`, string length and total
container size bounded by `JENTRY_OFFLENMASK` (checked on every iteration in the converters
to preclude overflow).

The binary wire format (`jsonb_send`) is a one-byte version followed by the text rendering;
it does not ship the internal layout.

## In-memory API

`JsonbValue` is a tagged union over `jbvNull`, `jbvString`, `jbvNumeric`, `jbvBool`,
`jbvArray`, `jbvObject`, `jbvBinary` (a pointer into an existing on-disk container, the
zero-copy mode) and `jbvDatetime`. The enum order is load-bearing: `compareJsonbContainers`
falls back to it when types differ.

Building: callers zero a `JsonbInState`, optionally set `outcontext` (build in another memory
context) and `escontext` (soft errors), then call `pushJsonbValue` with a token sequence
(`WJB_BEGIN_OBJECT`, `WJB_KEY`, `WJB_VALUE`, `WJB_ELEM`, `WJB_END_ARRAY`, ...). `result` stays
NULL until a complete, valid sequence finishes. Pushing a `jbvObject`/`jbvArray`/`jbvBinary`
expands it recursively. This API changed recently (commit "Revise APIs for pushJsonbValue()"):
it takes `JsonbInState *`, returns void, and `JsonbInState` moved into `jsonb.h`; external
code using the old `JsonbParseState **` signature no longer compiles.

Reading: `JsonbIteratorInit` and `JsonbIteratorNext(it, val, skipNested)`. With
`skipNested = false` the iterator descends into nested containers so callers never see
`jbvBinary`; with `true` they see `jbvBinary` and decide whether to recurse. Objects keep two
cursors because keys and values live in separate regions.

Conversions: `JsonbValueToJsonb` (serialize via `convertToJsonb`), `JsonbToJsonbValue`
(cheap, produces a `jbvBinary`), `JsonbToCString` / `JsonbToCStringIndent` for output.

Input goes `jsonb_in` to `jsonb_from_cstring`, which wires a stack-allocated `JsonSemAction`
(`jsonb_in_object_start`, `jsonb_in_scalar`, ...) into `pg_parse_json_or_errsave`; the
callbacks push into a `JsonbInState`. Soft-error support means `jsonb_in` works with
`pg_input_is_valid`.

## Core algorithms (`jsonb_util.c`)

- `getKeyJsonValueFromContainer`: binary search over the sorted key region. Array lookup in
  `findJsonbValueFromContainer` is linear because arrays are unordered.
- `compareJsonbContainers`: lockstep iteration. Order is object > array > bool > number >
  string > null, larger containers first, then element-wise. Two frozen quirks: an empty
  top-level array sorts below null (the raw-scalar check is overridden by the element count),
  and object keys compare in storage order (shorter first).
- `JsonbDeepContains`: containment (`@>`) as top-down unordered subtree matching. Objects get
  an early exit on pair count (valid only because keys are deduplicated); arrays are treated as
  sets, ignoring order and multiplicity, and nested array containment is O(N^2). A raw scalar
  is contained in an array, an array is never contained in a scalar.
- `JsonbHashScalarValue` and the extended variant: per-scalar hashing (numerics via
  `hash_numeric` so equal values hash equally) combined by rotate-and-xor. Used by hash
  indexes, hash joins/partitioning and the `jsonb_path_ops` GIN opclass.
- Serialization: `convertToJsonb`, `convertJsonbValue`, `convertJsonbArray`,
  `convertJsonbObject`, `convertJsonbScalar` over a `StringInfo` with `reserveFromBuffer`
  and `copyToBuffer` for back-patching headers.

## jsonpath

A `JsonPath` datum is a header (`JSONPATH_VERSION`, `JSONPATH_LAX` bit) followed by a flat
chain of 4-byte-aligned items linked by `nextPos` offsets; operands are referenced by offset.
The main node is the left operand, not the operator, which makes descending a path cheap.
`JsonPathItemType` (`jpiKey`, `jpiAnyArray`, `jpiFilter`, `jpiExists`, item methods, ...) is
part of the on-disk representation: never reorder it, only append. The scalar types alias the
`jbvType` values. Parsing: `parsejsonpath` from the bison/flex grammar, flattened by
`flattenJsonPathParseItem`; printing via `jsonPathToCstring`.

Execution (`jsonpath_exec.c`): `executeJsonPath` sets up a `JsonPathExecContext` (root,
current item, variables via callbacks, `laxMode`, `throwErrors`, `useTz`) and recurses through
`executeItem` / `executeNextItem`, with `executeBoolItem` and `executePredicate` for filters.
Results are `JsonPathExecResult` (`jperOk`, `jperNotFound`, `jperError`) and tri-state
`JsonPathBool`. Output collects into a `JsonValueList`, a chunked array with a small
stack-resident base chunk (not a `List`; callers must `JsonValueListInit`). Lax mode is
expressed by `jspAutoUnwrap`, `jspAutoWrap`, `jspIgnoreStructuralErrors`; in strict mode an
exists-style query cannot short-circuit because it must prove no error occurs anywhere.

SQL functions `jsonb_path_exists`, `jsonb_path_match`, `jsonb_path_query`,
`jsonb_path_query_array`, `jsonb_path_query_first` each have a `_tz` twin. Casts involving the
session time zone raise an error unless `useTz` is set, so the base functions stay immutable
(usable in index expressions) and only the `_tz` forms are stable. `jspIsMutable` gives the
planner the same answer for `contain_mutable_functions`. Recently added item methods include
the string methods (`jpiStrLower`, `jpiStrReplace`, `jpiStrSplitPart`, ...), considered
immutable because the database locale is fixed at initdb.

## SQL/JSON

All standard functions exist: constructors `JSON_OBJECT`, `JSON_ARRAY`, `JSON_OBJECTAGG`,
`JSON_ARRAYAGG`, `JSON()`, `JSON_SCALAR`, `JSON_SERIALIZE`; predicate `IS JSON`; query
functions `JSON_EXISTS`, `JSON_QUERY`, `JSON_VALUE`; and `JSON_TABLE` including NESTED paths
and the `PLAN` / `PLAN DEFAULT` clauses (added this cycle, with a reworked plan/join executor
in `JsonTablePlanState`).

- Nodes (`primnodes.h`): `JsonConstructorExpr` with `JsonConstructorType`,
  `JsonIsPredicate`, `JsonExpr` with `JsonExprOp`, `JsonBehavior`, `JsonReturning`,
  `JsonValueExpr`, and the JSON_TABLE plan tree (`JsonTablePathScan`, `JsonTableSiblingJoin`).
  `JsonBehaviorType` order is mirrored in `get_json_behavior` in `ruleutils.c`.
- Parse analysis: `transformJsonFuncExpr`, `transformJsonObjectConstructor`,
  `transformJsonIsPredicate`, etc. in `parse_expr.c`; `transformJsonTable` in
  `parse_jsontable.c`, reached from `transformRangeTableFunc`.
- Execution: opcodes `EEOP_JSONEXPR_PATH`, `EEOP_JSONEXPR_COERCION`,
  `EEOP_JSONEXPR_COERCION_FINISH`, `EEOP_JSON_CONSTRUCTOR`. `ExecEvalJsonExprPath` dispatches to
  `JsonPathExists` / `JsonPathQuery` / `JsonPathValue` in `jsonpath_exec.c` and selects the
  ON EMPTY / ON ERROR branch; `JsonPathQuery` implements the WRAPPER rules. JSON_TABLE runs
  through the `JsonbTableRoutine` table-function routine.
- Underlying builders: `jsonb_build_object_worker`, `jsonb_build_array_worker`, with
  `unique` and `absent_on_null` flowing into `uniqueifyJsonbObject`.

## json versus jsonb

`json` stores the input text verbatim (whitespace, key order, duplicates preserved) and
reparses on each use; `jsonb` decomposes to the binary form above, is slower to input,
faster to process, and the only one that is indexable. `jsonb` also enforces that `\u`
escapes are representable in the database encoding and that numbers fit `numeric`.
Documentation: `doc/src/sgml/json.sgml` and `doc/src/sgml/func/func-json.sgml`.

## Tests

One parallel group: `json`, `jsonb`, `json_encoding`, `jsonpath`, `jsonpath_encoding`,
`jsonb_jsonpath`, `sqljson`, `sqljson_queryfuncs`, `sqljson_jsontable` in
`src/test/regress/sql`. The two encoding tests have `_1`/`_2` alternate expected files.
`src/test/modules/test_json_parser` exercises the shared parser directly, including the
incremental mode.

## Change rules

- Never alter the `JEntry` layout, key sort order, raw-scalar wrapping, or the order of
  `JsonPathItemType`; all are on-disk formats. Appending a jsonpath item type is fine.
- New jsonpath methods need grammar, flattening, printing (`printJsonPathItem`) and
  execution, plus a decision on `jspIsMutable` if they depend on session state.
- New SQL/JSON behavior touches parser, node support (regenerated by `gen_node_support.pl`),
  `ruleutils.c` deparsing, and the executor.
