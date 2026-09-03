# Shared detoast: decider race scorecard

Written before either decider exists (2026-09-02). Fill the result columns only
from runs on eddie-debian with the scripts described in shared-detoast-baseline.md.
Both contenders sit on `detoast-base`; only the decider differs.

## Gate (must pass before scoring)

| check                                                     | base | A exec | B plan |
|-----------------------------------------------------------|------|--------|--------|
| guard suite, mode=master on cassert build (all ok)        | 28/28 | n/a (15 wins deviate) | n/a (15 wins deviate) |
| guard suite, mode=patched phase=1 on cassert build        | n/a  | 28/28  | 28/28  |
| check-world, cassert build                                | pass | pass (after base varno fix 8bc5ebbd61) | pass (same) |
| toast pointer identity kept after UPDATE (case 24)        | yes  | yes    | yes    |

The first check-world run of A and B failed identically: tlist_matches_tupdesc()
asserted on INDEX_VAR targetlists (index-only scans, pushed-down foreign joins). The
bug was in the base but unreachable with the empty decision hook, so only the
deciders exposed it; the Mac build has no cassert and the guard suite has no such
plan shape. Fixed in the base, both reran clean.

## Criterion 1: init overhead (user-space instructions per iteration, perfbench.sh)

Absolute delta over base; the fraction is for readability only. Base values from
shared-detoast-baseline.md: loop_noop 24,128; loop_jsonb 32,374; loop_wide 5,100,165.

| workload   | master instr/iter | base instr/iter | base delta | A instr/iter | A delta | B instr/iter | B delta |
|------------|------------------:|----------------:|-----------:|-------------:|--------:|-------------:|--------:|
| loop_noop  |            24,128 |          24,156 |        +28 |       24,371 |    +215 |       24,182 |     +26 |
| loop_jsonb |            32,374 |          32,375 |         +1 |       34,315 |  +1,940 |       33,372 |    +997 |
| loop_wide  |         5,100,165 |       5,074,017 |    -26,148 |    5,845,694 | +771,677 |   5,480,362 | +406,345 |

B2 (f5d9a2d27e: plan-time sets, folded veto, pointer pick in the executor, inline
header check in the interpreter), same host, 2026-09-03:

| workload   | B2 instr/iter | B2 delta vs base |
|------------|--------------:|-----------------:|
| loop_noop  |        24,174 |              +18 |
| loop_jsonb |        32,386 |              +11 |
| loop_wide  |     5,033,261 |          -40,756 |

B2 gate: guard 30/30 patched on cassert (two new subplan/FOR UPDATE cases), base
30/30 master with the new suite, identity kept, check-world pass. B2's first
check-world failed in eval-plan-qual: the RTE lookup used the subquery level's
range table after scanrelid had been offset into the flattened one; fixed.

Race run 2026-09-03 on eddie-debian; base here is 77b181154d (with the unused walker
and the IsScanPlan check), A is 18c0f84c1a, B is feac300bfd. Guard suites on the
cassert builds: base 28/28 master; A and B 28/28 patched phase 1, identity kept.

Reading: B wins criterion 1 outright (26 vs 215 on the no-help case). But both
regress on loop_jsonb and loop_wide, where the jsonb column is referenced twice but
is inline, so nothing is gained. That regression is not the decider walk: it is the
base's per-ExecutorStart work once candidates exist (veto walk over the expressions,
toastability loop, bare-Var scan, bitmap allocations), plus the out-of-line
EEOP_SCAN_VAR_TOAST call per reference per row. Constraint 1 (no regression when the
column is not toasted) is therefore not yet met by either variant.

Base measured 2026-09-02 on eddie-debian (perf build, --enable-depend). The base adds
the per-store reset branch, the ExecInitNode flag translation and the (empty) decision
call; +27 instructions on loop_noop is that cost. The negative deltas are code-layout
effects of recompiling with the changed headers, so differences of that size between
A and B are noise, not signal.

Scoring: lower delta wins; a difference below 30 instructions per iteration on
loop_noop (about 0.1%, the size of layout effects seen for the base) is a tie. loop_jsonb is expected to drop for both (one detoast saved
outweighs the walk); the comparison there is between A and B, not against base.

## Criterion 2: coverage (guard suite, mode=patched phase=1)

| measure                                              | A | B |
|------------------------------------------------------|---|---|
| cases at target (of those with min_phase 1)          | all | all |
| candidates denied by the permission rule (count via EXPLAIN VERBOSE line, all cases) | 2 of 30 (cases 15, 17); 1 of 30 after Phase 6 | 2 of 30 (same) |

Recorded for the Phase 5 decision on cross-node precision; not a tiebreaker unless
the two differ.

## Criterion 3: size

| measure                     | A | B |
|-----------------------------|---|---|
| diff lines vs detoast-base  | 8 (+6/-2, execScan.c only) | 26 (+21/-5) |
| files touched               | 1 | 3 (execScan.c, setrefs.c, plannodes.h) |
| subsystems touched          | executor | executor, planner, node definitions |
| new Plan node fields        | 0 | 1 (Scan.predetoast_attrs, Bitmapset) |

Both rely on pull_multi_detoast_attrs() in the base (about 200 lines), so the
comparison above is the decider-specific part only.

## Criterion 4: plan cache and EXPLAIN behaviour

| check                                                          | A | B |
|----------------------------------------------------------------|---|---|
| prepared statement, generic plan, 100 executions: counts stable | yes (perfbench) | yes (perfbench) |
| plan copied via copyObject keeps the decision                   |   |   |
| EXPLAIN (no ANALYZE) shows the Pre-detoast line                 |   |   |
| EXEC_FLAG_EXPLAIN_ONLY path does no detoasting                  |   |   |

## Verdict

Decided on: 2026-09-03  Winner: B2 (plan-time decision, executor permission check)

Reason: A and B both met every correctness gate and every Phase 1 target, so the
decision fell to criterion 1. B beat A eightfold on the no-help statement (+26 vs
+215 instructions), but both regressed 3% to 15% on statements that reference an
inline, never-toasted jsonb column twice, because the base still did the veto walk,
toastability check, bare-Var scan and bitmap allocations at every ExecutorStart once
candidates existed. Moving all of that to plan time (B2) removed the regression:
+18 and +11 instructions on the two small statements, within layout noise, and no
measurable cost on the amplified one. An executor-only variant cannot get there,
since the same work would have to run at every start. The price is one new Plan
field pair on Scan (two Bitmapsets), which the reviewers of the 2024 patch
questioned; the numbers above are the answer to that question.

Loser branch deleted on: 2026-09-03 (detoast-exec and the intermediate detoast-plan;
detoast-plan2 continues as the working branch, detoast-base stays as the record of
the shared mechanism).
