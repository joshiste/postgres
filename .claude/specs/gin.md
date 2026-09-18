# GIN (Generalized Inverted Index)

An inverted index: each indexed *item* (an array, a tsvector, a jsonb document) is
decomposed by the operator class into *keys* (entries), and the index maps each distinct key
to the set of heap TIDs containing it. `src/backend/access/gin/README` is the design document
and is accurate; this note orients you in the code and lists the rules that bite. User docs
are in `doc/src/sgml/gin.sgml`. The framework GIN plugs into is described in `indexes.md`.

## Files

- `ginutil.c`: `ginhandler` and the `IndexAmRoutine` flags, `initGinState`
  (`GinState`: per-column support functions, collations, and for multicolumn indexes a
  synthetic `(int2 attnum, key)` tuple descriptor), `ginExtractEntries`, metapage init,
  `ginGetStats`/`ginUpdateStats`, `ginoptions`.
- `gininsert.c`: `ginbuild` (serial via `BuildAccumulator`, or parallel via
  `_gin_begin_parallel`, worker `_gin_parallel_build_main`, leader `_gin_parallel_merge`),
  `ginbuildempty`, `gininsert`, `ginEntryInsert`.
- `ginbtree.c`: the generic B-tree engine (`GinBtreeData` vtable, `ginFindLeafPage`,
  `ginPlaceToPage`, `ginFinishSplit`, `ginStepRight`) shared by entry tree and posting trees.
- `ginentrypage.c`: entry-tree page methods, `GinFormTuple`, `ginReadTuple`.
- `gindatapage.c`: posting-tree page methods, leaf segment disassemble/repack, `createPostingTree`,
  `ginInsertItemPointers`, `ginVacuumPostingTreeLeaf`.
- `ginpostinglist.c`: varbyte delta compression of TID lists (`ginCompressPostingList`,
  `ginPostingListDecode*`, `ginMergeItemPointers`).
- `ginscan.c`: scan setup (`ginNewScanKey`, `ginFillScanKey`, `ginFillScanEntry`).
- `ginget.c`: scan execution (`gingetbitmap`, `startScan`, `startScanKey`, `entryGetItem`,
  `keyGetItem`, `scanGetItem`, `collectMatchBitmap`, `scanPendingInsert`).
- `ginfast.c`: pending list (`ginHeapTupleFastInsert`, `ginInsertCleanup`,
  `gin_clean_pending_list`).
- `ginvacuum.c`: `ginbulkdelete`, `ginvacuumcleanup`, posting-tree page deletion.
- `ginlogic.c`: consistent/triConsistent shims. `ginbulk.c`: the build-time red-black tree
  accumulator. `ginarrayproc.c`: the built-in `anyarray` opclass. `ginvalidate.c`. `ginxlog.c`.
- Headers: `src/include/access/gin.h` (public contract: proc numbers, search modes,
  `GinTernaryValue`, `GinStatsData`), `gin_private.h` (`GinState`, `GinBtreeData`,
  `GinScanKeyData`, `GinScanEntryData`, `GinOptions`, inline comparators),
  `ginblock.h` (page and tuple layout, categories, special TIDs), `ginxlog.h`, `gin_tuple.h`
  (the `GinTuple` used by parallel-build sorts).

## Structure on disk

Block 0 is the metapage (`GinMetaPageData`: pending-list head/tail, page and entry counts,
`ginVersion`, currently `GIN_CURRENT_VERSION` 2). Block 1 is the root of the **entry tree**,
a B-tree keyed on `(attnum, null category, key)`. A multicolumn GIN is therefore one tree
partitioned by column, not several trees. Each entry-tree leaf tuple is an ordinary
`IndexTuple` whose `t_tid` is repurposed: it either carries an inline compressed posting list
(offset to the list plus item count; `GinGetPosting`, `GinGetNPosting`) or, when the list
would not fit `GinMaxItemSize`, points to the root of a **posting tree** (`GinIsPostingTree`,
`GIN_TREE_POSTING`). A posting tree is a B-tree keyed on the TID itself; its leaves hold
several independent compressed segments (`GinPostingList`, sized between
`GinPostingListSegmentMinSize` and `GinPostingListSegmentMaxSize`) so updates re-encode one
segment and scans can skip whole segments. Either way TIDs for a key come out in ascending
order, which every scan algorithm relies on.

