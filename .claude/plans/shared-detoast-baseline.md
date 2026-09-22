# Shared detoast: baseline measurements

Reference commit: e073b64d33 (master, 2026-08-28). Measured 2026-09-02.

## Measurement host: eddie-debian (KVM, i7-6820HQ Skylake, 8 vCPU, 9 GB, Debian 12)

Layout on the VM:

- `~/pg/src`            clone of git.postgresql.org/git/postgresql.git at e073b64d33
- `~/pg/build.sh`       VPATH builds: `perf` (no cassert) and `debug` (cassert), both
                        --enable-debug --enable-injection-points --enable-tap-tests
                        --with-lz4 --without-icu; installs to ~/pg/inst-perf, ~/pg/inst-debug
                        (plus contrib/pg_stat_statements and the injection_points module)
- `~/pg/harness/`       run.sh + jsonb_detoast.sql (block-count harness), v10 patch
- `~/pg/perfbench.sh`   `perf stat -e instructions:u` attached to one backend while a
                        plpgsql loop runs a plan-cached statement N times
- perf usable without sudo: kernel.perf_event_paranoid=1 via /etc/sysctl.d/90-perf.conf
- installed for this: linux-perf bison flex libreadline-dev zlib1g-dev liblz4-dev
                        pkg-config libipc-run-perl

Builds take about 2.5 minutes each with -j8.

## Harness (toast block counts), inst-perf

Identical to the Mac run: 133 toast heap blocks per detoast of the 1 MB EXTERNAL
document, N operators = N detoasts, OFFSET 0 pass-through still N, `doc || '{}'`
behind OFFSET 0 and jsonb_to_record = 1, inline control = 0. Timings on the VM were
taken while the debug build was compiling and are not usable as a baseline.

## perfbench.sh inst-perf, 200000 iterations, 3 rounds (user-space instructions)

| workload   | statement                                                      | instr/iter | spread across rounds |
|------------|----------------------------------------------------------------|-----------:|---------------------:|
| loop_noop  | `SELECT txt FROM bench WHERE id = $1` (one reference)          |     24,128 | 1 instruction        |
| loop_jsonb | `SELECT (big->>'a')::int, (big->>'b')::int FROM bench WHERE id = $1` | 32,374 | 0 instructions   |
| loop_wide  | UNION ALL of 50 index scans x 20 `(big->>'a')::int` each       |  5,100,165 | 3 instructions       |

Resolution is therefore better than 0.001% per iteration; a decider costing even a
few hundred instructions per scan node will be visible directly. Cycle counts vary by
a few percent between rounds and are not used for the race criterion.

Race criterion 1 is scored as: instr/iter delta of A and B over base on loop_noop
(the "does not help" case) and loop_wide (amplified), reported as absolute
instructions and as a fraction of base.

## Guard suite (.claude/harness/detoast_guard.sql), mode=master

- eddie-debian inst-perf and inst-debug (cassert): 27/27 ok each, identity kept; identical
  block counts to the Mac after pinning docz to pglz (lz4 builds compress it to 16
  blocks per two detoasts instead of 20).
- Mac, scratchpad build (no cassert, no lz4): 27/27 ok, toast pointer identity kept
  after UPDATE; mode=patched phase=1 on the same master build flags exactly the 16
  win cases and exits 3, as intended.
- Pinned master values worth knowing: text slice/size readers fetch 28 toast blocks
  (case 14); the compressed docz column costs 10 toast blocks per detoast (case 27);
  the parallel case shows 0 leader-local toast blocks and 333 shared blocks (case 23).

## Base (detoast-base with the empty decision hook, commit f064153d4d)

- Guard suite mode=master: 28/28 ok on Mac, VM perf and VM debug (cassert).
- Throwaway decider (all toastable attributes) in mode=patched phase=1: all Phase 1
  win cases at target, all guards hold, toast pointer identity kept; cases 13 and 27
  pass only because of the raw-reader veto.
- Mac `make check` on the base: all 243 tests passed.
- perfbench inst-perf (rebuilt with --enable-depend), 200000 iterations:
  loop_noop 24,155 (+27 vs master), loop_jsonb 32,366 (-8), loop_wide 5,089,749
  (-10,416, -0.2%). The negative deltas are layout effects of the header change; the
  +27 is the mechanism's own cost on a statement it cannot help.

