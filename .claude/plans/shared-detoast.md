# Shared detoast of toasted Vars: implementation plan

Goal: a toasted column referenced by several operators or functions inside one plan
node is detoasted once per row instead of once per reference. Concept taken from Andy
Fan's "shared detoast datum" v10 (CF 4759): detoast lazily on first access, write the
plain datum back into the slot's tts_values[], own the memory in a per-slot context,
free it when the slot's values are invalidated.

The executor mechanism is built once as a shared base. The open design question, who
decides which attributes to pre-detoast, is settled by racing two deciders on that
base against predefined criteria. Guard suite and runner: `.claude/harness/` (also on
the VM under ~/pg/harness); the v10 patch is at ~/pg/harness/v10-shared-detoast.patch
on the VM.

## Constraints every phase must keep

1. No measurable regression when a column is referenced once, or not toasted.
2. Never let a pre-detoasted (fat) datum reach a node that stores tuples formed from
   slot values: Sort, IncrementalSort, Hash, HashJoin outer side (batch spill),
   Material, Memoize, Agg, WindowAgg, Group, Unique, SetOp, RecursiveUnion, CTE,
   MergeJoin inner (mark/restore), Gather/parallel tuple queues, ModifyTable
   (heap_update would re-toast and lose pointer identity), hashed SubPlans. Note: copies made from a slot that holds a physical tuple use that tuple,
   not tts_values, so the leak path is always a projection into a virtual slot that
   carries the bare Var and is later materialized.
3. Functions that read the raw datum keep seeing it: pg_column_size,
   pg_column_compression, pg_column_toast_chunk_id, NullTest, length/octet_length
   (toast_raw_datum_size). Slice readers keep slicing: substr/substring, starts_with,
   left/right, overlay.
4. Detoast lazily, at the first access of the row, so a failing first qual costs the
   same as today.
5. JIT and interpreter behave identically.

## Architecture: shared base plus a swappable decider

The base owns everything from the bitmap downward:

- Per-node input: `Bitmapset *ss_predetoast_attrs` on ScanState (later per side on
  JoinState). Attribute numbers whose Var references should compile to the new steps.
- `ExecInitExprRec` T_Var case: if the attribute is in the bitmap, emit
  `EEOP_SCAN_VAR_TOAST` (later OUTER/INNER variants) instead of `EEOP_SCAN_VAR`.
- The step: deform as today; if the datum is external or compressed, detoast into
  `slot->tts_detoast_cxt` (lazily created child of tts_mcxt) and overwrite
  `tts_values[attnum]`. Short-header values are left alone.
- Context reset wherever tts_nvalid drops to 0: generic `ExecClearTuple`/`ExecStore*`
  wrappers, not inside per-AM slot ops, guarded by `if (unlikely(cxt))` so unused slots
  pay one branch.
- Permission: `EXEC_FLAG_ROW_CONSUMER` meaning "my parent consumes rows one at a time
  without storing them". Set in `standard_ExecutorStart` for non-parallel-worker
  execution; forwarded only by audited pass-through nodes (Result, Limit, Append,
  MergeAppend, SubqueryScan, ProjectSet, LockRows, NestLoop both sides, MergeJoin outer
  only; HashJoin never); everything else drops it, so the default is deny. A candidate
  attribute is enabled if the node projects and the attribute is not projected as a
  bare Var, or if the flag is present. A node without projection returns its scan
  slot, so all attributes count as projected there.
- JIT: emit a call to an interpreter helper for the new opcodes.
- Raw-reader and slice-reader function lists (OID arrays with a comment on the future
  pg_proc attribute); unknown functions count as full detoasters.
- Developer GUC to turn the feature off for A/B runs.
- The base ships with a stub decider that fills the bitmap with nothing, so the base
  alone is a verified no-op.

The decider computes the reference counts: per attribute, the number of Var
occurrences used as an argument of FuncExpr/OpExpr/ScalarArrayOpExpr/DistinctExpr/
NullIfExpr/CoerceViaIO/etc. whose function is not on the raw or slice list; count >= 2
with typlen == -1 and storage != plain makes a candidate. Two deciders are built:

- **A, executor-only.** A walk over the node's targetlist and qual at
  `ExecInitScanTupleSlot`, the common setup point of every scan node type, where the
  tuple descriptor is known. Cost: one extra expression walk per `ExecutorStart`.
- **B, planner counts.** Counting piggybacks on `fix_scan_expr`/`fix_join_expr` in
  `setrefs.c`, which already visit every Var, and lands in one new Bitmapset field on
  Scan (later Join) nodes, copied into the ScanState at init. Toastability is
  re-checked at init against the tuple descriptor. Cost: one Plan field with
  out/read support, paid once per plan and cached.

Both use the same eflags permission. The full-planner variant (v10's `createplan.c`
forbid list, cross-node precision) is not built up front; the race records how many
candidates the eflags rule denies so its value can be judged with numbers.

## Verified before start (2026-09-02, master e073b64d33)

- Every scan node type calls ExecInitScanTupleSlot before ExecInitQual and before
  projection setup, so decider A's hook point sees the descriptor first and the
  bitmap is ready when Vars compile.
- copy_minimal_tuple for BufferHeap/Heap/Minimal slots copies the physical tuple;
  only the Virtual slot forms a tuple from tts_values. This is the basis of
  constraint 2's leak rule.
- Holdable portals persist through tstoreReceiveSlot_detoast, which detoasts every
  toasted value anyway, so they are not a leak concern; drop them from the deny list.
- Plan shapes: cheap jsonb expressions in the targetlist are evaluated in the scan
  below a Sort (handled by scan-level pre-detoast); a WHERE with two jsonb predicates
  under GROUP BY is a scan Filter (handled); expressions over a joined table are
  evaluated at the join with the scan returning its whole tuple (needs Phase 4).
- INJECTION_POINT compiles to `((void) name)` without --enable-injection-points, so
  a point in detoast_attr costs nothing in production builds.

## Review (2026-09-04)

The /code-review skill was attempted twice (high, then medium effort) and both runs
died on the session rate limit, so the diff was reviewed by hand instead. Findings,
all fixed in one commit with tests:

- Top-level ROW_CONSUMER grant applied to every receiver, including SPI, SQL functions
  and tuplestores, which copy the projected tuple: a RETURN QUERY would have stored
  full documents. Grant now depends on the DestReceiver kind.
- Raw-reader veto (pg_column_size etc.) only covered the deciding node; an ancestor
  reading a bare-projected column raw saw the detoasted form. New top-down pass
  apply_raw_reader_vetoes() maps ancestor raw reads through targetlists to scans. A
  first version of the pass keyed the veto by output position instead of scan
  attribute number and did nothing; the original test could not tell (size and
  compression of an uncompressed external value look the same either way), the
  toast chunk id can.
- Scan below an Agg could detoast a column the aggregate keeps (count(DISTINCT doc));
  agg_kept_input_attrs() shared between the Agg's and the child scan's decisions.
- NestLoop parameters excluded from the outer sets (Memoize cache keys).
- /simplify was not run as a skill (same budget reason); simplifications applied by
  hand: shared helpers for aggregate-kept and nestloop-parameter attributes.