Nulls and empties are handled with categories (`GinNullCategory` in `ginblock.h`):
`GIN_CAT_NORM_KEY`, `GIN_CAT_NULL_KEY` (a null key inside an item), `GIN_CAT_EMPTY_ITEM`
(placeholder for an item with zero keys), `GIN_CAT_NULL_ITEM` (placeholder for a null item),
and the query-only `GIN_CAT_EMPTY_QUERY`. Placeholders are what make full-index scans and
"contains empty" queries possible. Indexes with `ginVersion` below 1 predate them and reject
such queries with a REINDEX hint.

Page flags (`GinPageOpaqueData`): `GIN_DATA`, `GIN_LEAF`, `GIN_DELETED`, `GIN_META`,
`GIN_LIST`, `GIN_LIST_FULLROW`, `GIN_INCOMPLETE_SPLIT`, `GIN_COMPRESSED`. The special TID with
offset 0xffff marks a lossy whole-page pointer (`ItemPointerSetLossyPage`,
`ItemPointerIsLossyPage`).

Nothing is ever deleted from the entry tree; VACUUM only removes TIDs from posting lists and
deletes emptied posting-tree pages. This is a deliberate simplification (distinct keys in a
corpus change slowly).

## Insertion and the pending list

`gininsert` extracts entries per column with `ginExtractEntries` (never calls the opclass on
a null item, sorts and dedups, appends a `GIN_CAT_NULL_KEY` entry if needed) and inserts each
with `ginEntryInsert`. With `fastupdate` on (the default), entries are instead appended to
the **pending list**: `GIN_LIST` pages linked from the metapage, each holding unsorted index
tuples with one heap TID apiece. Searches must scan the pending list linearly, so it is
merged into the tree by `ginInsertCleanup`, which is triggered by VACUUM (first thing
`ginbulkdelete` does), by autovacuum's ANALYZE pass (`ginvacuumcleanup` with `analyze_only`),
by the SQL function `gin_clean_pending_list`, or opportunistically by an inserter once the
list exceeds `gin_pending_list_limit` (GUC or per-index reloption). Cleaners serialize on a
heavyweight page lock on the metapage; the insert-path cleaner uses `ConditionalLockPage`
and gives up if someone else is cleaning, while VACUUM waits. A large pending list shows up
directly in `gincostestimate` as startup cost.

Builds bypass the tree: `ginbuild` accumulates `(attnum, key) -> TID list` in a red-black
tree bounded by `maintenance_work_mem`, flushes it in key order with `ginEntryInsert`, and
WAL-logs the finished index with one `log_newpage_range`. Parallel builds sort `GinTuple`s
with `tuplesort_begin_index_gin`; workers do a first merge pass, the leader a second, merging
same-key runs through a `GinBuffer` before `ginEntryInsert`.

## Concurrency

Both tree kinds are Lehman and Yao B-trees with right-links only (no backward scans).
Readers hold one pin plus share lock at a time and never lock a parent while holding a
child. `ginStepRight` acquires the sibling before releasing the current page, which is the
interlock against concurrent page deletion. Inserters descend share-locked, keep pins on the
path, and re-lock the leaf exclusively. A split writes one `XLOG_GIN_SPLIT` record and leaves
`GIN_INCOMPLETE_SPLIT` set on the left page; inserting the downlink into the parent is a
separate `XLOG_GIN_INSERT` record that clears the flag on the child in the same record. The
next inserter to walk over an incomplete split repairs it (`ginFinishOldSplit`). Posting-tree
page deletion takes a cleanup lock on the posting-tree root, which excludes inserters, and
holds the left siblings of the whole path. Deleted pages record a delete XID in
`pd_prune_xid` and are recycled only when `GinPageIsRecyclable` says no reader can still
follow a stale downlink.