## B2 with joins (92bec0f69d), eddie-debian, 2026-09-03

| workload   | master | base   | B2     | B2+joins | B2+joins vs base |
|------------|-------:|-------:|-------:|---------:|-----------------:|
| loop_noop  | 24,128 | 24,156 | 24,174 |   24,185 |              +29 |
| loop_jsonb | 32,374 | 32,375 | 32,386 |   32,474 |              +99 |
| loop_wide  | 5,100,165 | 5,074,017 | 5,033,261 | 5,047,800 |   -26,217 |

No join in these statements, so the +11/+88 over B2 is layout movement from the new
interpreter cases and PlanState fields, the same magnitude seen between master and
base. Guard 30/30 at phase 4 on the cassert build, identity kept; check-world clean;
wal_consistency_checking regression clean; forced-JIT regression and module clean.

## Phase 6 (58c2aec422), eddie-debian, 2026-09-03

| workload   | master | base   | Phase 4 | Phase 6 | Phase 6 vs base |
|------------|-------:|-------:|--------:|--------:|----------------:|
| loop_noop  | 24,128 | 24,156 |  24,185 |  24,178 |             +22 |
| loop_jsonb | 32,374 | 32,375 |  32,474 |  32,468 |             +93 |
| loop_wide  | 5,100,165 | 5,074,017 | 5,047,800 | 5,161,606 |    +87,589 |

Guard 30/30 at phase 6 on the cassert build (case 17 now one detoast), identity kept,
check-world clean.

