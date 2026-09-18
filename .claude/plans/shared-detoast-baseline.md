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
