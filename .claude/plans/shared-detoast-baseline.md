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
