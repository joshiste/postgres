# Indexes: the access method framework

How index access methods (AMs) plug into the server, how the planner decides an index is
usable, and how scans, builds, and VACUUM reach the AM. AM-specific internals are in the
per-AM READMEs under `src/backend/access/*/README` (nbtree, hash, gist, spgist, brin, gin)
and in `gin.md`. User docs: `doc/src/sgml/indexam.sgml` (the API contract),
`indices.sgml`, `xindex.sgml` (writing opclasses), and one chapter per AM.

## Registering an AM

An index AM is a row in `pg_am` (`amtype = 'i'`) whose `amhandler` returns an
`IndexAmRoutine` (`src/include/access/amapi.h`). Handlers are `bthandler`, `hashhandler`,
`gisthandler`, `ginhandler`, `spghandler`, `brinhandler`. Since the recent change "Change
IndexAmRoutines to be statically-allocated structs", each handler returns a pointer to a
`static const` routine with designated initializers; `GetIndexAmRoutine` and
`GetIndexAmRoutineByAmId` (`src/backend/access/index/amapi.c`) return `const` pointers that
core never copies or frees. Extensions use `CREATE ACCESS METHOD ... TYPE INDEX HANDLER`;
`src/test/modules/dummy_index_am` is the minimal template and `contrib/bloom` a real one.

`IndexAmRoutine` has three parts:

- Capability flags the planner and executor consult: `amcanorder`, `amcanorderbyop`,
  `amcanhash`, `amconsistentequality`, `amconsistentordering`, `amcanbackward`,
  `amcanunique`, `amcanmulticol`, `amoptionalkey`, `amsearcharray`, `amsearchnulls`,
  `amstorage`, `amclusterable`, `ampredlocks`, `amcanparallel`, `amcanbuildparallel`,
  `amcaninclude`, `amusemaintenanceworkmem`, `amsummarizing`, plus
  `amparallelvacuumoptions`, `amkeytype`, `amstrategies`, `amsupport`, `amoptsprocnum`.
- Mandatory callbacks (asserted in `GetIndexAmRoutine`): `ambuild`, `ambuildempty`,
  `aminsert`, `ambulkdelete`, `amvacuumcleanup`, `amcostestimate`, `amoptions`,
  `amvalidate`, `ambeginscan`, `amrescan`, `amendscan`.
- Optional callbacks: `aminsertcleanup`, `amcanreturn`, `amgettreeheight`, `amproperty`,
  `ambuildphasename`, `amadjustmembers`, `amgettuple`, `amgetbitmap` (at least one of the
  two scan styles), `ammarkpos`/`amrestrpos`, the parallel-scan trio
  `amestimateparallelscan`/`aminitparallelscan`/`amparallelrescan`, and the planning pair
  `amtranslatestrategy`/`amtranslatecmptype`.

The translate pair maps between AM-specific `StrategyNumber` (`stratnum.h`) and the
AM-neutral `CompareType` (`cmptype.h`: `COMPARE_LT` .. `COMPARE_GT`, `COMPARE_NE`,
`COMPARE_OVERLAP`, `COMPARE_CONTAINED_BY`). `CompareType` replaced the old `RowCompareType`;
the wrappers are `IndexAmTranslateStrategy` and `IndexAmTranslateCompareType`. btree and hash
implement both directions, GiST only cmptype-to-strategy via a per-opclass support function,
SP-GiST and BRIN neither.

## Operator classes and families

Indexability of an operator is a catalog fact, not code. `pg_opfamily` groups compatible
opclasses; `pg_opclass` binds an input type (`opcintype`) and optional storage type
(`opckeytype`, requires `amstorage`) to a family for one AM; `pg_amop` lists the operators
per family with a `StrategyNumber` and a purpose (search or order-by, the latter with an
`amopsortfamily`); `pg_amproc` lists support functions by number. Support function numbering
is per AM: `BTORDER_PROC`, `BTSORTSUPPORT_PROC`, `BTINRANGE_PROC`, `BTEQUALIMAGE_PROC`,
`BTOPTIONS_PROC`, `BTSKIPSUPPORT_PROC` for btree; `HASHSTANDARD_PROC`, `HASHEXTENDED_PROC`;
`GIST_CONSISTENT_PROC` through `GIST_TRANSLATE_CMPTYPE_PROC`; `GIN_COMPARE_PROC` etc.