## Review follow-ups (2026-09-06)

- Item 6: Scan.predetoast_attrs_noproj folded into predetoast_attrs_safe plus a flag
  predetoast_noproj; the executor uses the set only if its projection decision matches
  the planner's guess. get_relnatts() revived for that guess. (e622638450)
- Item 7: module test for the nestloop-parameter exclusion (hash index on doc,
  parameterized inner scan; 5 detoasts with the exclusion, 2 without).
- Item 13/11: `shared-detoast` is now four commits without the notes: mechanism and
  scan decision (31 files, +864/-13), joins/aggregates/parent rules (15 files,
  +475/-12), EXPLAIN and tests (14 files, +714/-13), doc. Each intermediate tree was
  built and verified (A: guard phase 1 and regression; B: guard phase 6 and
  regression; C: module, regression, postgres_fdw). The notes stay on detoast-plan2.
- Item 15 (2026-09-10): planning cost is +547 instructions on the no-help statement
  and +2,489 (4% of its planning) on the two-reference jsonb statement, paid once per
  plan; numbers in the baseline file, with a possible follow-up (skip get_attstorage
  when the type decides).
- 2026-09-10, follow-up done: one type fetch instead of two lookups, raw-reader pass
  gated on PlannerGlobal.hasPredetoastAttrs, no list copies in the pass. Fifth commit
  of the series; remeasured on the VM (see baseline).
- Item 4 (2026-09-10): short-header widening loses 1.9% on the two-reference inline
  statement and wins 1.4% on the 20-reference one; not adopted, branch deleted. A
  plan-time reference-count threshold would be the way to revisit.
- 2026-09-10: the macOS temp cleaner had removed parts of the scratchpad build after
  four idle days; rebuilt from scratch, branch tip re-verified (module, guard, regress).
  Series regenerated: 864 / 508 / 747 / 20 lines added per commit.
- 2026-09-10, VM: tip c39abcd666 on the cassert build: guard 30/30, module pass,
  check-world clean. All review follow-ups closed.
- Item 12: /code-review at low effort completed on the split series and found two
  gaps of the ancestor-raw-reader family (join sets under permission, nestloop
  parameters under permission); fixed in apply_raw_reader_vetoes with two module
  cases. The earlier high/medium runs had hit the session rate limit.

## Closing batch (2026-09-15)

- Guard-only shapes moved into the in-tree module: holdable cursor (one detoast at
  COMMIT while the cursor is persisted), PL/pgSQL FOR loop through SPI, forced JIT
  settings, and the parallel case, which compares EXPLAIN (BUFFERS) block counts of
  the two-reference and one-reference statements because workers do not see locally
  attached injection points (0 extra blocks). 67 notices pinned. Series test commit
  regenerated; the tree equals detoast-plan2. Mac (new persistent build under
  ~/pg-build): module, guard 30/30, regression 240/240. VM cassert: module, guard,
  check-world clean.
- Measurement scripts (perfbench.sh, profile2.sh, build.sh) and the 2024 v10 patch are
  in .claude/harness/vm and .claude/harness/prior-art (622487e189); the VM keeps only
  the B2 debug/jit/perf builds and the base perf build (3.5 GB).
- The intermittent VM name resolution failure was the user's VPN, not the box.
- Xcode update on the Mac blocked compiles until the licence was accepted; the temp
  cleaner purged the scratchpad build a second time, hence the ~/pg-build location.

- /code-review at low effort on the five-commit series (2026-09-16) found one gap:
  the "projected bare" checks recognised only a Var at the root of a targetlist
  entry, while the executor compiles a Var under RelabelType, a CASE result,
  COALESCE, GREATEST/LEAST or NULLIF to the same step. Reproduced: a CASE arm
  returning doc whole under OFFSET 0 lost the pointer for an ancestor
  pg_column_toast_chunk_id(), and the same shapes under a Sort stored the fat value.
  Fixed with pull_passthrough_attrs() at all five sites (scan and join bare sets,
  bare_vars_of_side, aggregate kept args, raw-reader mapping in
  apply_raw_reader_vetoes), folded into series commits 1 to 3 (71def8ecf0 on
  detoast-plan2, series tip e28df084a4). Three module cases; Mac module, guard,
  regression 240/240 and postgres_fdw clean; VM cassert: module, guard,
  check-world clean on e28df084a4; both regenerated intermediate commits build.

### Shapes excluded by design, and why

Each of these keeps the default: the scan below still shares within its own
expressions (the "safe" set), and what is lost is only the sharing across the node
boundary named.

- MergeJoin inner side (join->predetoast_inner_* stay empty, set_join_predetoast_attrs
  and set_child_predetoast_noproj). The node saves the current inner tuple with
  ExecCopySlot into mj_MarkedTupleSlot and later evaluates merge clauses and join
  quals against that copy instead of the child slot. Whether the copy carries the
  detoasted value or the original pointer depends on the child slot's ops (physical
  copy from the tuple vs copy of tts_values), so the same Var would sometimes read a
  fat value living in another slot's detoast context. Either the copy step or the
  marked slot would need its own reset discipline; not worth it for the inner side of
  a merge join, whose inputs are usually sorted index scans.
- WindowAgg inputs. The node buffers its input in a tuplestore and evaluates window
  function arguments, partition and order expressions on rows read back from it into
  several slots (agg_row_slot, temp slots, frame head/tail slots). A "Pre-detoast
  Outer" set like Agg's would have to be honoured on each of those slots with a reset
  whenever the tuplestore position moves, and a child projecting the column bare into
  the store would put the fat value into the tuplestore if the child slot is virtual.
  WindowAgg is treated as a storing parent (noproj widening allowed below it, since
  storing copies physically from heap slots), but it gets no set of its own.
- Grouping sets and mixed aggregation (agg->groupingSets, chain, AGG_MIXED). One Agg
  then runs several phases with different grouping column sets, and the hashed
  phases copy input columns into hash table entries from the input slot's values.
  agg_kept_input_attrs would need the union over all phases and sets, and the
  sort-based phases re-read the input from a tuplesort. The Agg set is skipped and
  the noproj widening for a scan directly below such an Agg is denied.
- Pass-through chains below storing parents (Limit, LockRows, Append, MergeAppend,
  Result without projection). These return the child's slot unchanged, so a Sort or
  Hash above them copies the scan slot. The plan-time noproj rule looks one level
  only: the scan's parent is the pass-through node, which is an "unknown parent",
  so the widening is not applied. The executor permission bit does travel through
  them (EXEC_PASS_ROW_CONSUMER), but only from the top-level grant; a storing parent
  clears it, and a single bit cannot carry per-attribute exclusions. Recursing through
  Limit/LockRows at plan time is a possible follow-up; Append and MergeAppend would
  need per-child handling because their children have different attribute numbers.
- Virtual-slot scans without projection (IndexOnlyScan, ValuesScan, SubqueryScan,
  CustomScan; ForeignScan with scanrelid 0 goes the same way via tlist_matches_tupdesc
  with INDEX_VAR). The noproj widening relies on the parent copying from the heap
  tuple, which keeps the toast pointer; these scans' slots are virtual, or of a type
  chosen by the subquery or the provider, so a storing parent would copy tts_values
  and store the detoasted value. With a projection the scan writes its own result
  slot and the normal safe set applies.