Predicate locks (`ampredlocks`): leaf pages only, the posting-tree root for a key that has
one, and always the metapage to conflict with pending-list inserts. With fastupdate on this
degrades to an effective whole-index lock for serializable transactions.

Recent bug fixes concentrated here: posting-tree deletion with incomplete splits, VACUUM
during posting-tree root splits, and the pending list under multiple VACUUM scans. Injection
points `gin-leave-leaf-split-incomplete`, `gin-leave-internal-split-incomplete` and
`gin-finish-incomplete-split` exist for testing these paths.

## Scanning

GIN provides only `amgetbitmap`; `amgettuple` is NULL. Reasons: the pending list is scanned
first and may yield a TID the main tree also yields (harmless for a bitmap, fatal for a
tuple-at-a-time API), and partial-match or full scans collect TIDs into a `TIDBitmap` that
turns lossy when it exceeds `work_mem`. Consequently GIN is always a Bitmap Index Scan, never
returns ordered results, never supports index-only scans (`amcanreturn` NULL, no INCLUDE),
and cannot be unique. There is no parallel scan, though parallel build exists.

`ginNewScanKey` calls the opclass `extractQuery` per scan key, creating one `GinScanEntry`
per returned key (deduplicated across keys by `ginFillScanEntry`) and picking a search mode:
`GIN_SEARCH_MODE_DEFAULT` (only matching entries), `GIN_SEARCH_MODE_INCLUDE_EMPTY` (also the
empty-item placeholder), `GIN_SEARCH_MODE_ALL` (every non-null item; the key becomes an
`excludeOnly` filter unless it is the only key for its column), and the internal
`GIN_SEARCH_MODE_EVERYTHING`. A null scan argument makes the query unsatisfiable, since
indexable operators are assumed strict.

`gingetbitmap` then runs `scanPendingInsert`, `startScan`, and loops `scanGetItem`. The
notable optimizations:

- **Fast scan** (`startScanKey`): entries are sorted by predicted frequency and the
  triConsistent function is probed with prefixes marked FALSE to find the smallest set of
  *required* entries; the remaining *additional* entries are only checked at TIDs the required
  set produces. This is what makes "rare AND frequent" queries cheap and is only effective
  when the opclass supplies a real triConsistent function.
- **Partial match** (`collectMatchBitmap`): when `extractQuery` flags an entry as a prefix
  (`pmatch`), GIN walks the entry tree from that key while `comparePartial` says to continue,
  unioning all posting lists into a bitmap. tsvector prefix search and pg_trgm rely on this.
- **Fuzzy limit** (`gin_fuzzy_search_limit`): entries predicted to return more than the
  limit have TIDs dropped randomly in `entryGetItem`. A soft, non-deterministic cap.

`keyGetItem` fills `entryRes[]` with `GIN_TRUE`/`GIN_FALSE`/`GIN_MAYBE` (lossy pages force
MAYBE), uses triConsistent to skip cheaply and the boolean consistent function for the final
verdict and the `recheck` flag. `scanGetItem` ANDs all keys and applies `excludeOnly` keys as
filters. GIN does not use `kill_prior_tuple`.

## Opclass contract

Support functions (numbers in `gin.h`, signatures checked by `ginvalidate`):

| Proc | Purpose |
|---|---|
| `GIN_COMPARE_PROC` | order two keys; may be omitted if the key type has a default btree opclass |
| `GIN_EXTRACTVALUE_PROC` | item to keys (`nentries`, optional `nullFlags`); required |
| `GIN_EXTRACTQUERY_PROC` | query to keys plus `strategy`, `pmatch`, `extra_data`, `nullFlags`, `searchMode`; required |
| `GIN_CONSISTENT_PROC` | boolean check over `check[]`, sets `recheck` |
| `GIN_TRICONSISTENT_PROC` | ternary check over `GinTernaryValue check[]`, no recheck argument |
| `GIN_COMPARE_PARTIAL_PROC` | enables partial match |
| `GIN_OPTIONS_PROC` | opclass options (no core GIN opclass uses it) |

