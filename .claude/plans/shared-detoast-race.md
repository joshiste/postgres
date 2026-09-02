# Shared detoast: decider race scorecard

Written before either decider exists (2026-09-02). Fill the result columns only
from runs on eddie-debian with the scripts described in shared-detoast-baseline.md.
Both contenders sit on `detoast-base`; only the decider differs.

## Gate (must pass before scoring)

| check                                                     | base | A exec | B plan |
|-----------------------------------------------------------|------|--------|--------|
| guard suite, mode=master on cassert build (all ok)        | 28/28 |        |        |
| guard suite, mode=patched phase=1 on cassert build        | n/a  |        |        |
| check-world, cassert build                                | see baseline |  |     |
| toast pointer identity kept after UPDATE (case 24)        | yes  |        |        |

## Criterion 1: init overhead (user-space instructions per iteration, perfbench.sh)

Absolute delta over base; the fraction is for readability only. Base values from
shared-detoast-baseline.md: loop_noop 24,128; loop_jsonb 32,374; loop_wide 5,100,165.

| workload   | master instr/iter | base instr/iter | base delta | A instr/iter | A delta | B instr/iter | B delta |
|------------|------------------:|----------------:|-----------:|-------------:|--------:|-------------:|--------:|
| loop_noop  |            24,128 |          24,155 |        +27 |              |         |              |         |
| loop_jsonb |            32,374 |          32,366 |         -8 |              |         |              |         |
| loop_wide  |         5,100,165 |       5,089,749 |    -10,416 |              |         |              |         |

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
| cases at target (of those with min_phase 1)          |   |   |
| candidates denied by the permission rule (count via EXPLAIN VERBOSE line, all cases) |   |   |

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
| prepared statement, generic plan, 100 executions: counts stable |   |   |
| plan copied via copyObject keeps the decision                   |   |   |
| EXPLAIN (no ANALYZE) shows the Pre-detoast line                 |   |   |
| EXEC_FLAG_EXPLAIN_ONLY path does no detoasting                  |   |   |

## Verdict

Decided on: ____  Winner: ____  Reason (one paragraph):

Loser branch deleted on: ____