## Review of the five-commit series (2026-09-18)

Full read of the series diff plus experiments on the Mac build (tip ead970111e).
Findings and what was done, folded into the owning commits with
`git rebase --autosquash` (fixups keyed to commits 1 to 3; the folded tree equals
the tested tree except for the position of one function):

- apply_raw_reader_vetoes skipped scans under Append/MergeAppend: the Append
  branch recursed with raw_above but the trimming of a scan's sets only ran in the
  parent's side loop. Reproduced with a partitioned table under OFFSET 0
  (pg_column_toast_chunk_id NULL). Fixed by plan_input_plans(), which expands
  Append/MergeAppend chains into their members and is used by both planner passes;
  set_child_predetoast_noproj now reaches partition scans too (Sort over a
  partitioned table shares). Prior art for the "transparent nodes" idea is
  ExecSetTupleBound() in execProcnode.c; there is no generic Plan-tree walker in
  core (planstate_tree_walker is PlanState only), so the helper stays local to
  setrefs.c like its other statics.
- Correlated SubPlan args carried the detoasted value into the subplan, where
  pg_column_size/pg_column_toast_chunk_id saw the fat form (reproduced: 59952 vs
  59948, chunk id NULL). Vars passed as SubPlan args are now vetoed in
  pull_multi_detoast_walker and pull_raw_reader_walker, like nestloop parameters.
- ExecScanPredetoastAttrs chose INDEX_VAR only for IndexOnlyScan or scanrelid 0,
  while ForeignScan/CustomScan with fdw_scan_tlist/custom_scan_tlist and
  scanrelid > 0 use INDEX_VAR (nodeForeignscan.c:188, nodeCustom.c:77), so
  tlist_matches_tupdesc's varno Assert would fire for such providers. New
  ScanUsesIndexVar() in plannodes.h is used by the executor, the planner's relid
  choice and EXPLAIN.
- Hashed Agg spill copies the needed columns out of the input slot by value
  (hashagg_spill_tuple, all_cols_needed false), so a physical-tlist scan's
  in-place detoast went to disk whole: 19256 kB vs 216 kB temp for 3000 x 20 kB
  docs at work_mem 64kB. New agg_spilled_input_attrs() (plan-time counterpart of
  find_cols) excludes every input column a hashed Agg reads from the noproj
  widening; the Agg's own set is unaffected (advance_aggregates runs after the
  spill decision).
- DestIntoRel/DestTransientRel removed from dest_consumes_rows: toast_tuple_init
  fetches foreign external values with detoast_external_attr (no decompression),
  so a value arriving decompressed would have to be compressed again.
- tts_buffer_heap_copyslot's fast path refilled a buffer slot through
  tts_buffer_heap_store_tuple without the detoast reset; no reachable slot was
  found, but the reset now lives in tts_buffer_heap_store_tuple so every refill
  path resets.
- EXPLAIN: scan sets are deparsed like join sets (useprefix as for Output), which
  fixes the blank "Pre-detoast: " for an aggregate-pushdown foreign scan and
  prefixes names when more than one relation is in the plan; join-side candidates
  skip child targetlist entries that are Consts (looking through PlaceHolderVars),
  removing the ('constant'::text) line from join.out.
- Tests: the ancestor raw-reader cases put the bare column first, where the
  projection copied the pointer before the expressions detoasted, so they passed
  without the veto; reordered. New module cases: partitioned raw reader, Sort
  over a partitioned table, SubPlan parameter, hashed Agg over an aggregated
  column, CTAS now keeps the pointer (four detoasts for two rows).
- Checked and fine: deform ranges (walker based), reset coverage of all
  ExecStore*/ExecClearTuple/ExecForceStore* paths, EPQ (testslot cleared),
  holdable cursors, Memoize keys via the nestParam exclusion, JIT dispatch, GUC
  wiring; sorted Agg's firstSlot is never a TOAST-step target because grouping
  columns are always bare in the Agg tlist.

## Alternative approach: sidecache (2026-09-19)

detoast-sidecache keeps the copy beside the slot (tts_detoasted) and hands it only to
argument positions, which removes the whole permission model (about 585 lines of
setrefs.c and 230 of clauses.c) and covers the shapes the series excluded (merge join
inner, hashed grouping columns, bare projection under storing parents).  Cost: about
160 more instructions per statement at expression-compile time, and one extra
detoast when the client receives the bare column next to expressions over it.
Numbers and shape table in shared-detoast-baseline.md; verification identical to the
series (Mac, VM cassert check-world, fork CI).

## Series regenerated on the side-array design (2026-09-19)

`shared-detoast` is now a four-commit series built from the detoast-sidecache tree
(same tree as cfb6f78ea9): mechanism + scan decision (execExpr.c ExecInitDetoastArg
and the EEOP_*_VAR_TOAST / EEOP_ASSIGN_*_VAR_TOAST steps, side array tts_detoasted,
planner counting, GUC), joins/aggregates/window functions (per-side sets, merge and
hash clauses through the argument path, probe-side hash keys counted twice),
EXPLAIN + tests, doc. The planning-overhead commit is gone: its content is either
built in (typcache lookups) or moot (no veto pass). Intermediate commits 1 and 2
compile; tip: module (93 notices), regression 239/239 (with.out, create_view.out,
returning.out gain Pre-detoast lines), postgres_fdw clean, pgindent clean.

Benefit-only extensions folded in beyond the first sidecache commit: WindowAgg set;
merge clause sides (ExecInitExprArg) and hash keys (ExecBuildHash32Expr) compiled as
argument positions; projections of a marked column carry the copy into the result
slot's side array (EEOP_ASSIGN_*_VAR_TOAST, dropped by tts_virtual_materialize);
child output columns that are Const or RowExpr skipped for join sets.

Branch layout: `shared-detoast` = the series; `detoast-plan2` = series + these notes
(the three measurement commits replayed); `detoast-sidecache` = development history
on top of the old in-place series; `detoast-inplace` = the old in-place series +
notes as they were before the regeneration. Still open: VM cassert check-world, guard
suite, harness and benchmarks on the series tip, fork CI.

## Application benchmark on the side-array series (2026-09-20)

The user's 70-environment benchmark, same data and SQL, Docker images :latest
(in-place design, ead970111e, before the review fixes) and :series (side array,
5522903769):

| build | shared_detoast | total | buffers |
|-------|---------------:|------:|--------:|
| :latest | off | 49,399 ms | 44,168,785 |
| :latest | on  | 14,287 ms | 5,905,453 |
| :series | off | 55,501 ms | 44,168,722 |
| :series | on  | 20,708 ms | 9,725,992 |