Only one of consistent and triConsistent is mandatory. `ginlogic.c` derives the other:
`shimBoolConsistentFn` maps MAYBE to true-with-recheck; `shimTriConsistentFn` brute-forces up
to `MAX_MAYBE_ENTRIES` MAYBE inputs and otherwise answers MAYBE. `nkeys` seen by the opclass is
`nuserentries`, never including the hidden placeholder entry GIN may append.
`amadjustmembers` gives the two extract functions hard dependencies and everything else soft.

Built-in opclasses: `array_ops` (`ginarrayproc.c`), `tsvector_ops`
(`src/backend/utils/adt/tsginidx.c`; exact lexeme keys, no `siglen`, which is a GiST
concept), `jsonb_ops` and `jsonb_path_ops` (`jsonb_gin.c`, see `jsonb-operators.md`).
Contrib: `btree_gin`, `pg_trgm` (`gin_trgm_ops`), `hstore` (`gin_hstore_ops`), `intarray`
(`gin__int_ops`).

## VACUUM

`ginbulkdelete` cleans the pending list, then walks entry-tree leaves left to right:
inline posting lists are filtered through the callback and rewritten (converting any pre-9.4
uncompressed lists), posting-tree roots are collected and vacuumed with
`ginVacuumPostingTree` (leaf pass, then a page-deletion pass under a root cleanup lock if any
leaf became empty). `ginvacuumcleanup` handles the analyze-only autovacuum case, recomputes
`GinStatsData` by scanning all pages with a read stream, records recyclable pages in the FSM,
and writes stats to the metapage (`XLOG_GIN_UPDATE_META_PAGE`). It reports the heap tuple
count as the index tuple count, which is wrong for partial indexes and known.

## Cost estimation

`gincostestimate` in `selfuncs.c` actually calls the opclass `extractQuery` for each qual
(`gincost_pattern`) to count exact, partial and search entries. Partial matches get a flat
penalty per entry, scaled against the total entry count; their data pages are charged as
startup cost because the bitmap is collected up front. Pending pages add directly to startup.
Metapage statistics are as of the last VACUUM and are scaled for growth up to a cutoff.

## Tests

`src/test/regress/sql/gin.sql` covers fastupdate and `gin_clean_pending_list`, the
rare-and-frequent fast scan, fuzzy limit, `GIN_SEARCH_MODE_ALL` and excludeOnly cases, a
recheck-count harness built on `EXPLAIN (ANALYZE, FORMAT json)`, posting-tree vacuum, and
`ginbuildempty`. `src/test/modules/gin/sql/gin_incomplete_splits.sql` uses injection points
plus pageinspect to leave and then repair incomplete splits. `contrib/amcheck` provides
`gin_index_check` (`verify_gin.c`) with `sql/check_gin.sql` and `t/006_verify_gin.pl`.
Opclass-level coverage lives in `jsonb.sql`, `tsearch.sql`, `arrays.sql` and the contrib
module tests.

## Change rules

- Page and tuple layouts in `ginblock.h`, the posting-list encoding, and the category codes
  are on-disk formats; changing them requires a `ginVersion` bump and compatibility code like
  the existing uncompressed-list handling.
- New WAL record types go in `ginxlog.h`, `ginxlog.c` (redo and mask) and
  `src/backend/access/rmgrdesc/gindesc.c`.
- A new opclass needs `pg_opclass.dat`, `pg_opfamily.dat`, `pg_amop.dat`, `pg_amproc.dat`
  entries, must pass `ginvalidate`, and should implement triConsistent if it wants the fast
  scan to prune anything.