The loop_wide jump was investigated: with plan_cache_mode=force_generic_plan the per
symbol profile contains no planner functions, so nothing is replanned; a build of the
same tree with the two Phase 6 planner calls disabled (which are no-ops for this
statement) measured 5,119,047 against 5,177,726 for the unmodified build under generic
plans. Two binaries differing only in plan-time code thus differ by 1% at execution
time, which can only come from binary layout, most plausibly through pointer-keyed
hash tables (ResourceOwner's hash moved in the profile). loop_wide is therefore
trustworthy only to about 1.5% between builds; the two small statements, where the
whole change costs 22 and 93 instructions, are the reliable no-regression evidence.
Planning cost itself, visible under force_custom_plan, is +1.7% for this 50-scan,
1000-expression statement and is paid once per plan.

## After the review fixes (commit series 2026-09-04, on upstream 534db08f97)

| workload   | master | final  | delta vs master |
|------------|-------:|-------:|----------------:|
| loop_noop  | 24,128 | 24,200 |      +72 (0.3%) |
| loop_jsonb | 32,374 | 32,527 |     +153 (0.5%) |

The receiver check in InitPlan and the (empty) raw-reader pass account for part of
the step from the Phase 6 build; the rest is layout, as before. Guard 30/30 at phase
6, identity kept, cassert check-world clean on the VM. These are the final numbers
for the series as pushed.

## Items 15 and 4 (2026-09-10, eddie-debian, tip c39abcd666 vs base)

Planning cost on the small statements (plan_cache_mode forced; instr/iter, 1 round of
100000):

| workload   | generic base | generic tip | custom base | custom tip | planning delta |
|------------|-------------:|------------:|------------:|-----------:|---------------:|
| loop_noop  |       24,151 |      24,196 |      68,981 |     69,573 | +547 (1.2% of ~45k) |
| loop_jsonb |       32,366 |      32,515 |      93,698 |     96,336 | +2,489 (4.1% of ~61k) |

The planning delta is the custom-plan delta minus the generic-plan (execution) delta.
For a statement with a candidate column (loop_jsonb) the planner pays about 2.5k
instructions: the reference walk, the toastability syscache lookups, bitmap
allocations and the raw-reader pass. Paid once per plan; visible only under forced
custom plans or unparameterized statements planned every time. A follow-up could skip
get_attstorage when the type's default storage already decides, or cache per relation.

Short-header widening (branch detoast-shortheader, generic plans, instr/iter):

| workload   | tip       | with widening | delta |
|------------|----------:|--------------:|------:|
| loop_noop  |    24,181 |        24,179 |    -2 |
| loop_jsonb |    32,500 |        33,112 |  +612 (+1.9%) |
| loop_wide  | 5,112,404 |     5,039,556 | -72,848 (-1.4%) |

Widening a short-header value once into the slot context costs more than two plain
short-header copies (out-of-line call, context creation and per-row reset) and only
pays off with many references per row. Not adopted; a reference-count threshold at
plan time would be the way to revisit it. The experiment branch is deleted.

## Final series tip 73b2f6fb1a on upstream 0c5d626961 (2026-09-15, eddie-debian)

Planning cost after the fifth commit (plan_cache_mode forced; instr/iter, 100000):

| workload   | generic base | generic tip | custom base | custom tip | planning delta |
|------------|-------------:|------------:|------------:|-----------:|---------------:|
| loop_noop  |       24,137 |      24,182 |      68,999 |     69,316 |  +272 (was +547) |
| loop_jsonb |       32,352 |      32,612 |      93,698 |     96,057 | +2,099 (was +2,489) |

Remaining cost for a statement with a candidate: the column-storage catalog lookup,
the reference walk with its list and bitmap allocations, and the raw-reader pass.
Paid once per plan, only where the feature applies. Cassert build: guard 30/30,
module pass, check-world clean.


## Workload benchmarks (2026-09-18, eddie-debian, -O2 builds without cassert)

Master 26a3c0a45c vs series 0c1015e00f (same tree as ead970111e apart from tests),
one data directory served by either binary; jit off; warm cache; wall clock is the
median of 3 psql \timing runs with the default 2 parallel workers, CPU is backend
user time from log_executor_stats with parallelism off.  All result checksums
identical across master, series on and series off.

JSONBench (PostgreSQL variant): bluesky(data jsonb COMPRESSION lz4), 7,000,000 of
the 10m rows loaded (3 files failed the CSV-trick load), 4.4 GB table, avg document
541 bytes, 10,224 compressed inline, 613 out of line.  So this is the no-gain case.

| query | master wall ms | series on wall ms | master CPU s | series on CPU s | series off CPU s (interleaved) |
|-------|---------------:|------------------:|-------------:|----------------:|-------------------------------:|
| Q1 group by collection            | 1,380 | 2,420 (see note) | 2.28 / 2.40 | 2.26 / 2.18 | 2.19 / 2.22 / 2.25 |
| Q2 count distinct did             | 35,600 | 36,800 | 40.7 / 40.3 | 40.9 / 40.3 | 42.4 / 41.9 (drift) |
| Q3 per hour                        | 5,930 | 6,010 | 7.66 / 6.97 | 7.21 / 7.37 | 7.03 / 7.06 / 7.36 |
| Q4 first post per user (index)    | 1,030 | 1,035 | 0.86 / 0.91 | 0.92 / 0.90 | 0.98 / 0.89 |
| Q5 activity span (index)          | 1,200 | 1,200 | 1.08 / 1.07 | 1.11 / 1.07 | 1.14 / 1.11 |

Note: Q1-Q3 wall clock on this 9 GB VM depends on the page cache (3 GB shared
buffers, 4.4 GB table); the first series run of Q1 was 2.4-2.9 s and the "off" run
3.1-3.8 s, i.e. slower than "on", which identifies the wall-clock spread as cache/IO
noise.  Interleaved CPU (series on / off alternating, then master) shows no
difference: Q1 2.13-2.25 vs 2.19-2.25 vs master 2.35-2.38; Q3 7.03-7.44 vs 7.03-7.36
vs master 6.85-7.48.

Bartunov, "The curse of TOAST" (PGConf NYC 2021): test(jb jsonb) EXTERNAL, 10,000
rows of ~2 KB after the update that pushed them out of line.

| query | master ms | series on ms | series off ms | master blocks | series on blocks | master CPU s | series on CPU s |
|-------|----------:|-------------:|--------------:|--------------:|-----------------:|-------------:|----------------:|
| Q6  jb->'id'                          | 33.3 | 33.6 | 34.7 | 30,104 | 30,104 | 0.027 | 0.032 |
| Q7  two operators                     | 55.3 | 36.2 | 58.0 | 60,104 | 30,104 | 0.052 | 0.031 |
| Q8  four operators                    | 96.0 | 38.9 | 102.9 | 120,104 | 30,104 | 0.091 | 0.037 |
| Q9  count, three ops in WHERE         | 62.2 | 33.2 | 64.6 | 75,104 | 30,104 | 0.058 | 0.032 |
| Q10 manual once-detoast workaround    | 66.9 | 37.0 | 67.5 | 75,104 | 30,104 | 0.067 | 0.034 |

Q10 is the LATERAL jsonb_path_query_first(jb, '$') trick from the talk; the planner
flattens it into three calls, so on master it detoasts once per row anyway and the
series shares that single detoast (Pre-detoast: jb on the scan).  With the feature
off, the series equals master in time and block counts on every query.


## Alternative: detoasted copies beside the slot (detoast-sidecache, 2026-09-19)

Branch detoast-sidecache = the reviewed five-commit series (7fb0318b70) plus one
commit (8895f4f7d5) that keeps the detoasted copy in a per-slot side array
(tts_detoasted) instead of writing it into tts_values; only argument positions of
function-like constructs read the copy, so nothing that stores rows, passes the
column on whole or inspects the stored form can see it.  The permission flag, the
safe/all/noproj sets, the raw-reader veto pass and the per-node exclusions are gone.

Instruction harness on eddie-debian (-O2, no cassert; master 26a3c0a45c, series
7fb0318b70, sidecache 8895f4f7d5), instructions per iteration:

| workload   | master    | series (delta)      | sidecache (delta)   |
|------------|----------:|--------------------:|--------------------:|
| loop_noop  |    24,046 |   24,119 (+73)      |   24,277 (+231)     |
| loop_jsonb |    32,320 |   32,433 (+113)     |   32,565 (+245)     |
| loop_wide  | 5,014,215 | 5,118,541 (+2.1%)   | 5,158,405 (+2.9%)   |

Planning (plan_cache_mode=force_custom_plan, one round; planning delta = custom
delta minus generic delta):

| workload   | master custom | series custom (planning) | sidecache custom (planning) |
|------------|--------------:|-------------------------:|----------------------------:|
| loop_noop  |    68,865 |  69,267 (+329)  |  69,218 (+122)  |
| loop_jsonb |    93,577 |  96,024 (+2,334)|  95,545 (+1,723)|
| loop_wide  | 25,534,558 | 25,848,715 (+1.2%) | 25,907,306 (+1.5%) |

Reading: the sidecache plans cheaper (no veto pass, one set per node) but costs about
160 more instructions per statement at execution on plans that gain nothing.  That
is expression-compile time: every function argument goes through
ExecInitDetoastArg, and cached plans recompile their expressions at each
ExecutorStart.  On loop_wide (1000 argument positions) the gap is 40k instructions.
Both remain small against the statement (0.7% and 0.8%).

Behaviour where the approaches differ (detoasts per row, injection points, Mac build):

| shape | series | sidecache |
|-------|-------:|----------:|
| client receives bare doc + two ops         | 1 | 2 (client output detoasts the pointer) |
| bare doc + two ops under a Sort            | 2 (+1 output) | 1 (+1 output) |
| merge join, two ops on the inner side      | 2 | 1 |
| hash agg GROUP BY doc, two predicates      | 2 | 1 |
| raw reader beside two ops                  | 1, pointer kept | 1, pointer kept |
| UPDATE with two WHERE ops                  | 1, pointer kept | 1, pointer kept |

Workload CPU (backend user time, parallelism off, same data directory): JSONBench Q4/Q5
and the Bartunov table Q6-Q10 identical within noise between series and sidecache
(e.g. Q8 0.037 vs 0.031/0.038 s); Q1-Q3 full scans drift with the machine as before.
Results identical across all configurations.

Verification of the sidecache tip: Mac pgindent, build (0 warnings), module (default
and debug_parallel_query=regress), regression, postgres_fdw, guard 30/30 at the
series' targets; VM cassert module, guard 30/30, check-world; fork CI run
35458028894.

### Toasted rows: per-row cost of the two mechanisms (2026-09-19)

perftoast.sh: 1000 rows with a 15 KB EXTERNAL jsonb, one row per plan-cached
statement, 20,000 iterations, 3 rounds (all rounds agree to a few instructions).

| statement (references) | master | series | sidecache | sidecache off |
|------------------------|-------:|-------:|----------:|--------------:|
| one                    | 53,564 | 53,692 (+128) | 53,921 (+357) | 53,933 |
| two                    | 82,956 | 59,520 (-28%) | 59,760 (+240 vs series) | 83,439 |
| four                   | 139,855 | 66,756 (-52%) | 67,014 (+258 vs series) | 140,452 |

The sidecache's extra over the series is 230-260 instructions per statement and does
not grow with the number of references, so it is the compile-time argument check plus
the one palloc0 of the side array for the detoasted row; against the ~29,000
instructions one 15 KB detoast costs, the per-row part is below 0.3% and an epoch
counter is not warranted.  With the feature off the sidecache equals master within
600 instructions (the compile-time check).

### Amended sidecache tip dee9436848 (early-out in ExecInitDetoastArg), 2026-09-19

| workload   | master | series | sidecache 8895f4f7 | sidecache dee94368 |
|------------|-------:|-------:|-------------------:|-------------------:|
| loop_noop  | 24,046 | 24,119 | 24,277 | 24,306 |
| loop_jsonb | 32,320 | 32,433 | 32,565 | 32,654 |
| loop_wide  | 5,014,215 | 5,118,541 | 5,158,405 | 5,167,798 |
| toast_one  | 53,564 | 53,692 | 53,921 | 53,937 |
| toast_two  | 82,956 | 59,520 | 59,760 | 59,856 |
| toast_four | 139,855 | 66,756 | 67,014 | 67,113 |

The early-out changed nothing measurable (differences of 30-90 instructions are
within layout noise).  A per-symbol profile (perf record, 400k iterations) puts
ExecInitDetoastArg at 0.37% of loop_noop (~90 instructions per statement: the call
itself, for every function argument the statement and the plpgsql loop compile) and
0.67% of loop_jsonb (~220, where the scan has a set and the full check runs), with
ExprEvalPushStep up 0.6% there; everything else scatters within +-0.5%.  The residual
could be removed by making the no-sets check a static inline in the callers, worth
about 0.4% of a trivial statement.  Verification of dee9436848: VM cassert module and
guard 30/30, CI run 35461872423; the Mac run of that tip was invalid because the
working tree already held uncommitted follow-up work.

## Series rebuilt on the sidecache design (tip 5522903769, fixup e9ca8d8580), 2026-09-19

Four commits: mechanism + scan decision, joins/aggregates/window functions, EXPLAIN +
tests, docs.  Copies live beside the slot (tts_detoasted); projections carry them
into the result slot (EEOP_ASSIGN_*_VAR_TOAST); merge and hash keys share; WindowAgg
has a set; the no-sets early-out is a static inline in the callers.

Instruction harness (same run, master 26a3c0a45c vs new series), instr/statement:

| workload   | master | new series | delta |
|------------|-------:|-----------:|------:|
| loop_noop  | 24,056 | 24,159 | +103 |
| loop_jsonb | 32,331 | 32,670 | +339 |
| loop_wide  | 5,033,467 | 5,180,798 | +2.9% |
| toast_one  | 53,569 | 53,692 | +123 |
| toast_two  | 82,963 | 59,889 | -28% |
| toast_four | 139,867 | 67,183 | -52% |
| planning loop_noop  | 68,858 | 69,119 | +158 net of execution |
| planning loop_jsonb | 93,566 | 95,524 | +1,619 net of execution |
| planning loop_wide  | 25,457,028 | 25,964,408 | +1.4% net of execution |

For comparison the previous in-place series measured +73 / +113 / +2.1% on the first
three rows and the first sidecache tip +231 / +245 / +2.9%; the caller-side early-out
recovered most of the no-gain path.

Workload CPU (backend user time, parallelism off, results identical): JSONBench
Q1-Q5 within noise of master; Bartunov table two ops 0.054 -> 0.036 s, four ops
0.093 -> 0.039 s, three predicates 0.061 -> 0.033 s, manual workaround 0.064 ->
0.033 s; with shared_detoast off the series equals master on Q4-Q10 (Q1-Q3 scans
drift with the machine as in every run).

Verification: Mac build (0 warnings), module (default and debug_parallel_query=
regress), regression 239/239, postgres_fdw, guard 30/30; VM cassert module, guard,
check-world; CI: first run failed only pg_upgrade/002 on Linux Autoconf and 32-bit
because collate.icu.utf8.out (run only under UTF-8 + ICU there) gains four
"Pre-detoast Outer" lines for text join keys; fixed as fixup e9ca8d8580; rerun 35463914575 fully green
(all Linux, macOS and Windows jobs including ASAN).  pgindent wants one comment rewrap in plannodes.h (Agg field).
Docker images: postgres-shared-detoast:series (5522903769), :sidecache (dee9436848).

## Parameter sharing (commit "Share detoasted copies through parameters", tip d3e8b9b31c), 2026-09-20

ParamExecData carries a reference to the source slot and attribute; a varlena
PARAM_EXEC parameter in an argument position compiles to EEOP_PARAM_EXEC_TOAST and
reads or makes the copy in the source slot's side array; SRF arguments are argument
positions.  The application shape (EXISTS over jsonb_array_elements_text(col -> key)
with LIKE ANY) detoasts once per outer row; a raw reader on the parameter inside the
subplan and a bare parameter projected out of it keep the pointer (checked on the Mac).
A pulled-up EXISTS (nested-loop semi-join) is a different shape: the join filter holds
one reference evaluated per inner row, and a node with one reference gets no set; a
join qual over an outer column pays off with a single reference whenever the inner
side has more than one row, worth a benefit-rule refinement.

Harness, same run (master vs tip):

| workload   | master | tip | delta | previous tip |
|------------|-------:|----:|------:|-------------:|
| loop_noop  | 24,050 | 24,301 | +251 | +103 |
| loop_jsonb | 32,325 | 32,718 | +393 | +339 |
| loop_wide  | 5,020,123 | 5,195,898 | +3.5% | +2.9% |
| toast_one  | 53,562 | 53,867 | +305 | +123 |
| toast_two  | 82,960 | 59,917 | -28% | -28% |
| toast_four | 139,866 | 67,207 | -52% | -52% |
| planning loop_noop | 68,865 | 69,259 | +143 net | +158 |
| planning loop_jsonb | 93,577 | 95,630 | +1,660 net | +1,619 |

The +150 on loop_noop over the previous tip comes from the inline ExecInitDetoastArg
now routing every Param and RelabelType argument out of line regardless of the node's
sets; loop_noop's statements are full of PL/pgSQL variables (PARAM_EXTERN) in argument
positions, each paying the call before the paramkind test turns it away.  Testing
paramkind == PARAM_EXEC in the inline would restore the previous numbers.

Workload CPU: JSONBench Q1-Q5 within noise of master; Bartunov two ops 0.053 -> 0.033 s,
four ops 0.091 -> 0.036 s, three predicates 0.063 -> 0.028 s, workaround 0.067 ->
0.037 s; off equals master on Q4-Q10.  Results identical.  Verification: Mac pgindent,
build (0 warnings), module (both settings), regression, postgres_fdw, guard 30/30; VM
cassert module, guard, check-world; CI run 35468747369 fully green.

## Single outer-side join reference + inline paramkind test (tip 8bbb4aef12), 2026-09-20

pull_multi_detoast_vars(single_ref_ok) marks any outer-side argument position of a
join (replacing the hash-key double count); ExecInitDetoastArg's inline calls out only
for PARAM_EXEC params or Vars on nodes with sets.  Case D (pulled-up semi-join, 3 outer
x 5 inner rows, no match): 18 -> 6 detoasts; the remaining 3 are the scan's own single
reference.  A join with the jsonb table on the inner side under a Materialize still
detoasts per (outer, inner) pair, as the rule states.

Harness (same run, master vs tip): loop_noop 24,043 -> 24,244 (+201), loop_jsonb
32,318 -> 32,546 (+228), loop_wide 5,070,997 -> 5,079,780 (+0.2%); planning +412 /
+2,136 / +1.4% total; toast_one 53,574 -> 53,832, toast_two 82,972 -> 59,764 (-28%),
toast_four 139,882 -> 67,066 (-52%).  Workload CPU: JSONBench within noise of
master; Bartunov two ops 0.054 -> 0.034 s, four 0.094 -> 0.036 s, three predicates
0.063 -> 0.031 s, workaround 0.067 -> 0.035 s; off equals master on Q4-Q10; results
identical.  Verification: Mac pgindent, build (0 warnings), module (both settings),
regression, postgres_fdw, guard 30/30; VM cassert module, guard, check-world; CI run
35507784827 fully green.  Expected outputs of join, join_hash, rangefuncs,
returning and postgres_fdw gain "Pre-detoast Outer" lines for single text references
in join filters.

## No-repetition cost matrix (tip 49e46f72e5 vs master d39fda1cc4), 2026-09-22

Requested acceptance run.  perf stat -e instructions:u on one backend, plan-cached
loops, 5-6 interleaved reps, median.  master at the series base, series tip with the
GUC off and on, one data directory each (master's copied for the series).  100k rows,
doc ~20 kB EXTERNAL, cdoc ~20 kB EXTENDED pglz, small ~100 B inline, txt short.

A-E and I first ran with a rotating id and showed a spurious -21% on A/B: that was
buffer-read warmth (profile: pg_checksum_block_avx2 / shared_buffer_readv_complete
only in the off run, which ran before the warmest on run), not the feature -- A gets
no set (one detoast per execution either way, injection points confirm).  Rerun
against a fixed warm row (id=1), instr/exec, median of 6:

| statement                    | master | off | on | off vs m | on vs m |
|------------------------------|-------:|----:|---:|---------:|--------:|
| A single ref, external       | 54,171 | 54,252 | 54,260 | +0.15% | +0.16% |
| B single ref, compressed     | 71,819 | 71,905 | 71,913 | +0.12% | +0.13% |
| C single ref, inline         | 22,818 | 22,896 | 22,904 | +0.34% | +0.38% |
| D no toastable column        | 21,626 | 21,707 | 21,715 | +0.37% | +0.41% |
| E bare projection            | 20,130 | 20,193 | 20,201 | +0.31% | +0.35% |
| F two refs (gain)            | 88,850 | 88,963 | 59,258 | +0.13% | -33.3% |
| I plpgsql, 10 text params    |  6,140 |  6,140 |  6,140 | +0.01% | +0.01% |

Join statements (rotating id, hash join with the jsonb table on the probe side so the
single outer-side reference triggers the rule; spreads < 0.1%):

| statement                        | master | off | on | off vs m | on vs m |
|----------------------------------|-------:|----:|---:|---------:|--------:|
| G hash filter, 1 inner row       | 54,607,391 | 54,623,151 | 55,248,308 | +0.03% | +1.17% |
| H hash filter, 5 inner rows      |  8,796,759 |  8,805,731 |  6,374,057 | +0.10% | -27.5% |
| Gnl nestloop param, 1 inner row  | 66,934,571 | 66,999,587 | 67,045,036 | +0.10% | +0.17% |

G is the rule's worst case: on - off = 625,156 per execution / 1000 outer rows = 625
instructions per outer row, one palloc0 of the side array plus the detoast master
would make at the reference anyway, reused only once.  Breaks even at two inner rows
(H, 5 rows, is -27.5%).  Gnl: the planner made doc a single-reference inner index-scan
qual, i.e. the plain path, +45 instr per outer row.

Planning (force_custom_plan minus generic): A +1,529, F +1,563 per plan; G varies by
+/-200k with the join search on the 5000-row range, not a real delta.

Memory (H, backend VmHWM): master 137,676 kB, off 139,540, on 139,860 -- the +320 kB
of "on" over 1000 executions of a 20-outer-row join shows the copy is released per
outer row, not accumulated.

Acceptance: PASS.  off within 0.5% of master everywhere; on within 1% on A-E and I;
F and H reduce as expected; G's on-vs-off is one allocation + one detoast per outer
row (625 instr), the only shape where the rule spends more than it saves at exactly
one inner row.  Results identical across all builds throughout.