Per environment (bench_result tables in containers pg-bench-detoast and
pg-bench-series): 44 of 70 have identical buffer counts under both builds; the other
26 read about 1.8x more on :series, and every one of them has a correlated SubPlan
implemented as a Function Scan over the jsonb column (jsonb_array_elements_text(
attribute_values -> key) ... value ~~ ANY(...)) executed once per candidate row
(env034: 248k + 256k + 20k loops).  The outer Var is handed to the SubPlan as a
parameter.  :latest wrote the detoasted value back into tts_values, so the subplan
received the fat copy and did not detoast again; that is one of the boundaries the
review round later vetoed as unsafe (a subplan may read the stored form).  The side
array passes the stored pointer by construction, so the subplan detoasts per
execution.  Results identical across builds.  The 12% "off" difference (49.4 vs
55.5 s, identical buffers) is not attributable without an interleaved rerun; the
instruction harness puts the off path within 0.5% of master.

Possible follow-up: treat SubPlan parameters as argument positions when a walk over
the subplan's plan shows every use of the corresponding PARAM_EXEC Param is itself an
argument position of a function that does not inspect the stored form; the copy's
lifetime (the outer slot's current row) covers the correlated execution.  Would
recover these 26 environments safely.
## Parameters share the outer row's copy (2026-09-20)

Closes the subplan-parameter gap from the application benchmark by the same rule
as slots. ParamExecData carries a reference (slot, attnum) to the column the
value came from, set by EEOP_PARAM_SET for a plain Var argument of a correlated
SubPlan and by NestLoop for nestParams; value stays the stored datum, and the
initplan and parallel-restore writers clear the reference. A varlena PARAM_EXEC
Param in an argument position compiles to EEOP_PARAM_EXEC_TOAST
(ExecEvalParamExecToast), which follows the reference into the source slot's side
array, makes the copy there on first use, and reuses it for later references and
later executions for the same outer row. The reference is followed only while the
slot still holds the same datum (pointer equality against tts_values), so a stale
one can at worst miss the copy. Set-returning function arguments (execSRF.c) are
compiled as argument positions, since jsonb_array_elements_text($1 -> key) in FROM
is the benchmark's shape. Module: correlated EXISTS over jsonb_each_text($1), a
subplan reading $1 per inner row, and a LATERAL aggregate with a nestloop parameter
all detoast once per outer row; pg_column_toast_chunk_id($1) still sees the pointer.

Series is five commits now: mechanism+scan, joins/aggregates/window, parameters,
EXPLAIN+tests, doc (tip d3e8b9b31c). Verified on the Mac: module (94 notices),
regression and postgres_fdw runs in progress at the time of writing; VM cassert,
harness, benchmarks and CI still to do on this tip.

## Open refinement: single outer-side reference in a join qual (2026-09-20)

Observed while checking the parameter-sharing commit (case D of the ad-hoc test):

    SELECT count(*) FROM target t
    WHERE EXISTS (SELECT 1 FROM generate_series(1, 5) g
                  WHERE t.attribute_values ? ('k' || g) AND t.attribute_values ? 'k1');

The planner pulls the EXISTS up into a nested-loop semi-join, so no parameter is
involved: the constant predicate becomes the scan's Filter (one reference) and the
other becomes the Join Filter (one OUTER_VAR reference), evaluated once per inner
row while the outer tuple stays the same.  A node with a single reference gets no
set, so the join filter detoasts the column once per inner row: with 3 outer rows
and 5 inner rows, 15 detoasts in the join plus 3 in the scan.  The same holds for
hash and merge joins: the join filter runs once per matching inner row against an
unchanged outer tuple.  Inner-side references gain nothing (the inner tuple changes
per row).

Refinement: in set_join_predetoast_attrs, count every outer-side argument position
in joinqual and qual twice, as the hash join's probe-side keys already are (hashed,
then compared), for all three join types.  The join's OUTER_VAR_TOAST step then makes
the copy in the outer child's slot on the first inner row and reuses it.  Case D
would go from 18 detoasts to 6.  The remaining 3 are the scan's own single-reference
qual; sharing those too needs the scan to know that a parent reads the column, i.e.
cross-node counting, which is a larger change and not planned.

Size: about ten lines in the planner plus a module case pinning the count.  Not
implemented; the parameter-sharing commit does not depend on it, and the user's
production plans keep their SubPlans (covered) rather than pulled-up semi-joins.

## Independent review of the five-commit series (2026-09-22)

A fresh-context review of the series found one wrong-result bug and two
hardening items, all fixed the same day:

- ExecForceStoreMinimalTuple's minimal-tuple branch calls tts_minimal_store_tuple
  directly and so bypassed the detoast reset that lived in ExecStoreMinimalTuple.
  A multi-batch hash join re-reads probe-side tuples from a batch file through that
  path; the slot kept the first tuple's copy and the hash clause matched every later
  tuple against it. Reproduced: CTE scan (minimal tuples) as probe side of an
  8-batch hash join on a toasted text key, 1883 rows instead of 15000. The reset now
  lives in the store functions of all slot types (tts_heap_store_tuple,
  tts_minimal_store_tuple, tts_buffer_heap_store_tuple), so no wrapper can be
  bypassed; module case with a two-batch join added at the end of the file.
- The heap, minimal and buffer materialize functions now reset too, since a copy
  carried in by EEOP_ASSIGN_*_VAR_TOAST points into another slot that a
  materialized slot may outlive (latent, no in-tree reader).
- ExecScanSubPlan/ExecHashSubPlan writers of param values clear detoast_slot
  (harmless before, since those ids are never set from a Var).

The reviewer traced and found consistent: attnum/varno mapping, the argument
position list, stored-form readers, expanded datums, the parameter equality guard,
all other slot refill paths, JIT parity, and context lifetimes. IndexOnlyScan never
gets a set because set_plan_refs returns early for it: a missed optimization to
note.

## Second review round (2026-09-22)

No confirmed correctness problem. Three items taken:

- A stored-form reader reached through a non-inlined wrapper function (SQL
  SECURITY DEFINER, PL/pgSQL, extension C code using the raw varlena) sees the
  fetched value when its column argument is marked; only direct calls of
  pg_column_size/pg_column_compression/pg_column_toast_chunk_id see the pointer.
  Inherent in passing detoasted arguments; documented in the GUC description.
- Out-of-tree TupleTableSlotOps could bypass the reset; ExecCopySlot and
  ExecMaterializeSlot now reset in the generic wrappers as well, and the ops struct
  comment states the obligation. A read-time pointer-equality guard was considered
  and rejected: a slot that frees and reallocates tuples can put the next tuple at
  the same address, so equal pointers do not prove equal bytes (the parameter guard
  is sound only because refills reset first).
- IndexOnlyScan never got a set (set_indexonlyscan_references returned before the
  common call); fixed, module case with an INCLUDE'd compressed column.

Verified sound by the reviewer: every tts_values/tts_nvalid writer outside
execTuples.c, carried entries across child advances, parameter re-entrancy under
Memoize/Material/initplans/MULTIEXPR/recursive CTEs/parallel, expanded and read-only
datums, JIT parity and fast paths, planner attnum spaces incl. INDEX_VAR and
partitions.

## Rebase log

## Slot-reset hardening (tip 3561bc0f47, base upstream e8a3ee5b19), 2026-09-22

