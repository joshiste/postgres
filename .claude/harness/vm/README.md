# Measurement setup on the Linux VM (eddie-debian)

- `build.sh [perf|debug|all]`: VPATH builds of `~/pg/src` into `~/pg/build-<kind>`,
  installed to `~/pg/inst-<kind>`; `perf` without cassert for instruction counts,
  `debug` with cassert for correctness. Both with injection points, TAP tests,
  `--enable-depend`, lz4, no ICU.
- `perfbench.sh PGBIN [ITER] [ROUNDS]`: attaches `perf stat -e instructions:u` to one
  backend while a plpgsql loop runs plan-cached statements; deterministic to a few
  instructions per iteration. Workloads: loop_noop (one reference, nothing to gain),
  loop_jsonb (two references to an inline jsonb), loop_wide (50 scans x 20 references).
  `EXTRA_OPTS="-c plan_cache_mode=force_custom_plan"` measures planning too.
- `profile2.sh PGBIN TAG PORT`: per-symbol instruction profile of loop_wide with perf
  record, for locating where a delta comes from.
- The guard suite (`../run.sh`, `../detoast_guard.sql`) runs there unchanged.

Requirements installed on the VM: linux-perf, bison, flex, libreadline-dev, zlib1g-dev,
liblz4-dev, pkg-config, libipc-run-perl, llvm-dev + clang (for a `--with-llvm` build),
docbook-xml/xsl + libxml2-utils (doc validation); `kernel.perf_event_paranoid=1`.