Each AM validates its families in `amvalidate` (shared helpers in `amvalidate.c`) and can veto
or annotate additions in `amadjustmembers`, called from `opclasscmds.c`. Per-column operator
class options (for example GiST `siglen`, BRIN bloom parameters) are declared by the
`amoptsprocnum` support function through the `local_relopts` API, stored in the index's
`pg_attribute.attoptions`, and parsed by `index_opclass_options`.

## Planner path

`plancat.c` builds an `IndexOptInfo` per index, copying the AM flags, opfamilies,
collations, `canreturn`, `tree_height` (from `amgettreeheight`) and the `amcostestimate`
pointer. In `src/backend/optimizer/path/indxpath.c`, `create_index_paths` matches restriction
and join clauses to index columns via `match_clause_to_indexcol`, which handles plain
operators (`match_opclause_to_indexcol`, keyed on `get_op_opfamily_strategy` and
`op_in_opfamily`), boolean columns, function clauses with planner support functions,
ScalarArrayOp (`amsearcharray`), row comparisons, and OR clauses. Results are `IndexClause`
nodes marked `lossy` when a recheck is needed. Ordering uses `match_pathkeys_to_index` and
`amcanorderbyop` for KNN-style order-by operators. `check_index_only` decides index-only
feasibility from `canreturn`. Cost estimation is per AM in `selfuncs.c`: `btcostestimate`,
`hashcostestimate`, `gistcostestimate`, `spgcostestimate`, `gincostestimate`,
`brincostestimate`, mostly built on `genericcostestimate`.

## Scan path

`src/backend/access/index/indexam.c` is the thin generic layer: `index_beginscan`,
`index_rescan`, `index_getnext_tid`, `index_fetch_heap`, `index_getnext_slot`,
`index_getbitmap`, `index_endscan`, plus the parallel variants. Scan keys are `ScanKeyData`
(`skey.h`) with flags `SK_SEARCHARRAY`, `SK_SEARCHNULL`, `SK_SEARCHNOTNULL`, `SK_ORDER_BY`,
and the btree-only row-comparison flags `SK_ROW_HEADER`/`SK_ROW_MEMBER`/`SK_ROW_END`;
`ExecIndexBuildScanKeys` in `nodeIndexscan.c` builds them. `IndexScanDescData` (`relscan.h`)
carries the snapshot, keys, `xs_want_itup` (index-only), `xs_recheck`, the heap fetch state,
and the AM-private `opaque`.

Two scan styles: `amgettuple` returns one TID at a time and supports ordering, mark/restore
and `kill_prior_tuple` (the executor reports that a fetched heap tuple was dead so the AM can
set `LP_DEAD` hints; GIN does not use it). `amgetbitmap` fills a `TIDBitmap`
(`nodes/tidbitmap.c`) and is consumed by `nodeBitmapIndexscan.c` feeding
`nodeBitmapHeapscan.c`; pages become lossy when `work_mem` is exceeded and force a recheck.
GIN and BRIN offer only bitmap scans. `nodeIndexonlyscan.c` consults the visibility map
(`VM_ALL_VISIBLE`) before deciding whether to touch the heap. Parallel index scans exist only
for btree (`btestimateparallelscan`, `btinitparallelscan`, `btparallelrescan`); there is no
batched or read-stream index scan API yet.

## Build and maintenance

`DefineIndex` (`commands/indexcmds.c`) resolves opclasses (`ResolveOpClass`,
`GetDefaultOpClass`), builds an `IndexInfo` (`BuildIndexInfo`, `execnodes.h`) and calls
`index_create` then `index_build` (`catalog/index.c`). `index_build` picks parallel workers
via `plan_create_index_workers` when `amcanbuildparallel` (btree, GIN, BRIN), runs `ambuild`,
and for unlogged indexes creates the init fork and calls `ambuildempty`. AMs scan the heap with
`table_index_build_scan` / `table_index_build_range_scan`, whose heap implementation also
detects broken HOT chains. Sort-based builds use `tuplesort_begin_index_*` and divide
`maintenance_work_mem` among participants; `nbtsort.c` is the model for parallel builds.

CREATE INDEX CONCURRENTLY runs three transactions: create the catalog entry with
`INDEX_CREATE_CONCURRENT`, wait for lockers, build under a fresh snapshot
(`index_concurrently_build`), wait again, then `validate_index` inserts anything missed and
`WaitForOlderSnapshots` precedes marking it valid. REINDEX CONCURRENTLY
(`ReindexRelationConcurrently`) does the same against a copy made with `index_create_copy`,
then `index_concurrently_swap` and `index_concurrently_set_dead`.