Correctness round folded in as three fixups (verified tip 49e46f72e5 -> 3561bc0f47,
2 upstream commits further):
- ExecSlotResetDetoast moved into the slot ops (tts_heap/minimal/buffer_materialize
  and _store_tuple) and into ExecMaterializeSlot, instead of only the ExecStore*
  wrappers. Fixes a real bug: a slot refilled off the ExecStore*/ExecClearTuple path
  -- ExecForceStoreMinimalTuple re-reading a multi-batch hash join's probe tuples from
  a batch file -- kept a stale detoasted copy that satisfied the hash clause for every
  following tuple. TupleTableSlotOps header now documents the requirement for out-of-
  tree AMs.
- set_indexonlyscan_references now calls set_scan_predetoast_attrs (that path returns
  early from set_plan_refs, so index-only scans previously got no set); index-only
  scans move off the excluded list.
- Module gains two cases: a multi-batch hash join over an EXTERNAL text column via a
  MATERIALIZED CTE (minimal-tuple probe side), and an index-only scan over an INCLUDE
  column stored compressed.

Verified: Mac pgindent, build (0 warnings), module (both settings), regression
239/239, postgres_fdw, guard 30/30; VM cassert module, guard, check-world; harness
deltas unchanged; workload CPU as before (Bartunov 1.5-2.5x, JSONBench neutral, off =
master, results identical); fork CI run 35730391205 fully green (Linux incl. ASAN, macOS, both Windows toolchains). detoast-plan2
rebased onto it. Not pushed to shared-detoast/detoast-plan2 on the fork; the acceptance
cost matrix in shared-detoast-baseline.md was run on the previous tip 49e46f72e5,
whose relevant code (the detoast fast paths) this round does not change.
- 2026-09-22: series rebased onto upstream master d39fda1cc4 (17 commits; upstream
  touched join.out and collate.icu.utf8.out, no conflicts). Tip 49e46f72e5: Mac
  pgindent, build, module (both settings), regression 239/239, postgres_fdw, guard
  30/30; VM cassert module, guard, check-world; harness deltas unchanged (loop_noop
  +197, loop_jsonb +224, loop_wide +1.0%, toasted -28% / -52%); workload CPU as before;
  fork CI run 35695224475 fully green. detoast-plan2 rebased onto it. Not pushed to
  the fork's shared-detoast/detoast-plan2 (only shared-detoast-ci and master).
