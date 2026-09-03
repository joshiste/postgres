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

### Phase 5: overhead and polish (in progress 2026-09-03)

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
- Remaining: doc validation and no-cassert check-world on the VM (running), then a
  final pgindent pass over the branch and a squash into reviewable commits.

### Phase 6 (optional): widen coverage

- Cross-node permission analysis if Phase 5 shows it pays.
- Aggregate arguments in Agg nodes (transition functions detoast per row; the group
  state is not the input slot).
- Generalize the physical-slot test from Phase 4: any storing parent whose child
  returns a fixed physical-tuple slot copies the physical tuple, so the deny is only
  needed when a projection into a virtual slot carrying the bare Var sits between the
  pre-detoasting node and the storing node. Replacing the eflags rule with this check
  would recover Sort/Hash/Agg directly above a projection-free scan.

Benefit: closes the remaining gaps; each item is independently measurable with the
harness.

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