Inserts go through `ExecInsertIndexTuples` (`execIndexing.c`), which passes an
`indexUnchanged` hint (`index_unchanged_by_update`) that nbtree uses for bottom-up deletion.
Unique and exclusion constraints are checked via `index_insert` with `UNIQUE_CHECK_*` modes and
`ExecCheckIndexConstraints`; INSERT ON CONFLICT uses speculative insertion. In `heap_update`,
`HeapDetermineColumnsInfo` compares the modified columns against the index attribute bitmaps
from `RelationGetIndexAttrBitmap`: overlap with HOT-blocking columns disables HOT, but
summarizing indexes (BRIN, `amsummarizing`) are excluded and simply get new entries.

## VACUUM

`lazy_vacuum_all_indexes` in `vacuumlazy.c` calls `vac_bulkdel_one_index`, which invokes
`ambulkdelete` with the `IndexBulkDeleteCallback` `vac_tid_reaped`, a `TidStoreIsMember`
probe against the dead-TID `TidStore` (`access/common/tidstore.c`). `vac_cleanup_one_index`
invokes `amvacuumcleanup` afterwards. `vacuumparallel.c` distributes indexes to workers based
on `amparallelvacuumoptions` (`VACUUM_OPTION_PARALLEL_BULKDEL`, `_COND_CLEANUP`, `_CLEANUP`).
Results come back as `IndexBulkDeleteResult` and feed `index_update_stats`.

## WAL

Each core AM has its own resource manager in `rmgrlist.h` (`RM_BTREE_ID`, `RM_HASH_ID`,
`RM_GIN_ID`, `RM_GIST_ID`, `RM_SPGIST_ID`, `RM_BRIN_ID`) with redo, desc and mask routines.
Extension AMs use generic WAL (`GenericXLogStart`, `GenericXLogRegisterBuffer`,
`GenericXLogFinish` in `generic_xlog.c`), as `contrib/bloom` does, or register a custom
rmgr (`src/test/modules/test_custom_rmgrs`).

## Capability matrix

| | btree | hash | GiST | SP-GiST | GIN | BRIN |
|---|---|---|---|---|---|---|
| ordered scans / ORDER BY op | yes / no | no | no / yes | no / yes | no | no |
| unique | yes | no | no | no | no | no |
| multicolumn | yes | no | yes | no | yes | yes |
| INCLUDE columns | yes | no | yes | yes | no | no |
| index-only scans | yes | no | opclass fetch | yes | no | no |
| search arrays / nulls | yes / yes | no | no / yes | no / yes | no | no / yes |
| amgettuple | yes | yes | yes | yes | no | no |
| parallel scan / build | yes / yes | no | no | no | no / yes | no / yes |
| predicate locks (SSI) | yes | yes | yes | no | yes | no |
| special | skip scan, dedup, bottom-up deletion | `amkeytype` int4 | KNN, buffered/sorted build | | pending list, `amusemaintenanceworkmem` | `amsummarizing`, revmap |

nbtree specifics worth knowing: ScalarArrayOp and skip-scan arrays are handled in
`nbtpreprocesskeys.c` and `nbtreadpage.c` (`_bt_preprocess_keys`, `_bt_advance_array_keys`),
with per-type skip support in `nbtcompare.c` via `BTSKIPSUPPORT_PROC`; deduplication and
suffix truncation are described in the nbtree README.

## Verification and tests

`contrib/amcheck` provides `bt_index_check`, `bt_index_parent_check`, `gin_index_check`
(`verify_gin.c`) and `verify_heapam`; `src/bin/pg_amcheck` drives them. Regression coverage:
`create_index.sql`, `create_index_spgist.sql`, `btree_index.sql`, `index_including*.sql`,
`hash_index.sql`, `gist.sql`, `spgist.sql`, `brin*.sql`, `gin.sql`, `amutils.sql` (index
property functions), `indexing.sql` (partitioned indexes), `opr_sanity.sql` (opclass catalog
consistency). Modules: `dummy_index_am`, `index` (kill_prior_tuple isolation spec), `nbtree`,
`brin`, `gin`, `spgist_name_ops`, `test_tidstore`.

## Change rules

- Adding an `IndexAmRoutine` field means updating every core handler, `contrib/bloom`,
  `dummy_index_am`, `indexam.sgml`, and usually `IndexOptInfo` plus `plancat.c`.
- New opclass members go in `pg_amop.dat` / `pg_amproc.dat` with `opr_sanity.sql`
  expectations updated; the AM's `amvalidate` must accept them.
- New strategy semantics for btree-like comparison should be expressed through
  `CompareType` translation so `selfuncs.c` and exclusion constraints keep working.