- 2026-09-18 (later): series rebased onto upstream master 26a3c0a45c (5 commits, no
  overlapping files). Tip 0dd7d83df5: Mac module (default and
  debug_parallel_query=regress), guard 30/30, regression 239/239, postgres_fdw clean;
  VM cassert module, guard, check-world clean; fork CI run 35322881306 green except
  Linux 32-bit, where test_checksums/013_rewind failed ("last common checkpoint is a
  shutdown checkpoint"), an upstream area the series does not touch and which passed
  in the VM check-world. Style pass afterwards: 16 added code lines of 88 columns or
  more wrapped (one deep execExpr.c condition left), pgindent --check clean over all
  34 touched C files, no // comments or trailing whitespace; folded into the owning
  series commits by blaming the changed lines. headerscheck/cpluspluscheck on the
  Mac report only PL/Python headers (no Python.h there); the docs build in CI.
  Final tip a165ae17ad: VM cassert module, guard, check-world clean; fork CI run
  35324841040 fully green, including Linux 32-bit (the 013_rewind failure was flaky).
- 2026-09-18, GUC as the user-facing switch: set_scan/join/agg_predetoast_attrs return
  early when shared_detoast is off, so "off" skips the planning work too (executor
  check kept so a cached plan can still be switched off at execution time);
  shared_detoast moved from Developer Options to Other Planner Options with a
  postgresql.conf.sample line and GUC_EXPLAIN (the guc regression test requires it
  for Query Tuning parameters); docs moved; module case shows EXPLAIN without the
  Pre-detoast line when off. Folded into series commits 1, 3 and 4. No per-query hint
  mechanism: core has none by design, and the GUC already works with SET LOCAL, per
  function/role settings and pg_hint_plan's Set().
- 2026-09-18, coverage batch: module gains a three-row table with a NULL, EXTENDED
  pglz storage (out of line and compressed in one call), bytea, subscripting and
  jsonpath, LEFT JOIN with and without matches, INSERT ... SELECT and CREATE TABLE AS
  (pointer kept; CTAS shares because DestIntoRel consumes rows), jsonb_agg(doc) as a
  kept argument, window functions (expressions evaluated above the WindowAgg, no
  sharing), grouping sets (denied), a SCROLL cursor with FETCH BACKWARD, UNION, and a
  bitmap heap scan. 108 pinned notices, stable over reruns and under
  debug_parallel_query=regress. Folded into series commit 3.
- 2026-09-18, workload benchmarks (numbers in shared-detoast-baseline.md): JSONBench
  10m (7M rows loaded) shows no CPU difference between master and the series in
  either GUC state; the Bartunov TOAST table shows 1.5-2.5x less wall clock and CPU
  with two to four operators and TOAST block reads down to the heap count; results
  identical across all configurations. First runs had a stale "master" (configured
  from src-base) and wall-clock cache noise; both resolved (rebuilt, interleaved CPU).
  Docker image: .claude/harness/docker (Debian bookworm, official entrypoint),
  postgres-shared-detoast:latest built on the Mac (arm64, 293 MB), verified.
  Series tip ead970111e: CI run 35332899161 fully green; VM cassert module (108
  notices), guard 30/30 and check-world clean.
- 2026-09-18, application benchmark by the user (steadybit platform, 70 real target
  predicates over a 2.4 GB table whose jsonb column is out of line on every row,
  median 8 references per predicate; notes in
  ../steadybit/platform/docs/jsonb-shared-detoast-benchmark.md): shared_detoast off
  vs on in the Docker image, same data and SQL: 50,478 -> 15,255 ms total (3.31x),
  buffer accesses 44.2M -> 5.9M (7.48x, close to the mean reference count 9.4),
  per-environment median 1.55x, faster on 60 of 70, results identical (3,389,838
  rows, 70/70 counts equal). The environments without gain have identical block
  counts in both modes: their filter is an OR of @> terms whose first term matches,
  so only one reference is ever evaluated per row. The one "slower" case is an
  8-row sub-millisecond query (noise). "off" matches postgres:19beta3 to within 80
  buffer accesses. A SQL-level workaround (jsonb_to_record behind a lateral) had
  scored 0.87x because it loses the GIN index.
- 2026-09-18, Docker image rebuilt with LLVM 14 (--with-llvm, libllvm14 at runtime;
  508 MB): pg_jit_available() true, forced JIT compiles the Pre-detoast plan
  (Functions: 2, inlining and optimization on), results correct. Upstream master
  now defaults to jit = off (7f8c88c2b87), so the image and any benchmark need
  jit = on set explicitly; EXPLAIN shows the JIT block only with costs on, which
  had hidden a working JIT during the first check.
- 2026-09-18: series rebased onto upstream master c9c660e6ae (13 commits, only
  typedefs.list overlapped, no conflicts). Tip 30c52d19e3: Mac module (default and
  debug_parallel_query=regress), guard 30/30, regression, postgres_fdw clean; VM
  cassert module, guard, check-world clean; fork CI run 35230884187 fully green.
  detoast-plan2 condensed from 71 commits to the series plus one notes/harness
  commit; the old history is kept as detoast-plan2-history on the fork.
- 2026-09-16: series (5 commits) rebased onto upstream master a4f18fd8f2 (50 more
  commits; upstream touched execnodes.h, executor.h, plannodes.h, pathnodes.h,
  lsyscache.h, join.out and typedefs.list, no conflicts). Rebased tree e35d0351e7:
  Mac module, guard 30/30, regression 239/239 (upstream dropped a test), postgres_fdw
  clean; VM cassert: module, guard and check-world clean. detoast-plan2
  merged upstream master, tree identical to the series.
- 2026-09-16, after the rebase: comment audit against the surrounding files (helper
  header form in execScan.c, one-line flag comments in executor.h, periods, one double
  blank); folded into the series. The parallel module case then failed once on the VM
  by -3 blocks (a fresh worker's catalog reads land in the shared block counts); it now
  checks abs(difference) < 10, where a missed sharing would add dozens of toast-chunk
  blocks. Series tip b075a91907: VM cassert check-world clean, module 5/5 reruns clean,
  Mac module clean.
- 2026-09-17, first CI run on the fork (GitHub Actions, PG_CI_ENABLED=1; the fork also
  needed the one-time "enable workflows" click and its master fast-forwarded to
  upstream so the workflow is registered). All jobs green except macOS - Meson: that
  job runs with debug_parallel_query=regress, so every statement of the module ran in
  a worker, which cannot see injection points attached locally, and all 50 notices
  were missing. Reproduced locally with PG_TEST_INITDB_EXTRA_OPTS; the module now sets
  debug_parallel_query = off after attaching (and back to off after the explicit
  parallel case). Verified with both settings on the Mac, also on an -O0 cassert
  autoconf build (the CI build type). Series tip f9ab0a6196, rerun as
  https://github.com/joshiste/postgres/actions/runs/35205549099.
- 2026-09-17, second CI finding: the Linux Meson 64-bit job (gcc, -fsanitize=address,
  LLVM 19, -Dbuildtype=debug) crashed inside libLLVM.so.19.1 (SEGV at +0x4850901,
  deterministic) on the module's forced-JIT statement. Probe branches of unmodified
  upstream master with only a forced-JIT module (ci-jit-asan-probe, Linux jobs only)
  crash identically, already with jit_above_cost = 0 alone, so this is an LLVM 19 +
  AddressSanitizer problem in that job, not the patch. Core regress tests that force
  jit_above_cost = 0 (aggregates, groupingsets, select_distinct, updatable_views) pass
  there, yet the third probe crashed on `SELECT id FROM sd` as the first JIT-compiled
  statement of a fresh session in a src/test/modules pg_regress run, so the trigger is
  the environment of that job, not the statement. Worth reporting upstream (the
  user's call). The module no longer forces JIT; JIT coverage instead comes from running the whole
  module and the guard suite under forced JIT (temp-config / PGOPTIONS) on the VM's
  LLVM 14 cassert build, both clean after a distclean rebuild (the incremental
  build-B2-jit had gone stale and crashed in initdb). Series tip 10c45cd10d:
  https://github.com/joshiste/postgres/actions/runs/35215567030 fully green.
- 2026-09-13: series (5 commits) rebased onto upstream master 0c5d626961 (29 more
  commits, only typedefs.list overlapped, no conflicts). Rebased tree: module, guard
  30/30, regression 240/240, postgres_fdw clean on the Mac; VM cassert: guard,
  module and check-world clean (2026-09-15). detoast-plan2 merged upstream master,
  tree taken from the series.
- 2026-09-10: series rebased from 534db08f97 onto upstream master 8db08e2522 (60
  commits), no conflicts; upstream had itself revived get_relnatts and reworked
  join.out. Rebased tree: module, guard 30/30, regression (now 240 tests) and
  postgres_fdw clean on the Mac; VM cassert check-world queued. detoast-plan2 brought
  forward by merging upstream master, tree taken from the series.
- 2026-09-03: rebased from e073b64d33 onto upstream master 534db08f97 (7 commits);
  only typedefs.list overlapped. Guard 30/30 phase 6, module, regression suite clean on
  the rebased tree (Mac); VM cassert build: guard 30/30, check-world clean.

## Findings while building the base (2026-09-02)

- Autoconf builds need `--enable-depend`, otherwise a change to tuptable.h leaves
  stale objects and the server dies with a bus error in bootstrap. Both VM builds
  and the Mac build are configured with it now.
- Representation-dependent functions (pg_column_size, pg_column_compression,
  pg_column_toast_chunk_id) must veto pre-detoasting of the attribute they inspect,
  not merely be left out of the reference count: another reference would otherwise
  make them see the detoasted value. The veto is part of the base (guard cases 13,
  27, and the suite's own setup query depend on it).
- HashAggregate directly above a scan leaves the scan without projection (the Agg
  projects), so the eflags rule denies and case 17 stays at two detoasts; with a
  Sort in between the scan projects and drops to one (case 28). Hash aggregation
  stores only grouping columns, so a parent-side attribute analysis (Phase 5)
  could allow this shape.
- The same deny hits joins directly above projection-free scans; Phase 4 handles
  those at the join level.
- One detoast costs 133 toast heap blocks plus 3 toast index blocks in EXPLAIN's
  buffer counts; the per-relation xact counters on master attribute the index
  blocks elsewhere.
- Throwaway decider (all toastable attributes) on the base: every Phase 1 win case
  reaches its target, all guards hold, UPDATE keeps its toast pointer.
- ExecInitScanTupleSlot is also called by Agg, Sort, Material, Memoize, Group,
  WindowAgg and IncrementalSort, whose states embed a ScanState while their Plan is
  not a Scan. The base now checks IsScanPlan() first; found because variant B read
  its Scan field past the end of an Agg node and crashed at EXPLAIN time (2026-09-03).
- set_plan_refs returns early for SubqueryScan (set_subqueryscan_references), so a
  plan-time decider has to hook that path separately; guard case 9 caught it.
- pull_multi_detoast_attrs() lives in optimizer/util/clauses.c and is shared by both
  deciders; the race therefore measures only when the walk runs.

## Phases

### Phase 0: baseline and guard rails (no product code)

- Branch `detoast-base` off master. Build with --enable-cassert and a second build
  without, both --enable-injection-points, --enable-debug.
- Done 2026-09-02 as `.claude/harness/detoast_guard.sql` (30 cases, master values pinned,
  patched targets per case, exit status non-zero on mismatch). Cases:
  single reference; two references in WHERE with a failing first predicate; bare Var
  projected under Sort/Hash/Agg/Material/Memoize; UPDATE ... WHERE big ? 'x' (check the
  toast value id is unchanged afterwards via pg_column_toast_chunk_id); pg_column_size,
  pg_column_compression, length; substr and starts_with; hash join both sides; nested
  loop; parallel seq scan; holdable cursor; PL/pgSQL loop; JIT on and off.
- Init-overhead microbenchmark. Verified 2026-09-02: plain `pgbench -M prepared -S`
  style runs on this Mac vary about 9% between 5 s runs, far too noisy for the race.
  Use instead: (a) an amplified query, a prepared statement over a UNION ALL of ~200
  scans each with ~50 targetlist expressions on toastable columns, so decider cost
  dominates ExecutorStart and a relative difference is visible; (b) interleaved runs
  base/A/B/base/A/B with at least 10 rounds of 30 s, comparing medians; (c) on the
  Debian VM `ssh eddie-debian` (KVM, Skylake PMU passed through: instructions and
  cpu-cycles events present, sudo without password, 8 vCPU, 9 GB), `perf stat -e
  instructions` on the same statement gives a deterministic count and is the
  preferred measurement. Needs `apt install linux-perf bison flex libreadline-dev
  zlib1g-dev liblz4-dev pkg-config` and `kernel.perf_event_paranoid` lowered or perf
  run via sudo; no rsync there, so push a branch and clone with git.
- Race scorecard `.claude/plans/shared-detoast-race.md` written 2026-09-02 with the
  criteria below and empty result columns.
- Baseline numbers recorded in `.claude/plans/shared-detoast-baseline.md` (VM layout,
  harness counts, instruction counts per workload; done 2026-09-02). Instruction
  counts repeat to within 3 instructions per iteration, so the race criterion is
  measurable as an absolute instruction delta.

Benefit: every later phase is judged against fixed numbers, the regression classes
that killed earlier attempts exist as tests before the first line of C, and the race
cannot be decided by taste because its criteria are written down first.

### Phase 1: shared executor base, scan nodes only, stub decider

Files: src/include/executor/executor.h (flag), src/include/executor/tuptable.h
(tts_detoast_cxt), src/include/executor/execExpr.h (EEOP_SCAN_VAR_TOAST),
src/include/nodes/execnodes.h (ScanState.ss_predetoast_attrs),
src/backend/executor/execTuples.c (context reset, ExecInitScanTupleSlot hook),
execExpr.c (step emission, exclusion lists), execExprInterp.c (step), execScan.c
(no-projection case), llvmjit_expr.c, execMain.c and execParallel.c (set/withhold the
flag), pass-through nodes (forward the flag), src/include/access/detoast.h + detoast.c
(detoast_attr into a given context, or a documented MemoryContextSwitchTo),
guc_parameters.dat + postgresql.conf.sample + config.sgml developer option,
typedefs.list.

Steps:
1. Slot context and its reset. Harness and check-world unchanged.
2. Bitmap field, step, JIT emission, exclusion lists, GUC, with the stub decider.
   Still a verified no-op: harness counts at baseline, microbenchmark at baseline.
3. Permission flag plumbing through the audited nodes.
4. A throwaway decider that marks every toastable attribute, used only to exercise
   the steps under the cassert build and the guard cases; removed before Phase 2.

Benefit: the mechanism is proven correct and cost-free on its own, so the race in the
next phase measures only the deciders, and either decider can be dropped without
touching the executor code.

### Phase 2: the race (done 2026-09-03, winner B2; see shared-detoast-race.md)

Branches `detoast-exec` (decider A) and `detoast-plan` (decider B), each stacked on
`detoast-base` and touching only the decider. Both must pass the same guard tests
before scoring; correctness is a gate, not a score.

Criteria, in priority order:
1. Init overhead on the no-op microbenchmark, relative to base. Lower wins; a
   difference under the measurement noise is a tie.
2. Coverage: harness cases reaching one detoast, plus the count of candidates denied
   by the permission rule (recorded, not scored, for the Phase 5 decision).
3. Size: diff lines, files touched, subsystems touched, new node fields.
4. Interaction with plan caching: B's field must survive plan copy and cached plans;
   A must not misbehave under `EXEC_FLAG_EXPLAIN_ONLY` and re-execution.

Time-box the race. Decide, record the result in the scorecard, delete the losing
branch; do not keep a GUC that selects between deciders.

Expected outcome, to be confirmed or refuted by the numbers: B wins criterion 1 by
construction because its walk is already paid for at plan time; A wins if the init
walk is unmeasurable, since it then has no downside and adds no planner surface. If B
wins on overhead but A's overhead is small, note the size of the gap so the choice can
be revisited with reviewer taste in mind.

Benefit: the one question that previous attempts left to argument, whether the
decision costs anything on queries it does not help, is answered with measurements,
and the base is untouched whichever way it goes.

### Phase 3: correctness hardening and tests (on B2, branch detoast-plan2)

Design as it stands after the race: set_scan_predetoast_attrs() in setrefs.c records
Scan.predetoast_attrs_safe (toastable, multi-referenced, not vetoed, not projected as
a bare Var) and Scan.predetoast_attrs_all (also the bare-projected ones); the executor
picks all with EXEC_FLAG_ROW_CONSUMER, safe when the node projects, none otherwise.
pull_multi_detoast_vars() (clauses.c) does the counting and the veto; get_attstorage()
(lsyscache.c, new) supplies column storage for toastability.

- Audit done 2026-09-03. Where a detoasted value written into a scan slot can travel:
  - Copies out of a slot: tts_heap/buffer_heap/minimal_copyslot and the copy_*_tuple
    ops copy the physical tuple, never tts_values, so they cannot carry the fat value.
    Only tts_virtual_copyslot/copy_*_tuple form tuples from tts_values, and a virtual
    slot only holds the fat value if a projection put a bare Var there, which the
    permission rule denies unless the parent chain consumes rows one at a time.
  - SubqueryScan: its scan slot is the child's result slot, so the fat value lands in
    the child's projection slot; that slot is cleared by ExecProject every row (reset)
    and is only ever copied by the SubqueryScan's own projection (rule applies there).
  - EPQ: ExecScanFetch returns the EPQ substitute slot as the scan tuple; the step
    writes into that slot (heap slot, reset on next store/clear), EvalPlanQualEnd
    clears it. LockRows passes rows through and is allowed to grant permission.
  - ModifyTable: UPDATE builds the new tuple from the old tuple fetched by tid into
    ri_oldTupleSlot, not from the scan slot; the guard and module tests confirm the
    toast pointer survives. ModifyTable does not grant permission, so bare-projected
    columns keep their pointers on INSERT ... SELECT.
  - Materialize inside slot ops (tts_*_materialize) resets tts_nvalid without
    resetting the detoast context: the fat copy is orphaned until the next
    store/clear, bounded by one row; harmless, noted.
  - Whole-row Vars of a physical scan slot go through the physical tuple; of a virtual
    slot through heap_form_tuple, again only bare projections, denied as above.
  - ForeignScan/CustomScan/ValuesScan/FunctionScan slots never hold on-disk toast
    pointers except via tuplestores of heap tuples (CTE-like), where the minimal slot
    behaves like any other physical slot.
  Every tts_nvalid = 0 site outside slot ops is a generic wrapper that resets the
  context (Phase 1); the ops-internal ones are the materialize cases above.
- Done 2026-09-03 (8b3e63761c): injection points detoast-attr-external and
  detoast-attr-compressed in detoast_attr; module src/test/modules/test_shared_detoast
  pins detoast counts per query shape (19 notices over the suite). Parallel workers
  cannot be observed this way (locally attached points are per process), the guard
  suite covers them via buffer counts.
- Done 2026-09-03: EXPLAIN (VERBOSE) prints "Pre-detoast: col, ..." per scan node from
  PlanState.ps_predetoast_scanattrs.
- Found while writing the module: length(text) detoasts fully in multibyte encodings,
  so it left the no-detoast function list; octet_length stays.
- UPDATE toast identity: covered by guard case 24 and the module test.
- JIT verified 2026-09-03 on the VM with an LLVM 14 cassert build: `make check` with
  jit forced (jit_above_cost=0 etc.) all 243 passed; the module test under forced JIT
  passes with identical detoast counts.
- wal_consistency_checking=all regression run: clean (243/243) on the VM cassert
  build, 2026-09-03.
- check-world on the cassert build after the module and EXPLAIN commits: clean apart
  from EXPLAIN VERBOSE expected outputs that now show the new line (domain, rowtypes,
  postgres_fdw; later subselect and join for the join phase), all updated.

Benefit: the two failure modes reviewers feared, fat tuples in materializing nodes
and semantic change for raw readers, are covered by deterministic tests, and the
behaviour is visible in EXPLAIN.

### Phase 4: join nodes (done 2026-09-03, commit 64f93ace70; VM: guard 30/30 phase 4 on cassert, check-world clean)

As built: set_join_predetoast_attrs() in set_join_references() records per side
Join.predetoast_{outer,inner}_{safe,all}; attributes used in merge or hash clauses
are excluded because they are evaluated on fetch, before spilling or hashing.
EEOP_INNER_VAR_TOAST / EEOP_OUTER_VAR_TOAST detoast into the child's slot.
ExecInitJoinPredetoast() picks the set per side: NestLoop and HashJoin both sides,
MergeJoin outer only. Guard cases 20/21 reach one detoast; module test has join
cases including the join-key exclusion (a jsonb join key stays at six detoasts).
EXPLAIN shows "Pre-detoast Outer/Inner: p.doc" deparsed like other join expressions.

- Extend the winning decider to Join nodes: count OUTER_VAR/INNER_VAR references in
  joinqual, plan.qual and tlist; per-side bitmaps on JoinState (for B, a per-side
  field on Join); emit EEOP_OUTER_VAR_TOAST/EEOP_INNER_VAR_TOAST.
- Permission per side: NestLoop outer and inner allowed when the join itself has
  permission and does not project the attribute bare; HashJoin inner never (hash
  table); MergeJoin outer only. HashJoin outer is allowed when the outer child's
  result slot is a fixed physical-tuple slot (check `ExecGetResultSlotOps`:
  BufferHeap, Heap or Minimal ops, not Virtual), because batch spills go through
  `ExecFetchSlotMinimalTuple`, which copies the physical tuple and never sees the fat
  value. Verified 2026-09-02 with EXPLAIN VERBOSE: for `SELECT t.big->'a', t.big->'b'
  FROM t JOIN u ...` the planner evaluates the expressions at the Hash Join and the
  scan of t returns its whole tuple without projection, so this is the common shape
  and it is safe.
- The child's slot is what gets the fat value, so the child scan's own bitmap and the
  join's bitmap are unioned before step emission; the reset sites must cover slots
  returned by child nodes.
- Harness cases: jsonb predicates evaluated as join quals, jsonb extraction in join
  projections, lateral joins.

Benefit: covers the case where the planner pushes the jsonb predicates into join
quals or the projection happens above a join, which is common once more than one
table is involved.

### Phase 5: overhead and polish (done 2026-09-03)

- No-op path: per-symbol perf profile of base vs B2 on the no-help statement shows
  ExecScanPredetoastAttrs at 0.11% of user instructions, i.e. the +27 per execution
  measured; one call per scan node per start (GUC check, IsScanPlan switch, two field
  loads). Left as is; everything else in the profile is sampling noise.
- Detoast intermediates: detoast_attr runs with the slot's detoast context current, so
  the toast index scan's descriptors and, for compressed values, the fetched compressed
  copy land there too. Generation context: the compressed copy is pfree'd (its own
  block, freed at once), the small allocations die at the next row's reset. Accepted;
  a context-parameter variant of detoast_attr is not needed.
- Denied candidates in the guard suite (criterion 2): 2 of 30 cases, both by design:
  case 15 (bare doc under Sort) and case 17 (HashAgg directly above the scan).
- headerscheck / cpluspluscheck on the Mac: only failures are missing Python, Perl
  and LLVM headers of an untooled build; nothing from the changed headers.
- GUC: kept as a developer option, documented in config.sgml (52537cdc1a).
- Expected-output churn: the Pre-detoast line appears in domain, rowtypes, subselect,
  join and postgres_fdw; updated.
- Doc validation (xmllint) clean on the VM after installing DocBook tooling.
- pgindent --check clean over every C file the branch touched; no leftover markers.
- Reviewable series assembled on branch `shared-detoast` (tree identical to
  detoast-plan2): 1) the feature (33 files, +932/-15), 2) injection points, test
  module and EXPLAIN expected outputs, 3) the GUC doc, 4) these development notes
  (drop before any submission). `detoast-plan2` keeps the full development history.
- No-cassert check-world (VM perf build, lz4, injection points): clean, 2026-09-03.
  Phase 5 closed.

### Phase 6: widen coverage (done 2026-09-03; VM: guard 30/30, cassert check-world clean)

- Parent-aware no-projection set (Scan.predetoast_attrs_noproj, set at the parent in
  set_plan_refs after recursing): tuple-copying parents allow everything, hashed Agg
  everything but grouping columns, projecting parents everything not bare-projected,
  unknown parents nothing. Guard case 17 (HashAgg directly above the scan) reaches one
  detoast; so does Sort above a projection-free scan.
- Aggregate inputs (Agg.predetoast_outer_attrs): aggregate arguments and quals
  referencing the same input column share one detoast, excluding grouping columns and
  columns passed whole to an aggregate (count(doc), array_agg(doc)). EXPLAIN shows
  "Pre-detoast Outer" on the Aggregate node.
- Still excluded by design: MergeJoin inner side, join keys, grouping sets and mixed
  aggregation, IndexOnlyScan/ValuesScan/SubqueryScan/CustomScan without projection,
  pass-through chains (Limit, LockRows, Append) below a storing parent unless the
  top-level permission reaches them.
- Denied candidates in the guard suite are now 1 of 30 (case 15, bare doc projected
  under a Sort, which is correct).

## Risks and how the plan handles them

- Fat datum leaks into a stored tuple: default-deny permission flag, tests per node.
- Memory growth: context reset on every row change; cassert build with
  MEMORY_CONTEXT_CHECKING under the regression suite; TPC-H style run in Phase 5.
- Raw-reader semantics: explicit list, unknown functions count as detoasters.
- Table AMs with custom slot ops: reset lives in generic wrappers, not in ops.
- Parallel query: flag withheld in workers, so workers never send fat tuples.
- Race without a verdict: criteria and time-box are fixed in Phase 0; the loser is
  deleted, not kept behind a switch.
- Deciders diverging from the base interface: both fill the same bitmap; anything a
  decider needs beyond that goes into the base first, on `detoast-base`.
